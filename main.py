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
    insert_pending_event,
    set_onchain_cache,
)
from src.filter_engine import FilterEngine
from src.filter_verifier import check_event as filter_verifier_check
from src.l1_confirmer import check_event as l1_confirmer_check
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


async def state_machine_loop(conn, get_current_block, registry: set[bytes]) -> None:
    """Periodically advance every non-terminal event through filter_verifier and
    l1_confirmer, in that order, then refresh the display-only on-chain cache
    and rescan the token factory for newly-deployed tokens.

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
