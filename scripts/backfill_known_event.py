"""One-off, auditable replay of a known real historical event through the
exact same verification functions the live pipeline uses --
filter_verifier.check_event(), l1_confirmer.check_event(), and
reference_model.verify_event() -- so it ends up in events.db with the same
columns a live catch would have, except `source`, which this script sets to
`historical_backfill` instead of leaving it at the schema default
(`live_detection`).

Why this script exists: on 2026-09-14, events.db contained one row for this
same token/tx/block with `detected_at` five days after the real on-chain
broadcast time, and a full pending -> l1_confirmed transition completed in
4.45 seconds -- not reachable through main.py's real state-machine loop,
which sleeps 15s between iterations and can only advance
`filter_check_count` by 1 per iteration. That row was therefore written by
some undocumented one-off process, not the live listener. This script is the
sanctioned replacement: anyone auditing events.db can now find, in git
history, exactly what produced any `historical_backfill` row and why.

Scope, deliberately narrow: this replays the *off-chain* verification path
only (filter check, L1 log confirmation, reference model recompute). It does
NOT call GapwatchRegistry.recordVerification() -- that requires the
relayer's private key and is a separate, manual on-chain step outside this
script's responsibility (and outside this codebase entirely; grep the repo
and the only callers of recordVerification are Foundry tests).

Usage (run as a module from the repo root, so `src` resolves):
    uv run python -m scripts.backfill_known_event [--db-path PATH]
"""

from __future__ import annotations

import argparse
import json
import logging
import time
import urllib.request
from pathlib import Path

from src.event_store import (
    DEFAULT_DB_PATH,
    connect,
    get_event_by_id,
    insert_pending_event,
    set_source,
)
from src.filter_verifier import check_event as filter_verifier_check
from src.l1_confirmer import check_event as l1_confirmer_check
from src.reference_model import verify_event

logging.basicConfig(level=logging.INFO)
_log = logging.getLogger("gapwatch.backfill")

RPC_URL = "https://rpc.mainnet.chain.robinhood.com"

# Real, already-broadcast Robinhood Chain mainnet event -- not fabricated.
# Confirmed 2026-09-14 by cross-referencing the known real broadcast/effective
# times against detected_at/last_checked_at timing (see module docstring).
TOKEN_ADDRESS = "0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC"
TX_HASH = "0x4ac23f2e58e2c4962dcd701c2beff581e87f3995152a29d527c07a3afd67d956"
BLOCK_NUMBER = 58952659
KNOWN_BROADCAST_AT = "2026-09-09T23:50:42Z"
KNOWN_EFFECTIVE_AT = "2026-09-10T00:00:30Z"
KNOWN_OLD_MULTIPLIER = "1.0"
KNOWN_NEW_MULTIPLIER = "1.000775159164630595"

MAX_FILTER_CHECK_ITERATIONS = 10
MAX_L1_CONFIRM_ITERATIONS = 10


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


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db-path", type=Path, default=DEFAULT_DB_PATH)
    args = parser.parse_args()

    _log.info("backfilling known historical event into %s", args.db_path)
    _log.info(
        "token=%s tx=%s block=%d real_broadcast_at=%s real_effective_at=%s "
        "multiplier=%s->%s (real on-chain values, not fabricated)",
        TOKEN_ADDRESS,
        TX_HASH,
        BLOCK_NUMBER,
        KNOWN_BROADCAST_AT,
        KNOWN_EFFECTIVE_AT,
        KNOWN_OLD_MULTIPLIER,
        KNOWN_NEW_MULTIPLIER,
    )

    conn = connect(args.db_path)
    event_id = insert_pending_event(conn, TOKEN_ADDRESS, TX_HASH, BLOCK_NUMBER)
    set_source(conn, event_id, "historical_backfill")
    _log.info("inserted event id=%d, source=historical_backfill", event_id)

    # Drive it through the real filter_verifier state machine: REQUIRED_FALSE_STREAK
    # (3) consecutive `false` results from the live isTransactionFiltered()
    # precompile, spaced by real chain-block progress (MIN_BLOCKS_BETWEEN_CHECKS) --
    # exactly the same function main.py's state_machine_loop calls. The only
    # difference from that loop is pacing: this checks back-to-back with a short
    # sleep instead of a full 15s between iterations, because it is a documented
    # one-off replay, not a long-running monitor -- it is not trying to look like
    # one, and the `historical_backfill` source tag says so explicitly.
    for _ in range(MAX_FILTER_CHECK_ITERATIONS):
        event = get_event_by_id(conn, event_id)
        if event["status"] in ("confirmed_not_filtered", "filtered", "l1_confirmed"):
            break
        current_block = _eth_block_number(RPC_URL)
        filter_verifier_check(conn, event, current_block)
        time.sleep(1)
    else:
        raise RuntimeError(
            f"event id={event_id} did not reach a terminal filter-check status "
            f"after {MAX_FILTER_CHECK_ITERATIONS} iterations"
        )

    event = get_event_by_id(conn, event_id)
    if event["status"] == "filtered":
        _log.warning(
            "event id=%d came back FILTERED by the live precompile -- stopping here, "
            "this is not the confirmable event we expected",
            event_id,
        )
        return

    # L1 confirmation: find the real UIMultiplierUpdated log for this exact tx.
    for _ in range(MAX_L1_CONFIRM_ITERATIONS):
        event = get_event_by_id(conn, event_id)
        if event["status"] == "l1_confirmed":
            break
        l1_confirmer_check(conn, event)
        if get_event_by_id(conn, event_id)["status"] != "l1_confirmed":
            time.sleep(2)
    else:
        raise RuntimeError(
            f"event id={event_id} did not reach l1_confirmed after "
            f"{MAX_L1_CONFIRM_ITERATIONS} iterations -- no matching L1 log found"
        )

    _log.info("event id=%d reached l1_confirmed", event_id)

    # Reference Model: independent recomputation, self-contained, compared
    # against what filter_verifier/l1_confirmer concluded.
    result = verify_event(conn, event_id)
    _log.info("reference model match=%s sha256=%s", result.match, result.sha256)
    if not result.match:
        _log.warning("reference model mismatches: %s", result.mismatches)

    final = get_event_by_id(conn, event_id)
    _log.info(
        "done: event id=%d status=%s source=%s filter_check_count=%d "
        "reference_model_hash=%s",
        final["id"],
        final["status"],
        final["source"],
        final["filter_check_count"],
        final["reference_model_hash"],
    )


if __name__ == "__main__":
    main()
