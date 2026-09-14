"""Module 2: flag candidate corporate-action txs against the token registry.

Hot path only checks the cheap, eager `Tx` fields (`to_bytes`, `selector`) — never
`tx.sender`, which triggers ECDSA recovery.
"""

from __future__ import annotations

import datetime
import logging

from rhfeed import Tx, sel

_log = logging.getLogger("gapwatch.filter_engine")

# updateMultiplier(uint256,uint256) — the only version observed on-chain.
UPDATE_MULTIPLIER_SELECTOR = sel("0xbad60f18")
# Defensive comparison only; never observed in real usage.
UPDATE_MULTIPLIER_SELECTOR_ALT = sel("0x5ffe6146")

_SELECTORS = {UPDATE_MULTIPLIER_SELECTOR, UPDATE_MULTIPLIER_SELECTOR_ALT}


class FilterEngine:
    """Checks decoded txs against a token registry + known selectors."""

    def __init__(self, registry: set[bytes]) -> None:
        self.registry = registry
        self.hits = 0

    def check(self, tx: Tx, block: int) -> bool:
        """Return True (and log) if `tx` looks like a corporate-action call."""
        if tx.to_bytes is None or tx.selector not in _SELECTORS:
            return False
        if tx.to_bytes not in self.registry:
            return False

        self.hits += 1
        timestamp = datetime.datetime.now(datetime.UTC).isoformat()
        _log.warning(
            "CANDIDATE EVENT ts=%s token=%s tx=%s block=%d selector=%s",
            timestamp,
            tx.to,
            tx.hash,
            block,
            tx.selector_hex,
        )
        return True
