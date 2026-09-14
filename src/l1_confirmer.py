"""Final confirmation step: does the token's UIMultiplierUpdated log really carry
this tx hash?

Runs on `confirmed_not_filtered` events. Reuses the same `eth_getLogs` call
`token_registry` already makes, scoped to the token address and the event's own
block, rather than a broad historical scan.
"""

from __future__ import annotations

import logging
import sqlite3
from urllib.error import URLError

from src.event_store import update_status
from src.token_registry import RPC_URL, UI_MULTIPLIER_UPDATED_TOPIC0, _rpc_call
from rhfeed import addr

_log = logging.getLogger("gapwatch.l1_confirmer")

#: How many blocks either side of the detected block to search, in case the log
#: lands a block or two off from where the tx was first seen on the feed.
BLOCK_WINDOW = 3


def _find_matching_log(
    token_address: str, tx_hash: str, block_number: int, rpc_url: str
) -> dict | None:
    from_block = max(block_number - BLOCK_WINDOW, 0)
    to_block = block_number + BLOCK_WINDOW
    logs = _rpc_call(
        rpc_url,
        "eth_getLogs",
        [
            {
                "fromBlock": hex(from_block),
                "toBlock": hex(to_block),
                "address": token_address,
                "topics": [UI_MULTIPLIER_UPDATED_TOPIC0],
            }
        ],
    )
    tx_hash = tx_hash.lower()
    for log in logs:
        if log["transactionHash"].lower() == tx_hash:
            return log
    return None


def check_event(conn: sqlite3.Connection, event: sqlite3.Row, rpc_url: str = RPC_URL) -> None:
    """Confirm one `confirmed_not_filtered` event landed on L1, or leave it as-is."""
    event_id = event["id"]
    tx_hash = event["tx_hash"]
    old_status = event["status"]

    try:
        # addr() validates the stored address is well-formed before we spend an
        # RPC call on it -- a corrupt row should not repeatedly hit the network.
        addr(event["token_address"])
        log = _find_matching_log(
            event["token_address"], tx_hash, event["block_number"], rpc_url
        )
    except (URLError, TimeoutError, RuntimeError) as exc:
        _log.warning("L1 confirmation check failed for tx=%s: %s (leaving status unchanged)", tx_hash, exc)
        return
    except ValueError as exc:
        _log.warning("L1 confirmation skipped for tx=%s: bad token address: %s", tx_hash, exc)
        return

    if log is None:
        # Not found (yet, or ever -- e.g. a hand-inserted fake tx). Left in
        # `confirmed_not_filtered`; the next scheduled pass tries again rather
        # than retrying in a tight loop.
        _log.info("no matching L1 log yet for tx=%s (token=%s)", tx_hash, event["token_address"])
        return

    update_status(conn, event_id, "l1_confirmed")
    _log.warning(
        "STATUS CHANGE tx=%s %s -> l1_confirmed (matched L1 log tx=%s)",
        tx_hash,
        old_status,
        log["transactionHash"],
    )
