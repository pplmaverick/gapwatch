"""Checks candidate events against the ArbOS compliance-filtering precompile.

*** UNCONFIRMED SOURCE — READ BEFORE TOUCHING THESE CONSTANTS ***
`isTransactionFiltered(bytes32)` selector `0x85c733a4` and precompile address
`0x0000000000000000000000000000000000000074` come from a single blog post that
is NOT confirmed by any official Robinhood/Offchain Labs documentation. The only
thing actually verified in this codebase is that calling it with these values
against a known-successful, unfiltered tx (NVDA, block 58,952,659) returns
`false` without erroring. That is weak evidence: an unrelated function at the
same address happening to accept a bytes32 and return a bool would look
identical. Treat every result from this module as provisional until a
filtered tx is observed returning `true`, or Robinhood documents the
precompile. If this ever starts erroring or returning nonsense, the selector
or address is the first thing to suspect, not the caller's tx hash.

Why the conservative multi-check design: whether a transaction has been
compliance-filtered may not be knowable immediately after the tx is sequenced
-- filtering is a separate step from sequencing, and how much settling time it
needs is undocumented. Two consecutive `false` results checked back-to-back
told us nothing: we could not distinguish "genuinely not filtered" from "not
filtered *yet*, check again later" from live testing, since both look
identical from here. So a single `false` moves the event to
`filter_check_in_progress` rather than a terminal state, and it takes
`REQUIRED_FALSE_STREAK` consecutive `false` results, spaced at least
`MIN_BLOCKS_BETWEEN_CHECKS` apart, before we call it `confirmed_not_filtered`.
A `true` result, on the other hand, is trusted immediately -- there is no
"maybe filtered later" failure mode symmetric to it, and a filtered tx is the
most valuable evidence this tool can produce, so it is never left sitting in
an intermediate state.
"""

from __future__ import annotations

import json
import logging
import sqlite3
import urllib.request
from urllib.error import URLError

from src.event_store import update_status
from src.token_registry import RPC_URL

_log = logging.getLogger("gapwatch.filter_verifier")

# See the module docstring: unconfirmed, single-source.
FILTER_PRECOMPILE_ADDRESS = "0x0000000000000000000000000000000000000074"
IS_TRANSACTION_FILTERED_SELECTOR = "0x85c733a4"

#: Consecutive `false` results required before calling it confirmed-not-filtered.
REQUIRED_FALSE_STREAK = 3
#: Minimum blocks that must separate two checks, so consecutive checks are not
#: just re-asking the same still-settling question a few seconds apart.
MIN_BLOCKS_BETWEEN_CHECKS = 2


def _eth_call(rpc_url: str, to: str, data: str) -> str:
    payload = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "eth_call",
        "params": [{"to": to, "data": data}, "latest"],
    }
    req = urllib.request.Request(
        rpc_url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "User-Agent": "gapwatch/0.1"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = json.loads(resp.read())
    if "error" in body:
        raise RuntimeError(f"eth_call failed: {body['error']}")
    return body["result"]


def is_transaction_filtered(tx_hash: str, rpc_url: str = RPC_URL) -> bool:
    """Call the (unconfirmed) filter precompile for one tx hash. See module docstring."""
    tx_hash_word = tx_hash.removeprefix("0x").rjust(64, "0")
    data = IS_TRANSACTION_FILTERED_SELECTOR + tx_hash_word
    result = _eth_call(rpc_url, FILTER_PRECOMPILE_ADDRESS, data)
    # abi-encoded bool: 32-byte word, nonzero = true.
    return int(result, 16) != 0


def check_event(conn: sqlite3.Connection, event: sqlite3.Row, current_block: int) -> None:
    """Run one filter-verifier step against a single pending/in-progress event."""
    event_id = event["id"]
    tx_hash = event["tx_hash"]
    old_status = event["status"]

    last_checked_block = event["last_checked_block"]
    if last_checked_block is not None and current_block - last_checked_block < (
        MIN_BLOCKS_BETWEEN_CHECKS
    ):
        return

    try:
        filtered = is_transaction_filtered(tx_hash)
    except (URLError, TimeoutError, RuntimeError) as exc:
        _log.warning("filter check failed for tx=%s: %s (leaving status unchanged)", tx_hash, exc)
        return

    if filtered:
        update_status(
            conn, event_id, "filtered", increment_filter_check_count=True, checked_at_block=current_block
        )
        _log.warning("STATUS CHANGE tx=%s %s -> filtered (compliance-filtered!)", tx_hash, old_status)
        return

    new_count = event["filter_check_count"] + 1
    if new_count >= REQUIRED_FALSE_STREAK:
        update_status(
            conn,
            event_id,
            "confirmed_not_filtered",
            increment_filter_check_count=True,
            checked_at_block=current_block,
        )
        _log.info(
            "STATUS CHANGE tx=%s %s -> confirmed_not_filtered (%d consecutive false)",
            tx_hash,
            old_status,
            new_count,
        )
    else:
        update_status(
            conn,
            event_id,
            "filter_check_in_progress",
            increment_filter_check_count=True,
            checked_at_block=current_block,
        )
        _log.info(
            "STATUS CHANGE tx=%s %s -> filter_check_in_progress (false, %d/%d)",
            tx_hash,
            old_status,
            new_count,
            REQUIRED_FALSE_STREAK,
        )
