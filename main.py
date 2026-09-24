"""Gapwatch entrypoint: feed listener -> filter engine -> event state machine."""

from __future__ import annotations

import asyncio
import logging

import requests
from rhfeed import MAINNET_FEED, FeedConsumer

from src.event_store import (
    connect,
    get_all_events,
    get_events_by_status,
    get_pending_events,
    increment_reference_model_attempts,
    insert_pending_event,
    set_onchain_cache,
)
from src.filter_engine import FilterEngine
from src.filter_verifier import check_event as filter_verifier_check
from src.l1_confirmer import check_event as l1_confirmer_check
from src.reference_model import verify_event
from src.registry_client import event_hash_to_bytes32, registry_contract, testnet_w3
from src.token_registry import build_registry, refresh_registry

_log = logging.getLogger("gapwatch.main")

#: How often the state-machine loop wakes up to advance pending events.
STATE_MACHINE_INTERVAL_SECONDS = 15


def _refresh_onchain_cache(conn) -> None:
    """Sync `onchain_verified_cache` for display purposes only (GET /events list
    view). `isVerified` is monotonic -- once true, always true, since recordedAt
    is never cleared even after a challenge -- so a row already cached true is
    never re-checked. Never treated as ground truth: GET /events/{id} always
    re-reads the chain directly regardless of what this column says."""
    try:
        w3 = testnet_w3()
        registry = registry_contract(w3)
    except Exception as exc:  # noqa: BLE001 -- cache refresh must never crash the loop
        _log.warning("onchain cache refresh: could not connect: %s", exc)
        return

    for row in get_all_events(conn):
        if row["onchain_verified_cache"]:
            continue
        event_hash = event_hash_to_bytes32(row["tx_hash"])
        try:
            verified = registry.functions.isVerified(event_hash).call()
        except requests.exceptions.ConnectionError as exc:
            # A dropped keep-alive connection (e.g. RemoteDisconnected) surfaces
            # here as requests.exceptions.ConnectionError. The retrying session
            # from registry_client already retries at the connection-pool level,
            # so getting here means that was exhausted -- rebuild the Web3/
            # registry pair (a fresh session) once and give this row one more
            # try before giving up on it for this tick.
            _log.warning(
                "onchain cache refresh: connection dropped for event id=%d, "
                "rebuilding session and retrying once: %s", row["id"], exc,
            )
            try:
                w3 = testnet_w3()
                registry = registry_contract(w3)
                verified = registry.functions.isVerified(event_hash).call()
            except Exception as exc2:  # noqa: BLE001 -- one bad row must not block the rest
                _log.warning(
                    "onchain cache refresh retry failed for event id=%d: %s", row["id"], exc2
                )
                continue
        except Exception as exc:  # noqa: BLE001 -- one bad row must not block the rest
            _log.warning("onchain cache refresh failed for event id=%d: %s", row["id"], exc)
            continue
        if verified != bool(row["onchain_verified_cache"]):
            set_onchain_cache(conn, row["id"], verified)


#: verify_event's own RPC helper (src/reference_model.py's `_rpc_call`) opens a
#: fresh urllib.request connection per call rather than reusing a
#: requests.Session, so it isn't exposed to the stale-keep-alive-connection bug
#: `registry_client.py`'s retrying session was built for -- and it has no
#: retry-with-backoff of its own. This tick-level cap is what stands in for
#: that: a genuinely failing event gets retried a bounded number of times,
#: spread ~15s apart, before this loop gives up on it.
MAX_REFERENCE_MODEL_ATTEMPTS = 3


def _verify_reference_model_for_l1_confirmed(conn) -> None:
    """Run the independent reference-model recomputation (`verify_event`) on
    every `l1_confirmed` event that doesn't have a `reference_model_hash` yet.

    This writes only `reference_model_hash` (and, on failure,
    `reference_model_verify_attempts`) to SQLite -- no on-chain call, no
    private key involved. `recordVerification()` stays a deliberate, manual,
    human-run step (see docs/recordVerification-checklist.md); this function
    must never be extended to submit anything on-chain.

    Guarded by `reference_model_hash IS NULL` rather than re-running every
    tick: the reference model's inputs (the token's on-chain log/state at a
    fixed historical block) don't change after the fact, so a hash computed
    once for a given event never needs to be recomputed. A row that keeps
    failing (RPC errors, not mismatches -- verify_event catches those and
    returns `sha256=None` rather than raising) stops being retried after
    `MAX_REFERENCE_MODEL_ATTEMPTS`, and only the first failure logs at
    WARNING -- the rest log at DEBUG -- so a persistently-broken RPC endpoint
    doesn't spam whatever forwards WARNING+ logs onward.
    """
    for event in get_events_by_status(conn, "l1_confirmed"):
        event_id = event["id"]
        if event["reference_model_hash"]:
            continue
        if event["reference_model_verify_attempts"] >= MAX_REFERENCE_MODEL_ATTEMPTS:
            continue  # already gave up on this row; stay silent

        try:
            result = verify_event(conn, event_id)
        except Exception as exc:  # noqa: BLE001 -- one bad row must not block the rest
            result = None
            rpc_failure_detail = str(exc)
        else:
            rpc_failure_detail = (
                result.mismatches[0] if result.sha256 is None and result.mismatches else None
            )

        if result is None or result.sha256 is None:
            attempts = increment_reference_model_attempts(conn, event_id)
            log_fn = _log.warning if attempts == 1 else _log.debug
            log_fn(
                "reference model verify failed for event id=%d (attempt %d/%d): %s",
                event_id, attempts, MAX_REFERENCE_MODEL_ATTEMPTS, rpc_failure_detail,
            )
            if attempts >= MAX_REFERENCE_MODEL_ATTEMPTS:
                _log.warning(
                    "reference model verify: giving up on event id=%d after %d attempts",
                    event_id, MAX_REFERENCE_MODEL_ATTEMPTS,
                )
            continue

        if not result.match:
            _log.warning(
                "reference model MISMATCH for event id=%d: %s", event_id, result.mismatches
            )


async def state_machine_loop(conn, get_current_block, registry: set[bytes]) -> None:
    """Periodically advance every non-terminal event through filter_verifier and
    l1_confirmer, in that order, then independently re-verify newly-l1_confirmed
    events against the reference model, refresh the display-only on-chain
    cache, and rescan the token factory for newly-deployed tokens.

    `registry` is the exact set object FilterEngine.registry points to;
    refresh_registry() mutates it in place, so a token deployed while this
    process is running gets picked up on the next tick -- no restart needed.
    """
    while True:
        await asyncio.sleep(STATE_MACHINE_INTERVAL_SECONDS)
        current_block = get_current_block()
        if current_block == 0:
            continue  # feed hasn't produced a block yet

        # These are blocking RPC calls, run synchronously on the event loop. Not
        # farmed out to a thread: the sqlite3.Connection is created on this thread
        # and is not safe to share with another. At this check-in cadence and
        # event volume, a brief pause here is not worth the added complexity --
        # websocket frames queue in the OS socket buffer while we're busy.
        for event in get_pending_events(conn):
            filter_verifier_check(conn, event, current_block)

        for event in get_events_by_status(conn, "confirmed_not_filtered"):
            l1_confirmer_check(conn, event)

        _verify_reference_model_for_l1_confirmed(conn)
        _refresh_onchain_cache(conn)
        refresh_registry(registry)


async def run(url: str = MAINNET_FEED) -> None:
    conn = connect()
    registry = build_registry()
    engine = FilterEngine(registry)

    shared_state = {"current_block": 0}

    async def feed() -> None:
        consumer = FeedConsumer(url)
        async for msg in consumer.live():
            shared_state["current_block"] = msg.seq
            print(f"seq={msg.seq} txs={len(msg.txs)}")
            for tx in msg.txs:
                if engine.check(tx, msg.seq):
                    insert_pending_event(conn, tx.to, tx.hash, msg.seq)

    async with asyncio.TaskGroup() as tg:
        tg.create_task(feed())
        tg.create_task(
            state_machine_loop(conn, lambda: shared_state["current_block"], engine.registry)
        )


def main() -> None:
    logging.basicConfig(level=logging.INFO)
    asyncio.run(run())


if __name__ == "__main__":
    main()
