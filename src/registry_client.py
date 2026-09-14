"""Shared web3.py wiring for talking to the on-chain contracts.

Two separate chains are involved, which is a real quirk of this demo setup,
not a bug: GapwatchRegistry and MockLendingPool are deployed on Robinhood
Chain *Testnet* (cheap to iterate on), but the stock tokens they verify data
about are real contracts on Robinhood Chain *Mainnet*. Anything that reads
`verifications`/`latestVerificationForToken`/etc. must use the testnet RPC;
anything that reads a token's own state (`balanceOfUI`, `uiMultiplier`) must
use the mainnet RPC. Mixing them up produces a clean "contract not found"
style failure, not silently wrong data, but it's worth being deliberate
about which `w3` a given call uses.

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

from web3 import Web3

DEFAULT_DEPLOYMENT_PATH = Path(__file__).resolve().parent.parent / "deployment.json"

#: Which network's contract addresses/RPC this process talks to for
#: GapwatchRegistry/MockLendingPool. Overridable for local testing against a
#: future re-deploy without editing source.
NETWORK = os.environ.get("GAPWATCH_NETWORK", "testnet")

_ABI_DIR = Path(__file__).resolve().parent / "abi"
_REGISTRY_ABI = json.loads((_ABI_DIR / "GapwatchRegistry.json").read_text())
_POOL_ABI = json.loads((_ABI_DIR / "MockLendingPool.json").read_text())

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

REGISTRY_ADDRESS = _network_config["GapwatchRegistry"]["address"]
POOL_ADDRESS = _network_config["MockLendingPool"]["address"]


def testnet_w3() -> Web3:
    return Web3(Web3.HTTPProvider(TESTNET_RPC, request_kwargs={"headers": _HEADERS}))


def mainnet_w3() -> Web3:
    return Web3(Web3.HTTPProvider(MAINNET_RPC, request_kwargs={"headers": _HEADERS}))


def registry_contract(w3: Web3):
    return w3.eth.contract(address=Web3.to_checksum_address(REGISTRY_ADDRESS), abi=_REGISTRY_ABI)


def pool_contract(w3: Web3):
    return w3.eth.contract(address=Web3.to_checksum_address(POOL_ADDRESS), abi=_POOL_ABI)


def token_contract(w3: Web3, token_address: str):
    return w3.eth.contract(address=Web3.to_checksum_address(token_address), abi=_BALANCE_OF_UI_ABI)


def event_hash_to_bytes32(tx_hash: str) -> bytes:
    return Web3.to_bytes(hexstr=tx_hash)
