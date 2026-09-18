"""Dynamic token registry: which stock token contracts exist, discovered via the
Robinhood Chain token factory's deployment events, filtered through a symbol
safety allowlist before being trusted for monitoring.

Replaces an earlier, indirect approach (scanning every address on chain for
UIMultiplierUpdated and treating anything that ever emitted one as a token)
with a direct one: FACTORY_ADDRESS emits one TokenDeployed-shaped event per
token it creates, carrying (address, name, symbol) directly in the log data.
Verified 2026-09-18 against a full-history scan (this RPC has no eth_getLogs
block-range limit): all 22 previously-known token addresses -- discovered
indirectly, before this module existed -- appear among the factory's 204
total deployment events, so switching to this direct source loses no
coverage. The factory's own EIP-1967 implementation slot is currently
zeroed (any eth_call to it reverts), so replaying its historical event log
is not a fallback here -- it is the only way to query it at all.

The beacon address shared by every Stock.sol proxy for role checks
(0xe10b6f6b275de231345c20d14ab812db62151b00) was investigated first and
ruled out: it is a compliance blocklist + AccessControl module the tokens
delegate role checks to, not a factory, and exposes no token-enumeration
interface of any kind.
"""

from __future__ import annotations

import json
import logging
import re
import urllib.request
from pathlib import Path
from urllib.error import URLError

from eth_abi import decode as abi_decode
from rhfeed import addr

_log = logging.getLogger("gapwatch.token_registry")

RPC_URL = "https://rpc.mainnet.chain.robinhood.com"

# topic0 = keccak256("UIMultiplierUpdated(uint256,uint256,uint256)"). Kept here
# (not moved or renamed) because l1_confirmer.py imports it from this module
# for an unrelated purpose: confirming one already-known tx's own log, not
# discovering which addresses are tokens.
UI_MULTIPLIER_UPDATED_TOPIC0 = (
    "0x2205df4534432b2f60654a3fdb48737ffdaf3e9edb1a498bd985bc026b15b055"
)

#: The Robinhood Chain stock-token factory (an EIP-1967 proxy). Confirmed by
#: tracing a known token's (JNJ, 0x03dfbbe0ac4e7bcdafd08ed41a400326b77d8c80)
#: construction transaction back to its `to` address.
FACTORY_ADDRESS = "0x4783c67b63de2b358ac5951a7d41f47a38f3c046"

# topic0 of the factory's deployment event. Exact signature string not
# recovered (the factory's implementation slot is zeroed, so it can no
# longer be introspected live), but the topic0 hash and its ABI-decoded
# payload shape -- (address token, string name, string symbol) -- are both
# confirmed empirically against all 204 historical emissions.
TOKEN_DEPLOYED_TOPIC0 = (
    "0xd9b0c6a1c0de228715ad0fa09f3259686ee84f8cc675e03ef7e47a9cdafa76d6"
)

#: A trusted symbol looks like a real ticker: 1-6 uppercase letters/digits,
#: optionally with one ".X" or ".XX" suffix (e.g. "BRK.A"). Tunable -- kept
#: as a module-level constant rather than inlined so the threshold can be
#: adjusted without touching the scan logic.
TICKER_RE = re.compile(r"^[A-Z0-9]{1,6}(\.[A-Z0-9]{1,2})?\Z")

#: Substrings (case-insensitive) that disqualify a symbol regardless of
#: TICKER_RE, for factory deployments that are clearly test/placeholder
#: tokens rather than real stock tokens. Verified against real data: this
#: (together with the underscore check) is exactly what rejects
#: "PEACH_DEFI_1", the one deployment out of 204 that isn't a real stock
#: token.
BLOCKLIST_SUBSTRINGS = ("DEFI", "TEST", "MOCK", "DEMO", "DUMMY", "SAMPLE")

DEFAULT_STATE_PATH = Path(__file__).resolve().parent.parent / "data" / "token_registry_state.json"


def is_valid_symbol(symbol: str) -> tuple[bool, str | None]:
    """Safety filter for a factory-reported symbol. Returns (ok, reason);
    reason is None when ok is True, otherwise names which rule rejected it --
    kept explicit so a rejected token's `pending_review` entry says why."""
    if "_" in symbol:
        return False, "underscore"
    upper = symbol.upper()
    for keyword in BLOCKLIST_SUBSTRINGS:
        if keyword in upper:
            return False, f"blocklisted keyword {keyword}"
    if not TICKER_RE.match(symbol):
        return False, "format mismatch"
    return True, None


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


def _eth_get_logs(
    rpc_url: str, address: str, topic0: str, from_block: int, to_block: int
) -> list[dict]:
    """Scoped to a single contract address -- every caller here already knows
    which address it wants (the factory), unlike the old address-agnostic
    scan this replaces."""
    return _rpc_call(
        rpc_url,
        "eth_getLogs",
        [
            {
                "address": address,
                "fromBlock": hex(from_block),
                "toBlock": hex(to_block),
                "topics": [topic0],
            }
        ],
    )


def _decode_token_deployed(log: dict) -> tuple[bytes, str, str]:
    """ABI-decode one TokenDeployed-shaped log's data into (address, name, symbol)."""
    data = bytes.fromhex(log["data"].removeprefix("0x"))
    token_address, name, symbol = abi_decode(["address", "string", "string"], data)
    return addr(token_address), name, symbol


def _load_state(state_path: Path) -> tuple[int | None, dict[bytes, dict], dict[bytes, dict]]:
    if not state_path.exists():
        return None, {}, {}
    data = json.loads(state_path.read_text())

    if "last_scanned_factory_block" in data:
        last_scanned_factory_block = data.get("last_scanned_factory_block")
        tokens = {addr(a): meta for a, meta in data.get("tokens", {}).items()}
        pending_review = {addr(a): meta for a, meta in data.get("pending_review", {}).items()}
        return last_scanned_factory_block, tokens, pending_review

    # Pre-migration file (old schema: last_scanned_block/addresses, built by
    # scanning UIMultiplierUpdated on every address). That scanner tracked a
    # different event and address scope entirely, so its last_scanned_block
    # is not a valid resume point for the factory scan -- start that at 0.
    # The addresses it already found are kept as already-approved,
    # metadata-less entries so monitoring does not regress while the fresh
    # factory scan (which will enrich them with real symbol/name once it
    # reaches their deployment block) catches up.
    legacy_addresses = data.get("addresses", [])
    _log.info(
        "migrating token_registry_state.json from the old UIMultiplierUpdated "
        "scan format: keeping %d already-known address(es), starting the "
        "factory scan fresh from block 0",
        len(legacy_addresses),
    )
    tokens = {
        addr(a): {"symbol": None, "name": None, "source": "legacy_migrated"}
        for a in legacy_addresses
    }
    return None, tokens, {}


def _save_state(
    state_path: Path,
    last_scanned_factory_block: int,
    tokens: dict[bytes, dict],
    pending_review: dict[bytes, dict],
) -> None:
    state_path.parent.mkdir(parents=True, exist_ok=True)
    data = {
        "last_scanned_factory_block": last_scanned_factory_block,
        "tokens": {"0x" + a.hex(): meta for a, meta in sorted(tokens.items())},
        "pending_review": {"0x" + a.hex(): meta for a, meta in sorted(pending_review.items())},
    }
    state_path.write_text(json.dumps(data, indent=2))


def _scan_factory(
    rpc_url: str, state_path: Path
) -> tuple[dict[bytes, dict], dict[bytes, dict]]:
    """Incrementally scan FACTORY_ADDRESS for new TokenDeployed events since the
    last successful scan, apply is_valid_symbol() to each, and persist the
    updated tokens/pending_review sets.

    Same resumability contract as the scanner this replaces: on RPC failure
    the persisted last_scanned_factory_block is left untouched so the next
    call resumes from the same point, and the previously known sets are still
    returned so a transient failure never blanks the registry.
    """
    last_scanned_factory_block, tokens, pending_review = _load_state(state_path)
    from_block = 0 if last_scanned_factory_block is None else last_scanned_factory_block + 1

    try:
        latest = _eth_block_number(rpc_url)
        if from_block > latest:
            # Nothing new since the last successful scan; no RPC log query needed.
            return tokens, pending_review
        logs = _eth_get_logs(rpc_url, FACTORY_ADDRESS, TOKEN_DEPLOYED_TOPIC0, from_block, latest)
    except (URLError, TimeoutError, RuntimeError) as exc:
        _log.warning(
            "token registry factory scan failed (range %d -> latest, resuming "
            "from %d next time): %s",
            from_block,
            from_block,
            exc,
        )
        return tokens, pending_review

    newly_approved = 0
    for log in logs:
        try:
            token_address, name, symbol = _decode_token_deployed(log)
        except Exception as exc:  # noqa: BLE001 -- one malformed log must not block the rest
            _log.warning(
                "could not decode TokenDeployed log at tx=%s: %s",
                log.get("transactionHash"),
                exc,
            )
            continue

        ok, reason = is_valid_symbol(symbol)
        meta = {"symbol": symbol, "name": name, "block_number": int(log["blockNumber"], 16)}
        if ok:
            if token_address not in tokens:
                newly_approved += 1
            tokens[token_address] = meta
            pending_review.pop(token_address, None)
        else:
            meta["reason"] = reason
            pending_review[token_address] = meta
            _log.warning(
                "token registry: rejected factory deployment symbol=%r name=%r "
                "address=0x%s reason=%s -- held in pending_review, not monitored",
                symbol,
                name,
                token_address.hex(),
                reason,
            )

    _save_state(state_path, latest, tokens, pending_review)
    if logs:
        _log.info(
            "token registry factory scan: blocks %d -> %d, %d event(s), %d "
            "newly approved, %d total approved, %d pending review",
            from_block,
            latest,
            len(logs),
            newly_approved,
            len(tokens),
            len(pending_review),
        )
    return tokens, pending_review


def build_registry(rpc_url: str = RPC_URL, state_path: Path = DEFAULT_STATE_PATH) -> set[bytes]:
    """Startup entry point: scan the factory (full history on first run, only
    new blocks on later runs) and return the set of approved token addresses
    ready to hand to FilterEngine. See refresh_registry() for the periodic,
    in-place variant used by the running feed loop.
    """
    tokens, _pending_review = _scan_factory(rpc_url, state_path)
    return set(tokens.keys())


def refresh_registry(
    registry: set[bytes], rpc_url: str = RPC_URL, state_path: Path = DEFAULT_STATE_PATH
) -> int:
    """Periodic entry point for the running feed loop (state_machine_loop):
    incrementally rescan the factory and merge any newly-approved token
    addresses directly into `registry` (mutated in place via `.update()`, never
    reassigned), so a FilterEngine already holding a reference to this exact
    set object picks up new tokens without being reconstructed or the process
    being restarted. Returns how many new addresses were added.
    """
    tokens, _pending_review = _scan_factory(rpc_url, state_path)
    added = set(tokens.keys()) - registry
    if added:
        registry.update(added)
        _log.warning(
            "token registry: %d new token address(es) added to the live "
            "registry without a restart: %s",
            len(added),
            ", ".join("0x" + a.hex() for a in sorted(added)),
        )
    return len(added)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    registry = build_registry()
    print(f"{len(registry)} token addresses found")
    for a in sorted(registry):
        print("0x" + a.hex())
