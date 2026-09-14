"""Gapwatch entrypoint: feed listener -> filter engine -> event state machine."""

from __future__ import annotations

import asyncio
import logging

from rhfeed import MAINNET_FEED, FeedConsumer

from src.event_store import connect, get_events_by_status, get_pending_events, insert_pending_event
from src.filter_engine import FilterEngine
from src.filter_verifier import check_event as filter_verifier_check
from src.l1_confirmer import check_event as l1_confirmer_check
from src.token_registry import build_registry

_log = logging.getLogger("gapwatch.main")

#: How often the state-machine loop wakes up to advance pending events.
STATE_MACHINE_INTERVAL_SECONDS = 15


async def state_machine_loop(conn, get_current_block) -> None:
    """Periodically advance every non-terminal event through filter_verifier and
    l1_confirmer, in that order."""
    while True:
        await asyncio.sleep(STATE_MACHINE_INTERVAL_SECONDS)
        current_block = get_current_block()
        if current_block == 0:
            continue  # feed hasn't produced a block yet

        # These are blocking RPC calls, run synchronously on the event loop. Not
        # farmed out to a thread: the sqlite3.Connection is created on this thread
        # and is not safe to share with another. At this check-in cadence and
        # event volume, a brief pause here is not worth the added complexity --
        # websocket frames queue in the OS socket buffer while we're busy.
        for event in get_pending_events(conn):
            filter_verifier_check(conn, event, current_block)

        for event in get_events_by_status(conn, "confirmed_not_filtered"):
            l1_confirmer_check(conn, event)


async def run(url: str = MAINNET_FEED) -> None:
    conn = connect()
    registry = build_registry()
    engine = FilterEngine(registry)

    shared_state = {"current_block": 0}

    async def feed() -> None:
        consumer = FeedConsumer(url)
        async for msg in consumer.live():
            shared_state["current_block"] = msg.seq
            print(f"seq={msg.seq} txs={len(msg.txs)}")
            for tx in msg.txs:
                if engine.check(tx, msg.seq):
                    insert_pending_event(conn, tx.to, tx.hash, msg.seq)

    async with asyncio.TaskGroup() as tg:
        tg.create_task(feed())
        tg.create_task(state_machine_loop(conn, lambda: shared_state["current_block"]))


def main() -> None:
    logging.basicConfig(level=logging.INFO)
    asyncio.run(run())


if __name__ == "__main__":
    main()
