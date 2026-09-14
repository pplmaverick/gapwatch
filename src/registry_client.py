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
"""

from __future__ import annotations

import json
from pathlib import Path

from web3 import Web3

TESTNET_RPC = "https://rpc.testnet.chain.robinhood.com"
MAINNET_RPC = "https://rpc.mainnet.chain.robinhood.com"

REGISTRY_ADDRESS = "0x53f10f96e3F6443e67Af2F1b01144B7e325f006d"
POOL_ADDRESS = "0xF764f545B4e6fF8755EEDEE64A0CFCf2Ec08a671"

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
