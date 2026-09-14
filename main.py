"""Gapwatch entrypoint: feed listener -> filter engine hot path."""

from __future__ import annotations

import asyncio
import logging

from rhfeed import MAINNET_FEED, FeedConsumer

from src.filter_engine import FilterEngine
from src.token_registry import build_registry

_log = logging.getLogger("gapwatch.main")


async def run(url: str = MAINNET_FEED) -> None:
    registry = build_registry()
    engine = FilterEngine(registry)

    consumer = FeedConsumer(url)
    async for msg in consumer.live():
        print(f"seq={msg.seq} txs={len(msg.txs)}")
        for tx in msg.txs:
            engine.check(tx, msg.seq)


def main() -> None:
    logging.basicConfig(level=logging.INFO)
    asyncio.run(run())


if __name__ == "__main__":
    main()
