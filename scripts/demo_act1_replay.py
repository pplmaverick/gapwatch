"""Act 1 opening replay for the Gapwatch demo video -- terminal-friendly,
paced playback of the six real corporate-action events (SOXX/TSM/PR/HPE/CRM/SPY)
already verified by scripts/backfill_new_token_events.py.

Read-only, presentation-only script: no chain writes, no db writes. It reuses
KNOWN_EVENTS from scripts.backfill_new_token_events for the real
tx_hash/block_number/multiplier values (not re-derived here) and reads
events.db for the reference_model_hash/status each event already has on
record, so nothing printed here is invented -- it is either the real
KNOWN_EVENTS data or a value read back from this repo's own verification
pipeline output.

The one number this script computes itself, rather than reusing a stored
value, is "how many hours before entering monitoring": events.db's
`detected_at` only records when this backfill (or its predecessor run) wrote
the row, not when the real corporate-action event happened on-chain. So this
queries the real block timestamp for each event's block_number, plus the
chain's current block timestamp as "now", via one read-only eth_getBlockByNumber
call per block (mainnet RPC) -- both are live on-chain facts, not estimates.

Usage:
    uv run python -m scripts.demo_act1_replay
"""

from __future__ import annotations

import json
import sqlite3
import time
import urllib.request

from scripts.backfill_new_token_events import KNOWN_EVENTS, RPC_URL
from src.event_store import DEFAULT_DB_PATH

STEP_DELAY_SECONDS = 0.7


def _rpc_call(method: str, params: list) -> dict:
    payload = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
    req = urllib.request.Request(
        RPC_URL,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "User-Agent": "gapwatch-demo/0.1"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = json.loads(resp.read())
    if "error" in body:
        raise RuntimeError(f"{method} failed: {body['error']}")
    return body["result"]


def _block_timestamp(block_number: int) -> int:
    result = _rpc_call("eth_getBlockByNumber", [hex(block_number), False])
    return int(result["timestamp"], 16)


def _short(value: str, head: int = 6, tail: int = 4) -> str:
    # value is expected to start with "0x"; head includes the "0x" prefix.
    return f"{value[:head]}...{value[-tail:]}"


def _fmt_multiplier(raw: int) -> str:
    return f"{raw / 1e18:.9f}"


def _load_db_rows(tx_hashes: list[str]) -> dict[str, sqlite3.Row]:
    conn = sqlite3.connect(DEFAULT_DB_PATH)
    conn.row_factory = sqlite3.Row
    placeholders = ",".join("?" for _ in tx_hashes)
    rows = conn.execute(
        f"SELECT tx_hash, status, reference_model_hash FROM events "
        f"WHERE tx_hash IN ({placeholders})",
        tx_hashes,
    ).fetchall()
    conn.close()
    return {row["tx_hash"]: row for row in rows}


def main() -> None:
    events = sorted(KNOWN_EVENTS, key=lambda e: e.block_number)  # discovery order

    db_rows = _load_db_rows([e.tx_hash for e in events])
    missing = [e.symbol for e in events if e.tx_hash not in db_rows]
    if missing:
        raise RuntimeError(
            f"events.db has no verified row for: {missing} -- run "
            "scripts.backfill_new_token_events first"
        )

    now_block = _rpc_call("eth_blockNumber", [])
    now_ts = _block_timestamp(int(now_block, 16))

    print("Gapwatch -- Act 1: six real events the live feed never saw")
    print()

    gaps_hours = []
    total = len(events)
    for i, event in enumerate(events, start=1):
        row = db_rows[event.tx_hash]
        verified = row["status"] == "l1_confirmed" and row["reference_model_hash"] is not None

        event_ts = _block_timestamp(event.block_number)
        gap_hours = (now_ts - event_ts) / 3600
        gaps_hours.append(gap_hours)

        mark = "✓ verified" if verified else "✗ NOT verified"
        print(
            f"[{i}/{total}] {event.symbol:<5} {_short(event.token_address)}   "
            f"multiplier {_fmt_multiplier(event.old_multiplier)} -> "
            f"{_fmt_multiplier(event.new_multiplier)}   {mark}"
        )
        time.sleep(STEP_DELAY_SECONDS)

    verified_count = sum(
        1
        for event in events
        if db_rows[event.tx_hash]["status"] == "l1_confirmed"
        and db_rows[event.tx_hash]["reference_model_hash"] is not None
    )
    oldest_gap = max(gaps_hours)
    print()
    print(
        f"{verified_count}/{total} events verified — oldest one sat on-chain "
        f"{oldest_gap:.1f} hours ({oldest_gap / 24:.1f} days) before entering "
        f"monitoring (real block timestamps, not estimated)"
    )


if __name__ == "__main__":
    main()
