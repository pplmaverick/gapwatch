"""Shared web3.py wiring for talking to the on-chain contracts.

Two separate chains are involved, which is a real quirk of this demo setup,
not a bug: GapwatchRegistry (V1) and MockLendingPool are deployed on Robinhood
Chain *Testnet* (cheap to iterate on), but the stock tokens they verify data
about are real contracts on Robinhood Chain *Mainnet*. Anything that reads V1's
`verifications`/`latestVerificationForToken`/etc. must use the testnet RPC;
anything that reads a token's own state (`balanceOfUI`, `uiMultiplier`) must
use the mainnet RPC. Mixing them up produces a clean "contract not found"
style failure, not silently wrong data, but it's worth being deliberate
about which `w3` a given call uses.

The Tier 3 `GapwatchRegistryV2` adds a third combination: it is on *mainnet*,
alongside the tokens but separate from V1. `registry_v2_contract` is pinned
there and does not follow `NETWORK`, because both registries have to be
readable in the same process -- the testnet backfill event stays on display
while V2 is still empty. `registry_contract` remains the `NETWORK`-selected
path and still defaults to testnet V1, so nothing that reads it today moves.

Contract addresses are never hardcoded here or anywhere else in the codebase
-- they come from `deployment.json` at the project root, the one
git-tracked, authoritative record of "what's deployed where" (matching the
deployment-address cross-check discipline this project follows). An
environment variable can override the network selection or the whole
deployment file path for local experimentation, but the default path is
always this checked-in file, never a value copy-pasted into a second place.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry
from web3 import Web3

DEFAULT_DEPLOYMENT_PATH = Path(__file__).resolve().parent.parent / "deployment.json"

#: Which network's contract addresses/RPC this process talks to for
#: GapwatchRegistry/MockLendingPool. Overridable for local testing against a
#: future re-deploy without editing source.
NETWORK = os.environ.get("GAPWATCH_NETWORK", "testnet")

_ABI_DIR = Path(__file__).resolve().parent / "abi"
_REGISTRY_ABI = json.loads((_ABI_DIR / "GapwatchRegistry.json").read_text())
_REGISTRY_V2_ABI = json.loads((_ABI_DIR / "GapwatchRegistryV2.json").read_text())
_POOL_ABI = json.loads((_ABI_DIR / "MockLendingPool.json").read_text())

#: `deployment.json` names the registry differently per network -- testnet
#: carries V1 as `GapwatchRegistry`, mainnet carries Tier 3 as
#: `GapwatchRegistryV2` -- so the key is resolved per network rather than
#: assumed. Order matters: V1 first, so testnet keeps resolving exactly as it
#: always has even if a `GapwatchRegistryV2` is ever added alongside it there.
_REGISTRY_ABIS = {
    "GapwatchRegistry": _REGISTRY_ABI,
    "GapwatchRegistryV2": _REGISTRY_V2_ABI,
}

# Minimal ERC-8056 fragment -- only what the API needs, not a full token ABI.
_BALANCE_OF_UI_ABI = [
    {
        "name": "balanceOfUI",
        "type": "function",
        "stateMutability": "view",
        "inputs": [{"name": "account", "type": "address"}],
        "outputs": [{"name": "", "type": "uint256"}],
    }
]

#: `request_kwargs={"headers": ...}` replaces web3's default headers outright
#: rather than merging, so Content-Type has to be spelled out here too --
#: otherwise the RPC gets a POST with no Content-Type and returns 415.
#: User-Agent is set because Cloudflare's bot check (error 1010) rejects
#: default HTTP client user-agents outright.
_HEADERS = {"Content-Type": "application/json", "User-Agent": "gapwatch-api/0.1"}


def _build_retrying_session() -> requests.Session:
    """A fresh `requests.Session` per `Web3` instance, passed as `HTTPProvider`'s
    explicit `session=` so it bypasses web3.py's own process-wide session cache
    (keyed by thread id + URL, kept forever) -- that cache is exactly what was
    handing every call a `requests.Session` whose pooled keep-alive connection
    the RPC server had already closed server-side, surfacing as
    `http.client.RemoteDisconnected`.

    `allowed_methods=None` is required, not cosmetic: urllib3's `Retry` default
    only retries methods it considers idempotent (GET/HEAD/etc), and JSON-RPC is
    POST-only, so the out-of-the-box default silently never retried an RPC call
    at all. Note this is also why web3.py's own built-in retry
    (`exception_retry_configuration`) doesn't save us here either: its default
    error tuple checks the *builtin* `ConnectionError`, not
    `requests.exceptions.ConnectionError` (which is what a dropped keep-alive
    connection actually raises) -- the two are unrelated classes, so that retry
    path never triggers for this failure.
    """
    session = requests.Session()
    retry = Retry(total=3, backoff_factor=0.5, allowed_methods=None)
    adapter = HTTPAdapter(max_retries=retry)
    session.mount("http://", adapter)
    session.mount("https://", adapter)
    return session


def _load_deployment() -> dict[str, Any]:
    path = Path(os.environ.get("GAPWATCH_DEPLOYMENT_PATH", DEFAULT_DEPLOYMENT_PATH))
    data = json.loads(path.read_text())
    if NETWORK not in data:
        raise KeyError(f"deployment.json has no network {NETWORK!r} (checked {path})")
    return data


_deployment = _load_deployment()
_network_config = _deployment[NETWORK]

TESTNET_RPC = _deployment["testnet"]["rpc_url"]
MAINNET_RPC = _deployment["mainnet"]["rpc_url"]


def _resolve_registry(network_config: dict[str, Any], network: str) -> tuple[str, str]:
    """Pick the registry `deployment.json` actually records for `network`.

    Returns `(deployment_key, address)`. Resolving the key rather than hardcoding
    `"GapwatchRegistry"` is what stops `GAPWATCH_NETWORK=mainnet` from raising
    KeyError at import time and taking the whole process down before it serves a
    single request -- mainnet has never had a `GapwatchRegistry` entry.
    """
    for key in _REGISTRY_ABIS:
        entry = network_config.get(key)
        if entry is not None:
            return key, entry["address"]
    raise KeyError(
        f"deployment.json network {network!r} has no registry entry "
        f"(looked for {', '.join(_REGISTRY_ABIS)})"
    )


_REGISTRY_KEY, REGISTRY_ADDRESS = _resolve_registry(_network_config, NETWORK)
POOL_ADDRESS = _network_config["MockLendingPool"]["address"]

#: The Tier 3 registry is deployed only on mainnet, so its path is pinned there
#: rather than following `NETWORK`. That is deliberate: the V1 and V2 paths must
#: be usable *at the same time* -- the testnet NVDA backfill event stays
#: readable for demo purposes while V2 is brought online -- so V2 cannot be
#: expressed as "whichever network NETWORK happens to point at".
V2_NETWORK = "mainnet"
REGISTRY_V2_ADDRESS = _deployment[V2_NETWORK]["GapwatchRegistryV2"]["address"]


def testnet_w3() -> Web3:
    return Web3(
        Web3.HTTPProvider(
            TESTNET_RPC,
            request_kwargs={"headers": _HEADERS},
            session=_build_retrying_session(),
        )
    )


def mainnet_w3() -> Web3:
    return Web3(
        Web3.HTTPProvider(
            MAINNET_RPC,
            request_kwargs={"headers": _HEADERS},
            session=_build_retrying_session(),
        )
    )


def registry_contract(w3: Web3):
    """The registry for whichever network `NETWORK` selects (default: testnet V1).

    Pairs the address with the ABI matching the deployment key it resolved from,
    so a mainnet selection gets the V2 ABI rather than V1's applied to a V2
    address.
    """
    return w3.eth.contract(
        address=Web3.to_checksum_address(REGISTRY_ADDRESS), abi=_REGISTRY_ABIS[_REGISTRY_KEY]
    )


def registry_v2_contract(w3: Web3):
    """The Tier 3 `GapwatchRegistryV2` on mainnet, regardless of `NETWORK`.

    Caller must pass a mainnet `w3` (see `mainnet_w3`); handing this a testnet
    provider reads an address that holds no code there.
    """
    return w3.eth.contract(
        address=Web3.to_checksum_address(REGISTRY_V2_ADDRESS), abi=_REGISTRY_V2_ABI
    )


def pool_contract(w3: Web3):
    return w3.eth.contract(address=Web3.to_checksum_address(POOL_ADDRESS), abi=_POOL_ABI)


def token_contract(w3: Web3, token_address: str):
    return w3.eth.contract(address=Web3.to_checksum_address(token_address), abi=_BALANCE_OF_UI_ABI)


def event_hash_to_bytes32(tx_hash: str) -> bytes:
    return Web3.to_bytes(hexstr=tx_hash)
