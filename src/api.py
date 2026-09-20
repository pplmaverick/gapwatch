"""Gapwatch API: modules 6+7.

Two very different sources of truth, deliberately not blended:

- Screen B (live pipeline status: pending/filter_check_in_progress/
  confirmed_not_filtered/l1_confirmed) comes from `event_store` (SQLite) --
  that state machine only exists off-chain, there is nothing on-chain to
  check it against.
- Anything claiming a record is "verified", or describing a challenge, is
  read live from GapwatchRegistry on every request that returns it. SQLite's
  `onchain_verified_cache` column exists purely so `GET /events` can paint a
  fast approximate icon in a list view; the moment a caller wants an answer
  they might rely on, `GET /events/{id}` re-checks the chain directly and
  ignores the cache entirely. Never invert this.
"""

from __future__ import annotations

import json
import sqlite3

from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from requests.exceptions import RequestException
from web3.exceptions import Web3Exception

from src.event_store import DEFAULT_DB_PATH, STATUSES, connect, get_all_events, get_event_by_id
from src.registry_client import (
    event_hash_to_bytes32,
    mainnet_w3,
    registry_contract,
    registry_v2_contract,
    testnet_w3,
)
from src.token_registry import DEFAULT_STATE_PATH

app = FastAPI(
    title="Gapwatch API",
    description="Independent on-chain verification for Robinhood Chain corporate actions",
)

# Every endpoint here is a public, unauthenticated read of public blockchain/SQLite
# data (no cookies, no auth headers) -- wildcard CORS is safe and avoids re-locking
# this down every time the frontend's deployment origin changes.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["GET"],
    allow_headers=["*"],
)


def _db() -> sqlite3.Connection:
    return connect(DEFAULT_DB_PATH)


def _load_token_names() -> dict[str, dict]:
    """Read the token registry's auto-discovered symbol/name straight from
    `token_registry_state.json` -- the same file `token_registry.py`'s
    factory scanner writes, keyed by lowercase address. Read fresh on every
    call (the file is small and the live feed listener updates it while
    this process runs) rather than cached at import time, so a newly
    discovered token's name shows up without an API restart. Missing or
    unparseable file degrades to "no names known" rather than a 500 --
    callers already have a token_address to fall back to."""
    try:
        data = json.loads(DEFAULT_STATE_PATH.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}
    return data.get("tokens", {})


def _event_to_dict(row: sqlite3.Row, token_names: dict[str, dict] | None = None) -> dict:
    meta = (token_names or {}).get(row["token_address"].lower())
    return {
        "id": row["id"],
        "token_address": row["token_address"],
        "symbol": meta.get("symbol") if meta else None,
        "name": meta.get("name") if meta else None,
        "tx_hash": row["tx_hash"],
        "block_number": row["block_number"],
        "detected_at": row["detected_at"],
        "status": row["status"],
        "filter_check_count": row["filter_check_count"],
        "last_checked_at": row["last_checked_at"],
        "reference_model_hash": row["reference_model_hash"],
        "onchain_verified_cache": bool(row["onchain_verified_cache"])
        if row["onchain_verified_cache"] is not None
        else None,
        "onchain_cache_updated_at": row["onchain_cache_updated_at"],
        "source": row["source"],
    }


def _rpc_error(exc: Exception) -> HTTPException:
    return HTTPException(status_code=503, detail=f"on-chain read failed: {exc}")


@app.get("/events")
def list_events(limit: int = Query(50, ge=1, le=500), offset: int = Query(0, ge=0)):
    """Screen B: live pipeline status, straight from SQLite."""
    conn = _db()
    rows = get_all_events(conn)
    page = rows[offset : offset + limit]
    token_names = _load_token_names()
    return {
        "total": len(rows),
        "limit": limit,
        "offset": offset,
        "events": [_event_to_dict(r, token_names) for r in page],
    }


#: Which registry a read is answered from. Both stay reachable on purpose:
#: V1 on testnet still holds the NVDA backfill event the demo shows, while V2
#: on mainnet is live but empty. `v1` is the default so every existing caller
#: -- including the deployed frontend, which sends no such parameter -- keeps
#: getting exactly the bytes it gets today.
REGISTRY_SOURCES = ("v1", "v2")

_REGISTRY_SOURCE_QUERY = Query(
    "v1",
    pattern="^(v1|v2)$",
    description="v1 = GapwatchRegistry on testnet (default); v2 = GapwatchRegistryV2 on mainnet",
)


def _registry_for(source: str):
    """Resolve a `registry=` value to a live contract handle.

    Each branch pairs the contract with the chain it is actually deployed on;
    there is no combination where the caller picks those independently.
    """
    if source == "v2":
        return registry_v2_contract(mainnet_w3())
    return registry_contract(testnet_w3())


@app.get("/events/{event_id}")
def get_event(event_id: int, registry_source: str = _REGISTRY_SOURCE_QUERY):
    """One event's pipeline status, plus a live on-chain check -- never the cache."""
    conn = _db()
    row = get_event_by_id(conn, event_id)
    if row is None:
        raise HTTPException(status_code=404, detail=f"no event with id {event_id}")

    result = _event_to_dict(row, _load_token_names())
    result["onchain"] = None

    try:
        registry = _registry_for(registry_source)
        event_hash = event_hash_to_bytes32(row["tx_hash"])
        verification = registry.functions.getVerification(event_hash).call()
        recorded_at = verification[5]
        if recorded_at != 0:
            result["onchain"] = {
                "registry_version": registry_source,
                "registry_address": registry.address,
                "tx_hash_used_as_event_hash": row["tx_hash"],
                "token": verification[0],
                "old_multiplier": verification[1],
                "new_multiplier": verification[2],
                "was_filtered": verification[3],
                "reference_model_hash": "0x" + verification[4].hex(),
                "recorded_at": recorded_at,
                "bond": verification[6],
                "recorded_by": verification[7],
            }
    except (Web3Exception, RequestException, TimeoutError, ValueError) as exc:
        raise _rpc_error(exc) from exc

    return result


@app.get("/tokens/{token_address}/balance/{holder_address}")
def get_token_balance(token_address: str, holder_address: str):
    """Screen A: effective (UI-scaled) balance, read live from the token contract
    on mainnet -- never from a database."""
    try:
        w3 = mainnet_w3()
        token = w3.eth.contract(
            address=w3.to_checksum_address(token_address),
            abi=[
                {
                    "name": "balanceOfUI",
                    "type": "function",
                    "stateMutability": "view",
                    "inputs": [{"name": "account", "type": "address"}],
                    "outputs": [{"name": "", "type": "uint256"}],
                }
            ],
        )
        balance = token.functions.balanceOfUI(w3.to_checksum_address(holder_address)).call()
    except (Web3Exception, RequestException, TimeoutError, ValueError) as exc:
        raise _rpc_error(exc) from exc

    return {
        "token": token_address,
        "holder": holder_address,
        "balance_ui_raw": balance,
        "balance_ui": balance / 1e18,
    }


@app.get("/tokens/{token_address}/verification-status")
def get_token_verification_status(
    token_address: str, registry_source: str = _REGISTRY_SOURCE_QUERY
):
    """The core trust-minimized endpoint: reads GapwatchRegistry directly,
    nothing from SQLite. A caller does not have to trust this API's database --
    only the registry contract, whose address is public."""
    try:
        registry = _registry_for(registry_source)
        checksum_token = registry.w3.to_checksum_address(token_address)
        event_hash = registry.functions.latestVerificationForToken(checksum_token).call()

        if event_hash == b"\x00" * 32:
            return {
                "token": token_address,
                "registry_version": registry_source,
                "registry_address": registry.address,
                "ever_verified": False,
                "latest_event_hash": None,
                "has_discrepancy": None,
            }

        has_discrepancy = registry.functions.hasDiscrepancy(event_hash).call()
        verification = registry.functions.getVerification(event_hash).call()
    except (Web3Exception, RequestException, TimeoutError, ValueError) as exc:
        raise _rpc_error(exc) from exc

    return {
        "token": token_address,
        "registry_version": registry_source,
        "registry_address": registry.address,
        "ever_verified": True,
        "latest_event_hash": "0x" + event_hash.hex(),
        "has_discrepancy": has_discrepancy,
        "old_multiplier": verification[1],
        "new_multiplier": verification[2],
        "was_filtered": verification[3],
        "recorded_at": verification[5],
    }


@app.get("/audit-log")
def audit_log(status: str | None = Query(None)):
    """Screen C: every event ever detected, including filtered and never-confirmed
    ones. Straight from SQLite -- this is deliberately the full off-chain history,
    not filtered down to only what made it on-chain."""
    if status is not None and status not in STATUSES:
        raise HTTPException(
            status_code=400, detail=f"unknown status {status!r}; expected one of {STATUSES}"
        )
    conn = _db()
    rows = get_all_events(conn, status=status)
    token_names = _load_token_names()
    return {"count": len(rows), "events": [_event_to_dict(r, token_names) for r in rows]}
