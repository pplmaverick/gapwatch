"""Reference Model: an independent recomputation used to check module 3+4's
state-machine conclusions, not to produce them.

Deliberately self-contained. It does not import `token_registry`,
`filter_verifier`, or `l1_confirmer` -- it has its own RPC helper, its own
topic0, and its own log decoding. The only thing shared with the rest of the
pipeline is `event_store` (data access, not judgment) and the RPC endpoint
URL. If this module and module 3+4 agreed because they both called the same
verification function, agreeing would prove nothing; the point is that they
reach their conclusions by different paths and can still be compared.

What "independent path" means concretely: module 3+4 decides `l1_confirmed`
by finding *a* UIMultiplierUpdated log matching the tx hash. This module
additionally reads the token contract's *current* public state
(`uiMultiplier()` / `newUIMultiplier()` / `effectiveAt()`) and checks that,
once `effectiveAt` has passed, the live multiplier actually moved to the
value the log claims. A tx whose effect never reached the contract (e.g. it
was compliance-filtered after being sequenced, despite looking fine in the
feed) would fail this check even though a log existed -- which is
precisely the failure mode filter_verifier's conservative design exists to
guard against.
"""

from __future__ import annotations

import hashlib
import json
import logging
import sqlite3
from dataclasses import dataclass, field
from urllib.error import URLError

from src.event_store import get_event_by_id, set_reference_model_hash

_log = logging.getLogger("gapwatch.reference_model")

RPC_URL = "https://rpc.mainnet.chain.robinhood.com"

# topic0 = keccak256("UIMultiplierUpdated(uint256,uint256,uint256)"), computed
# independently here rather than imported from token_registry.
UI_MULTIPLIER_UPDATED_TOPIC0 = (
    "0x2205df4534432b2f60654a3fdb48737ffdaf3e9edb1a498bd985bc026b15b055"
)

# ERC-8056 selectors, computed independently (keccak256(sig)[:4]).
SELECTOR_UI_MULTIPLIER = "0xa60bf13d"  # uiMultiplier()
SELECTOR_NEW_UI_MULTIPLIER = "0xdc767007"  # newUIMultiplier()
SELECTOR_EFFECTIVE_AT = "0x97a4064f"  # effectiveAt()

# Multiplier is represented with 18 decimals (1e18 = 1.0), per ERC-8056.
MULTIPLIER_SCALE = 10**18

#: A representative raw balance used purely to demonstrate the scaling math;
#: this is not read from any real account.
SAMPLE_RAW_BALANCE = 1 * MULTIPLIER_SCALE


def _rpc_call(rpc_url: str, method: str, params: list) -> object:
    import urllib.request

    payload = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
    req = urllib.request.Request(
        rpc_url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "User-Agent": "gapwatch-reference-model/0.1"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = json.loads(resp.read())
    if "error" in body:
        raise RuntimeError(f"{method} failed: {body['error']}")
    return body["result"]


def _eth_call(rpc_url: str, to: str, selector: str) -> int:
    result = _rpc_call(rpc_url, "eth_call", [{"to": to, "data": selector}, "latest"])
    return int(result, 16)


def fetch_onchain_multiplier_state(token_address: str, rpc_url: str = RPC_URL) -> dict:
    """Read the token contract's *current* multiplier state directly -- not from
    any event log, from the contract's own public view functions."""
    return {
        "ui_multiplier": _eth_call(rpc_url, token_address, SELECTOR_UI_MULTIPLIER),
        "new_ui_multiplier": _eth_call(rpc_url, token_address, SELECTOR_NEW_UI_MULTIPLIER),
        "effective_at": _eth_call(rpc_url, token_address, SELECTOR_EFFECTIVE_AT),
    }


def fetch_event_log(token_address: str, block_number: int, rpc_url: str = RPC_URL) -> dict | None:
    """Independently re-fetch the UIMultiplierUpdated log for this token at this
    exact block, and decode oldMultiplier/newMultiplier/effectiveAtTimestamp."""
    logs = _rpc_call(
        rpc_url,
        "eth_getLogs",
        [
            {
                "fromBlock": hex(block_number),
                "toBlock": hex(block_number),
                "address": token_address,
                "topics": [UI_MULTIPLIER_UPDATED_TOPIC0],
            }
        ],
    )
    if not logs:
        return None
    log = logs[0]
    data = log["data"].removeprefix("0x")
    return {
        "tx_hash": log["transactionHash"],
        "old_multiplier": int(data[0:64], 16),
        "new_multiplier": int(data[64:128], 16),
        "effective_at": int(data[128:192], 16),
    }


def compute_effective_balance(raw_balance: int, multiplier: int) -> int:
    """(rawAmount * multiplier) / 1e18, truncating -- the ERC-8056 formula,
    reimplemented here rather than calling the contract's own toUIAmount()."""
    return (raw_balance * multiplier) // MULTIPLIER_SCALE


def _current_block_timestamp(rpc_url: str) -> int:
    block = _rpc_call(rpc_url, "eth_getBlockByNumber", ["latest", False])
    return int(block["timestamp"], 16)


@dataclass
class ReferenceResult:
    match: bool
    sha256: str | None
    mismatches: list[str] = field(default_factory=list)
    record: dict | None = None


def recompute(
    token_address: str, block_number: int, rpc_url: str = RPC_URL
) -> tuple[dict, list[str]]:
    """Independently rebuild everything this event implies, plus a list of any
    internal inconsistencies found along the way (not compared to event_store
    yet -- that happens in verify_event)."""
    problems: list[str] = []

    log = fetch_event_log(token_address, block_number, rpc_url)
    if log is None:
        problems.append(
            f"no UIMultiplierUpdated log found independently for token={token_address} "
            f"at block={block_number}"
        )
        log = {"tx_hash": None, "old_multiplier": None, "new_multiplier": None, "effective_at": None}

    onchain = fetch_onchain_multiplier_state(token_address, rpc_url)

    if log["effective_at"] is not None:
        now = _current_block_timestamp(rpc_url)
        if now >= log["effective_at"] and onchain["ui_multiplier"] != log["new_multiplier"]:
            problems.append(
                f"effectiveAt ({log['effective_at']}) has passed but on-chain "
                f"uiMultiplier() ({onchain['ui_multiplier']}) does not match the "
                f"log's newMultiplier ({log['new_multiplier']}) -- the update in "
                f"the log never actually took effect on-chain"
            )

    effective_balance_before = (
        compute_effective_balance(SAMPLE_RAW_BALANCE, log["old_multiplier"])
        if log["old_multiplier"] is not None
        else None
    )
    effective_balance_after = (
        compute_effective_balance(SAMPLE_RAW_BALANCE, log["new_multiplier"])
        if log["new_multiplier"] is not None
        else None
    )

    record = {
        "token_address": token_address.lower(),
        "block_number": block_number,
        "log_tx_hash": log["tx_hash"].lower() if log["tx_hash"] else None,
        "old_multiplier": log["old_multiplier"],
        "new_multiplier": log["new_multiplier"],
        "effective_at": log["effective_at"],
        "onchain_ui_multiplier": onchain["ui_multiplier"],
        "onchain_new_ui_multiplier": onchain["new_ui_multiplier"],
        "onchain_effective_at": onchain["effective_at"],
        "sample_raw_balance": SAMPLE_RAW_BALANCE,
        "sample_effective_balance_before": effective_balance_before,
        "sample_effective_balance_after": effective_balance_after,
    }
    return record, problems


def _hash_record(record: dict) -> str:
    canonical = json.dumps(record, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode()).hexdigest()


def verify_event(conn: sqlite3.Connection, event_id: int, rpc_url: str = RPC_URL) -> ReferenceResult:
    """Independently recompute event `event_id` and compare it against what
    module 3+4 recorded in event_store. Returns a `ReferenceResult` naming
    every field that disagreed, not just a boolean."""
    event = get_event_by_id(conn, event_id)
    if event is None:
        return ReferenceResult(match=False, sha256=None, mismatches=[f"no such event id {event_id}"])

    try:
        record, problems = recompute(event["token_address"], event["block_number"], rpc_url)
    except (URLError, TimeoutError, RuntimeError) as exc:
        return ReferenceResult(
            match=False, sha256=None, mismatches=[f"reference model RPC failure: {exc}"]
        )

    mismatches = list(problems)

    if record["log_tx_hash"] is None:
        mismatches.append("independent log lookup found nothing to compare tx_hash against")
    elif record["log_tx_hash"] != event["tx_hash"].lower():
        mismatches.append(
            f"tx_hash mismatch: event_store has {event['tx_hash']}, independent log "
            f"lookup found {record['log_tx_hash']}"
        )

    if event["status"] == "l1_confirmed" and record["log_tx_hash"] is None:
        mismatches.append(
            "event_store status is 'l1_confirmed' but the reference model could not "
            "independently find a matching log"
        )

    full_record = {
        # Deliberately NOT event_id: that's a SQLite AUTOINCREMENT primary
        # key, local to whichever events.db file this row happens to live
        # in -- it depends on insertion order, not on anything about the
        # real-world event. Two independent databases backfilling the same
        # real event in a different row order used to seal two different
        # hashes for identical on-chain facts, defeating the point of an
        # independently-reproducible hash. tx_hash is the one identifier
        # that's actually intrinsic to the event itself.
        "tx_hash": event["tx_hash"].lower(),
        "event_store_status": event["status"],
        **record,
    }
    sha256 = _hash_record(full_record)

    match = len(mismatches) == 0
    set_reference_model_hash(conn, event_id, sha256)
    _log.info(
        "verify_event id=%d match=%s sha256=%s%s",
        event_id,
        match,
        sha256,
        "" if match else f" mismatches={mismatches}",
    )
    return ReferenceResult(match=match, sha256=sha256, mismatches=mismatches, record=full_record)
