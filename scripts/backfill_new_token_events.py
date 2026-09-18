"""One-off, auditable replay of six real historical UIMultiplierUpdated events
-- one each for SOXX, TSM, PR, HPE, CRM, SPY -- through the exact same
verification functions the live pipeline uses: filter_verifier.check_event(),
l1_confirmer.check_event(), and reference_model.verify_event(). Modeled
directly on scripts/backfill_known_event.py (the NVDA backfill); see that
script's docstring for the full rationale behind this replay approach.

Why this script exists: these six tokens were only added to the monitored
registry in this same change (via the new factory-event-based token_registry
scanner), so the live feed listener was never running while their one real
corporate-action event each was sequenced -- there is no way for the live
pipeline to have caught them, and no undocumented row to replace (unlike the
NVDA case). This is a first-time backfill of already-settled history, not a
correction.

tx_hash/block_number/multiplier values below were read directly from
eth_getLogs against the real Robinhood Chain mainnet RPC
(UIMultiplierUpdated topic0, full chain history, no block-range chunking --
this RPC has no eth_getLogs range limit) on 2026-09-18, not fabricated or
assumed. Each token had exactly one such event in its full history; none had
zero (i.e. none of the six turned out to have "no corporate action yet, same
as TSLA/AMZN" -- that was one of the possible outcomes going in, but is not
what was found).

Scope, deliberately narrow, same as the NVDA script: this replays the
*off-chain* verification path only (filter check, L1 log confirmation,
reference model recompute). It does NOT call
GapwatchRegistry.recordVerification() -- that requires the relayer's private
key and is a separate, manual on-chain step outside this script's
responsibility and outside this codebase entirely (grep the repo: the only
callers of recordVerification are Foundry tests). GapwatchRegistryV2 is not
touched at all.

Usage (run as a module from the repo root, so `src` resolves):
    uv run python -m scripts.backfill_new_token_events [--db-path PATH]
"""

from __future__ import annotations

import argparse
import json
import logging
import time
import urllib.request
from dataclasses import dataclass
from pathlib import Path

from src.event_store import DEFAULT_DB_PATH, connect, get_event_by_id, insert_pending_event, set_source
from src.filter_verifier import check_event as filter_verifier_check
from src.l1_confirmer import check_event as l1_confirmer_check
from src.reference_model import verify_event

logging.basicConfig(level=logging.INFO)
_log = logging.getLogger("gapwatch.backfill_new_tokens")

RPC_URL = "https://rpc.mainnet.chain.robinhood.com"

MAX_FILTER_CHECK_ITERATIONS = 10
MAX_L1_CONFIRM_ITERATIONS = 10


@dataclass(frozen=True)
class KnownEvent:
    symbol: str
    token_address: str
    tx_hash: str
    block_number: int
    old_multiplier: int
    new_multiplier: int
    effective_at: int  # unix seconds


# Read from eth_getLogs against real mainnet data on 2026-09-18 -- see module
# docstring. Not fabricated.
KNOWN_EVENTS = [
    KnownEvent(
        symbol="SOXX",
        token_address="0x75742c18bc1f1c5c5f448f4c9d9c6f66dafaaa38",
        tx_hash="0x25ca20c977b0e0c206bd48e76515c85e9971b7397d950059cff00500ba912269",
        block_number=64062899,
        old_multiplier=1000000000000000000,
        new_multiplier=1000450838210425960,
        effective_at=1789517433,
    ),
    KnownEvent(
        symbol="TSM",
        token_address="0x58ffe4a942d3885baa22d7520691f611ef09e7aa",
        tx_hash="0x53888b0500828784f8eb5e98b22e2becf1e5d9b00d4e48c26d0b440e08f34037",
        block_number=64062939,
        old_multiplier=1000000000000000000,
        new_multiplier=1001463024159690554,
        effective_at=1789517433,
    ),
    KnownEvent(
        symbol="PR",
        token_address="0x4189f0c66ebbb0bfef1c31f763131361ef32f77c",
        tx_hash="0x81f4f290ae140538cda6ff63538b3eb5aee01c04dac6e9acb0c6eff7cd91d4f7",
        block_number=64062986,
        old_multiplier=1000000000000000000,
        new_multiplier=1004477942292229526,
        effective_at=1789517433,
    ),
    KnownEvent(
        symbol="HPE",
        token_address="0x59dd09d4900c2e4b5f75b7c0d4e6796fcc234cb1",
        tx_hash="0x44d2c674d74b6bbb890c3e5822e909f4fe773b865bfe701ffa1612e757d0c1ea",
        block_number=64924198,
        old_multiplier=1000000000000000000,
        new_multiplier=1001716957939304938,
        effective_at=1789604133,
    ),
    KnownEvent(
        symbol="CRM",
        token_address="0xd95b44124e475743a7589e68f3d74008a5536d44",
        tx_hash="0xc6189b8fcc4e3e0a92fdd33b0c74c0646165112f113af6782866ca460c64edde",
        block_number=65383603,
        old_multiplier=1000000000000000000,
        new_multiplier=1001148322800714293,
        effective_at=1789650372,
    ),
    KnownEvent(
        symbol="SPY",
        token_address="0x117cc2133c37b721f49de2a7a74833232b3b4c0c",
        tx_hash="0x2fe45ab24d1b3fa87883f8b08daf29dae969c5b43d0afe9ccca299c11a641025",
        block_number=65779981,
        old_multiplier=1000000000000000000,
        new_multiplier=1001717991187472003,
        effective_at=1789690233,
    ),
]


def _eth_block_number(rpc_url: str) -> int:
    payload = {"jsonrpc": "2.0", "id": 1, "method": "eth_blockNumber", "params": []}
    req = urllib.request.Request(
        rpc_url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "User-Agent": "gapwatch-backfill/0.1"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = json.loads(resp.read())
    return int(body["result"], 16)


def backfill_one(conn, event: KnownEvent) -> dict:
    """Replay one known event through the real pipeline functions. Returns a
    summary dict for the final per-token report -- never raises to abort the
    whole run early; a failure on one token must not block the other five.
    """
    _log.info(
        "backfilling %s token=%s tx=%s block=%d multiplier=%s->%s",
        event.symbol,
        event.token_address,
        event.tx_hash,
        event.block_number,
        event.old_multiplier,
        event.new_multiplier,
    )

    event_id = insert_pending_event(conn, event.token_address, event.tx_hash, event.block_number)
    set_source(conn, event_id, "historical_backfill")

    summary = {
        "symbol": event.symbol,
        "token_address": event.token_address,
        "tx_hash": event.tx_hash,
        "event_id": event_id,
        "status": None,
        "reference_model_match": None,
        "reference_model_mismatches": [],
        "anomalies": [],
    }

    # Filter check: REQUIRED_FALSE_STREAK consecutive `false` from the live
    # isTransactionFiltered() precompile, same function/thresholds
    # state_machine_loop uses -- only the pacing differs (documented replay,
    # not a long-running monitor).
    for _ in range(MAX_FILTER_CHECK_ITERATIONS):
        ev = get_event_by_id(conn, event_id)
        if ev["status"] in ("confirmed_not_filtered", "filtered", "l1_confirmed"):
            break
        current_block = _eth_block_number(RPC_URL)
        filter_verifier_check(conn, ev, current_block)
        time.sleep(1)
    else:
        summary["status"] = "FAILED: filter check never reached a terminal status"
        summary["anomalies"].append("filter_check_timeout")
        return summary

    ev = get_event_by_id(conn, event_id)
    if ev["status"] == "filtered":
        summary["status"] = "FILTERED (compliance-filtered by the live precompile)"
        summary["anomalies"].append("came_back_filtered")
        return summary

    # L1 confirmation: find the real UIMultiplierUpdated log for this exact tx.
    for _ in range(MAX_L1_CONFIRM_ITERATIONS):
        ev = get_event_by_id(conn, event_id)
        if ev["status"] == "l1_confirmed":
            break
        l1_confirmer_check(conn, ev)
        if get_event_by_id(conn, event_id)["status"] != "l1_confirmed":
            time.sleep(2)
    else:
        summary["status"] = "FAILED: never reached l1_confirmed"
        summary["anomalies"].append("l1_confirm_timeout")
        return summary

    # Reference Model: independent recomputation.
    result = verify_event(conn, event_id)
    summary["reference_model_match"] = result.match
    summary["reference_model_mismatches"] = result.mismatches

    final = get_event_by_id(conn, event_id)
    summary["status"] = final["status"]
    summary["filter_check_count"] = final["filter_check_count"]
    summary["reference_model_hash"] = final["reference_model_hash"]

    # Pattern check against the five already-known real events (NVDA plus
    # the four earlier ones already in events.db): flag anything that
    # doesn't look like the same multiplier/filter shape rather than
    # silently accepting it.
    if event.old_multiplier != 1000000000000000000:
        summary["anomalies"].append(
            f"old_multiplier is not 1.0 ({event.old_multiplier}) -- unlike every "
            "previously-seen event, this was not this token's first adjustment"
        )
    if not result.match:
        summary["anomalies"].append("reference model mismatch: see reference_model_mismatches")

    return summary


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db-path", type=Path, default=DEFAULT_DB_PATH)
    args = parser.parse_args()

    conn = connect(args.db_path)
    results = []
    for event in KNOWN_EVENTS:
        try:
            results.append(backfill_one(conn, event))
        except Exception as exc:  # noqa: BLE001 -- one token's failure must not stop the rest
            _log.error("backfill of %s raised: %s", event.symbol, exc)
            results.append(
                {
                    "symbol": event.symbol,
                    "token_address": event.token_address,
                    "tx_hash": event.tx_hash,
                    "status": f"FAILED: exception: {exc}",
                    "anomalies": ["unhandled_exception"],
                }
            )

    _log.info("=== backfill summary ===")
    for r in results:
        _log.info(json.dumps(r, indent=2, default=str))


if __name__ == "__main__":
    main()
