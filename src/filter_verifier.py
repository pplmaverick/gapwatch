"""Checks candidate events against the ArbOS compliance-filtering precompile.

*** PRECOMPILE IDENTITY: CONFIRMED. FILTERING BEHAVIOR: CONFIRMED "EXCLUDE",
NOT "INVALIDATE AFTER SUCCESS". ROBINHOOD'S SPECIFIC IMPLEMENTATION: STILL
INFERENCE. READ BEFORE TOUCHING THESE CONSTANTS OR THIS MODULE'S FRAMING. ***

`isTransactionFiltered(bytes32)` selector `0x85c733a4` and precompile address
`0x0000000000000000000000000000000000000074` were originally sourced from a
single blog post with no official confirmation. That status is now resolved:
official Arbitrum Nitro source confirms both the address and the function.
`precompiles/ArbFilteredTransactionsManager.go` declares `Address addr // 0x74`
and implements `IsTransactionFiltered(c *Context, evm *vm.EVM, txHash
common.Hash) (bool, error)` reading from `filteredTransactions.Open(evm.StateDB,
c).IsFiltered(txHash)` -- the same backing store `AddFilteredTransaction`
writes to. This is a real, documented ArbOS precompile (available from ArbOS
version 60), not a guess. (github.com/OffchainLabs/nitro,
precompiles/ArbFilteredTransactionsManager.go and
precompiles/ArbFilteredTransactionsManager_test.go /
system_tests/filtered_transactions_test.go)

What is now also confirmed, and changes how a `true`/`false` result here
should be read: compliance filtering's general effect in Nitro is to EXCLUDE
the transaction from the block entirely, not to let it succeed and mark it
invalid afterward. In `arbos/block_processor.go`'s `ProduceBlockAdvanced`,
both `PreTxFilter` (before execution) and `PostTxFilter` (checked from within
the execution callback, after the state transition has run but before it is
kept) can fail; either failure takes the same path:

    if err != nil {
        buildState.statedb.RevertToSnapshot(snap)
        buildState.statedb.ClearTxFilter()
        return nil, nil, err
    }

-- the tx's state changes are rolled back and it is left out of the produced
block altogether. `system_tests/seq_filter_test.go`'s
`TestSequencerBlockFilterAccept`/`Reject` confirm this empirically: a filtered
tx is simply absent from `block.Transactions()`. So even though `PostTxFilter`
runs after simulating execution (it has to, to see which addresses/events a
tx touched), the end state is "never happened" -- no receipt, no logs,
indistinguishable via standard RPC from a tx that was never submitted. There
is no on-chain "succeeded, then later marked filtered" status to query.

What remains inference, not confirmation: Robinhood Chain's own compliance
logic for these specific stock tokens is not in the public nitro repo.
`arbos/extra_transaction_checks.go`'s `extraPreTxFilter`/`extraPostTxFilter`
are the documented chain-operator customization points for exactly this kind
of rule ("should be modified by chain operators to enforce additional
[pre/post]-transaction validity rules"), called from `block_processor.go`
right alongside the generic `PreTxFilter`/`PostTxFilter` hooks -- but in the
public repo they are empty stubs (`// TODO: implement additional ... checks;
return nil`). Whatever Robinhood actually put there lives in a private fork
we cannot read. It is a reasonable inference that Robinhood's real stock-token
compliance filtering runs through this same standard extension point (which
would inherit the same exclude-not-invalidate behavior above), but that is
inference about Robinhood's specific chain, not something confirmed the way
the precompile's existence and the generic exclude-on-filter behavior now are.
Keep these two confidence levels separate in anything user-facing.

Practical upshot for this module: a `true` result here means this generic,
manually-curated txHash blocklist (`addFilteredTransaction`, requiring an
authorized "filterer" role) has this hash in it -- confirmed real, but a
narrower and more manually-operated mechanism than whatever Robinhood's actual
per-transaction stock compliance logic runs on. Two live scans of on-chain
data (2026-09-12, 2026-09-13) found zero real `addFilteredTransaction` calls,
which is now easier to explain: this may simply not be the mechanism Robinhood
uses for routine compliance filtering.

Why the conservative multi-check design (unchanged by the above): whether a
transaction has been compliance-filtered may not be knowable immediately
after the tx is sequenced -- filtering is a separate step from sequencing,
and how much settling time it needs is undocumented. Two consecutive `false`
results checked back-to-back told us nothing: we could not distinguish
"genuinely not filtered" from "not filtered *yet*, check again later" from
live testing, since both look identical from here. So a single `false` moves
the event to `filter_check_in_progress` rather than a terminal state, and it
takes `REQUIRED_FALSE_STREAK` consecutive `false` results, spaced at least
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

# Confirmed via official Nitro source -- see module docstring.
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
    """Call the confirmed ArbFilteredTransactionsManager precompile for one tx
    hash. A narrower, manually-curated mechanism than Robinhood's actual
    compliance filtering is inferred to run on -- see module docstring."""
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
