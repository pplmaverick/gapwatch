"""Module 1: connect to the Robinhood Chain sequencer feed and decode frames.

Thin wrapper around `rhfeed.FeedConsumer`, which already implements the header,
reconnect/backoff, and dedup/reorg handling this needs. Standalone, this just
prints per-message tx counts to stdout; `main.py` wires its decoded txs into the
filter engine's hot path instead.
"""

from __future__ import annotations

import asyncio
import logging

from rhfeed import MAINNET_FEED, FeedConsumer

_log = logging.getLogger("gapwatch.feed_listener")


async def watch(url: str = MAINNET_FEED) -> None:
    """Connect and print a line per decoded message. Standalone module-1 test."""
    consumer = FeedConsumer(url)
    async for msg in consumer.live():
        print(f"seq={msg.seq} txs={len(msg.txs)}")


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    asyncio.run(watch())
