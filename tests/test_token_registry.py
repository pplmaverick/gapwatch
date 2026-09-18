"""Tests for the factory-based token registry: the symbol safety filter, and
the hot-reload path (refresh_registry mutating a live FilterEngine.registry
in place, without a restart).

No test suite existed for this project before this file -- there is nothing
prior to compare against or avoid breaking; this is new coverage for new
code. Uses only the standard library (unittest, unittest.mock) since the
project has no test framework dependency to build on.

Run with: uv run python -m unittest tests.test_token_registry -v
"""

from __future__ import annotations

import json
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

from eth_abi import encode as abi_encode

from src import token_registry


def _factory_log(block: int, token_address_hex: str, name: str, symbol: str) -> dict:
    """Build one TokenDeployed-shaped log the way _decode_token_deployed()
    expects to receive it from eth_getLogs -- same encoding real factory
    events use, verified against real on-chain data before this module was
    written."""
    data = abi_encode(["address", "string", "string"], [token_address_hex, name, symbol])
    return {
        "address": token_registry.FACTORY_ADDRESS,
        "blockNumber": hex(block),
        "data": "0x" + data.hex(),
        "transactionHash": "0x" + "11" * 32,
    }


class IsValidSymbolTests(unittest.TestCase):
    """Same rules verified in the prior investigation against all 204 real
    historical factory deployments (203 passed, only PEACH_DEFI_1 rejected).
    These are the unit-level cases behind that result."""

    def test_accepts_plain_ticker(self):
        self.assertEqual(token_registry.is_valid_symbol("NVDA"), (True, None))

    def test_accepts_single_letter_ticker(self):
        self.assertEqual(token_registry.is_valid_symbol("P"), (True, None))

    def test_accepts_dotted_ticker(self):
        self.assertEqual(token_registry.is_valid_symbol("BRK.A"), (True, None))

    def test_rejects_underscore(self):
        ok, reason = token_registry.is_valid_symbol("PEACH_DEFI_1")
        self.assertFalse(ok)
        self.assertEqual(reason, "underscore")

    def test_rejects_blocklisted_keyword(self):
        ok, reason = token_registry.is_valid_symbol("MOCKTOKEN")
        self.assertFalse(ok)
        self.assertIn("blocklisted keyword", reason)

    def test_rejects_too_long(self):
        ok, _reason = token_registry.is_valid_symbol("TOOLONGTICKER")
        self.assertFalse(ok)

    def test_rejects_lowercase(self):
        ok, reason = token_registry.is_valid_symbol("nvda")
        self.assertFalse(ok)
        self.assertEqual(reason, "format mismatch")


class HotReloadTests(unittest.TestCase):
    """Simulates a new token appearing in the factory's event log between two
    state_machine_loop iterations, with no process restart -- this is what
    the task asked to verify without waiting for a real on-chain deployment.
    """

    def setUp(self):
        self._tmpdir = TemporaryDirectory()
        self.state_path = Path(self._tmpdir.name) / "token_registry_state.json"
        self.token_a = bytes.fromhex("11" * 20)
        self.token_b = bytes.fromhex("22" * 20)

    def tearDown(self):
        self._tmpdir.cleanup()

    def test_refresh_registry_adds_new_token_without_reassigning_the_set(self):
        # First scan, like build_registry() at process startup: one known token.
        first_batch = [_factory_log(100, "0x" + self.token_a.hex(), "Alpha Corp", "ALFA")]
        with (
            patch.object(token_registry, "_eth_block_number", return_value=100),
            patch.object(token_registry, "_eth_get_logs", return_value=first_batch),
        ):
            registry = token_registry.build_registry(state_path=self.state_path)

        self.assertEqual(registry, {self.token_a})

        # Stand-in for what FilterEngine(registry) would hold a reference to.
        engine_registry = registry
        registry_object_id = id(engine_registry)

        # A new token gets deployed on-chain and shows up in the next
        # incremental scan window -- exactly what state_machine_loop's 15s
        # tick sees mid-run, with no restart involved.
        second_batch = [_factory_log(150, "0x" + self.token_b.hex(), "Beta Inc", "BETA")]
        with (
            patch.object(token_registry, "_eth_block_number", return_value=200),
            patch.object(token_registry, "_eth_get_logs", return_value=second_batch),
        ):
            added = token_registry.refresh_registry(engine_registry, state_path=self.state_path)

        self.assertEqual(added, 1)
        # Same set object -- a FilterEngine holding this reference sees the
        # update without being reconstructed or the process restarting.
        self.assertEqual(id(engine_registry), registry_object_id)
        self.assertIn(self.token_b, engine_registry)
        self.assertEqual(engine_registry, {self.token_a, self.token_b})

    def test_refresh_registry_routes_bad_symbol_to_pending_review_not_registry(self):
        with (
            patch.object(token_registry, "_eth_block_number", return_value=100),
            patch.object(token_registry, "_eth_get_logs", return_value=[]),
        ):
            registry = token_registry.build_registry(state_path=self.state_path)

        bad_batch = [_factory_log(150, "0x" + self.token_a.hex(), "Peach DeFi", "PEACH_DEFI_1")]
        with (
            patch.object(token_registry, "_eth_block_number", return_value=200),
            patch.object(token_registry, "_eth_get_logs", return_value=bad_batch),
        ):
            added = token_registry.refresh_registry(registry, state_path=self.state_path)

        self.assertEqual(added, 0)
        self.assertEqual(registry, set())

        state = json.loads(self.state_path.read_text())
        self.assertIn("0x" + self.token_a.hex(), state["pending_review"])
        self.assertNotIn("0x" + self.token_a.hex(), state["tokens"])

    def test_legacy_state_file_migrates_without_losing_known_addresses(self):
        self.state_path.write_text(
            json.dumps({"last_scanned_block": 12345, "addresses": ["0x" + self.token_a.hex()]})
        )
        with (
            patch.object(token_registry, "_eth_block_number", return_value=100),
            patch.object(token_registry, "_eth_get_logs", return_value=[]),
        ):
            registry = token_registry.build_registry(state_path=self.state_path)

        # Old address kept (monitoring doesn't regress), even though the
        # factory scan restarted from block 0 rather than resuming 12345.
        self.assertIn(self.token_a, registry)
        state = json.loads(self.state_path.read_text())
        self.assertEqual(state["tokens"]["0x" + self.token_a.hex()]["source"], "legacy_migrated")
        self.assertNotIn("last_scanned_block", state)
        self.assertIn("last_scanned_factory_block", state)


if __name__ == "__main__":
    unittest.main()
