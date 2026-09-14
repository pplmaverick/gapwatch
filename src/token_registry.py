"""Dynamic token registry: which contracts have ever emitted UIMultiplierUpdated.

Built via `eth_getLogs` against the public Robinhood Chain RPC, and persisted to a
small local JSON file so repeat calls only scan the block range since the last
successful scan instead of re-scanning from block 0 every time. That matters
regardless of RPC provider: it keeps query ranges small against a public endpoint
prone to timeouts/429s, and avoids burning unnecessary CU against a paid one.
"""

from __future__ import annotations

import json
import logging
import urllib.request
from pathlib import Path
from urllib.error import URLError

from rhfeed import addr

_log = logging.getLogger("gapwatch.token_registry")

RPC_URL = "https://rpc.mainnet.chain.robinhood.com"

# topic0 = keccak256("UIMultiplierUpdated(uint256,uint256,uint256)")
UI_MULTIPLIER_UPDATED_TOPIC0 = (
    "0x2205df4534432b2f60654a3fdb48737ffdaf3e9edb1a498bd985bc026b15b055"
)

DEFAULT_STATE_PATH = Path(__file__).resolve().parent.parent / "data" / "token_registry_state.json"


def _rpc_call(rpc_url: str, method: str, params: list) -> object:
    payload = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
    req = urllib.request.Request(
        rpc_url,
        data=json.dumps(payload).encode(),
        headers={
            "Content-Type": "application/json",
            # Cloudflare's bot check (error 1010) rejects the default
            # Python-urllib user-agent string outright.
            "User-Agent": "gapwatch/0.1",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = json.loads(resp.read())
    if "error" in body:
        raise RuntimeError(f"{method} failed: {body['error']}")
    return body["result"]


def _eth_block_number(rpc_url: str) -> int:
    return int(_rpc_call(rpc_url, "eth_blockNumber", []), 16)


def _eth_get_logs(rpc_url: str, topic0: str, from_block: int, to_block: int) -> list[dict]:
    return _rpc_call(
        rpc_url,
        "eth_getLogs",
        [
            {
                "fromBlock": hex(from_block),
                "toBlock": hex(to_block),
                "topics": [topic0],
            }
        ],
    )


def _load_state(state_path: Path) -> tuple[int | None, set[bytes]]:
    if not state_path.exists():
        return None, set()
    data = json.loads(state_path.read_text())
    last_scanned_block = data.get("last_scanned_block")
    addresses = {addr(a) for a in data.get("addresses", [])}
    return last_scanned_block, addresses


def _save_state(state_path: Path, last_scanned_block: int, addresses: set[bytes]) -> None:
    state_path.parent.mkdir(parents=True, exist_ok=True)
    data = {
        "last_scanned_block": last_scanned_block,
        "addresses": sorted("0x" + a.hex() for a in addresses),
    }
    state_path.write_text(json.dumps(data, indent=2))


def build_registry(
    rpc_url: str = RPC_URL, state_path: Path = DEFAULT_STATE_PATH
) -> set[bytes]:
    """Return the set of token addresses that have ever emitted `UIMultiplierUpdated`.

    First call (no persisted state): scans block 0 -> latest.
    Later calls: scans only `last_scanned_block + 1` -> latest, and merges newly
    found addresses into the persisted set rather than rebuilding it.

    On failure (timeout, rate limit, etc.), the persisted `last_scanned_block` is
    left untouched so the next call resumes from the same point instead of
    silently skipping the blocks in between. The previously known address set is
    still returned so a transient RPC failure doesn't blank the registry.

    Addresses are returned as raw 20-byte values (via `rhfeed.addr`) so they can be
    compared directly against `Tx.to_bytes` on the hot path without a checksum hash.
    """
    last_scanned_block, registry = _load_state(state_path)
    from_block = 0 if last_scanned_block is None else last_scanned_block + 1

    try:
        latest = _eth_block_number(rpc_url)
        if from_block > latest:
            # Nothing new since the last successful scan; no RPC log query needed.
            return registry
        logs = _eth_get_logs(rpc_url, UI_MULTIPLIER_UPDATED_TOPIC0, from_block, latest)
    except (URLError, TimeoutError, RuntimeError) as exc:
        _log.warning(
            "token registry refresh failed (range %d -> latest, resuming from %d "
            "next time): %s",
            from_block,
            from_block,
            exc,
        )
        return registry

    new_addresses = {addr(log["address"]) for log in logs}
    registry |= new_addresses
    _save_state(state_path, latest, registry)
    _log.info(
        "token registry refreshed: scanned blocks %d -> %d, %d new address(es) "
        "from %d event(s), %d total",
        from_block,
        latest,
        len(new_addresses),
        len(logs),
        len(registry),
    )
    return registry


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    registry = build_registry()
    print(f"{len(registry)} token addresses found")
    for a in sorted(registry):
        print("0x" + a.hex())
