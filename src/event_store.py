"""SQLite-backed persistence for the candidate-event state machine.

State machine: pending -> filter_check_in_progress -> confirmed_not_filtered ->
l1_confirmed, with a `filtered` terminal state reachable directly from either
`pending` or `filter_check_in_progress` (the moment `isTransactionFiltered`
returns true).
"""

from __future__ import annotations

import datetime
import sqlite3
from pathlib import Path

DEFAULT_DB_PATH = Path(__file__).resolve().parent.parent / "data" / "events.db"

STATUSES = (
    "pending",
    "filter_check_in_progress",
    "confirmed_not_filtered",
    "filtered",
    "l1_confirmed",
)

_SCHEMA = """
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    token_address TEXT NOT NULL,
    tx_hash TEXT NOT NULL,
    block_number INTEGER NOT NULL,
    detected_at TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    filter_check_count INTEGER NOT NULL DEFAULT 0,
    last_checked_at TEXT,
    last_checked_block INTEGER,
    reference_model_hash TEXT,
    onchain_verified_cache INTEGER,
    onchain_cache_updated_at TEXT
)
"""


#: Columns added after the table's first release. `CREATE TABLE IF NOT EXISTS`
#: only helps a brand-new database -- an existing `events.db` from an earlier
#: tier needs these added explicitly, or code expecting them raises immediately.
_ADDED_COLUMNS = {
    "last_checked_block": "INTEGER",
    "reference_model_hash": "TEXT",
    "onchain_verified_cache": "INTEGER",
    "onchain_cache_updated_at": "TEXT",
}


def _migrate(conn: sqlite3.Connection) -> None:
    existing = {row["name"] for row in conn.execute("PRAGMA table_info(events)")}
    for column, coltype in _ADDED_COLUMNS.items():
        if column not in existing:
            conn.execute(f"ALTER TABLE events ADD COLUMN {column} {coltype}")
    conn.commit()


def connect(db_path: Path = DEFAULT_DB_PATH) -> sqlite3.Connection:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    conn.execute(_SCHEMA)
    conn.commit()
    _migrate(conn)
    return conn


def _now() -> str:
    return datetime.datetime.now(datetime.UTC).isoformat()


def insert_pending_event(
    conn: sqlite3.Connection, token_address: str, tx_hash: str, block_number: int
) -> int:
    cur = conn.execute(
        "INSERT INTO events (token_address, tx_hash, block_number, detected_at, status) "
        "VALUES (?, ?, ?, ?, 'pending')",
        (token_address, tx_hash, block_number, _now()),
    )
    conn.commit()
    return cur.lastrowid


def update_status(
    conn: sqlite3.Connection,
    event_id: int,
    status: str,
    *,
    increment_filter_check_count: bool = False,
    checked_at_block: int | None = None,
) -> None:
    if status not in STATUSES:
        raise ValueError(f"unknown status: {status!r}")
    if increment_filter_check_count:
        conn.execute(
            "UPDATE events SET status = ?, filter_check_count = filter_check_count + 1, "
            "last_checked_at = ?, last_checked_block = ? WHERE id = ?",
            (status, _now(), checked_at_block, event_id),
        )
    else:
        conn.execute(
            "UPDATE events SET status = ?, last_checked_at = ? WHERE id = ?",
            (status, _now(), event_id),
        )
    conn.commit()


def get_pending_events(conn: sqlite3.Connection) -> list[sqlite3.Row]:
    """Events still mid state-machine: not yet at a terminal status."""
    return conn.execute(
        "SELECT * FROM events WHERE status IN ('pending', 'filter_check_in_progress') "
        "ORDER BY id"
    ).fetchall()


def get_events_by_status(conn: sqlite3.Connection, status: str) -> list[sqlite3.Row]:
    if status not in STATUSES:
        raise ValueError(f"unknown status: {status!r}")
    return conn.execute("SELECT * FROM events WHERE status = ? ORDER BY id", (status,)).fetchall()


def get_event_by_id(conn: sqlite3.Connection, event_id: int) -> sqlite3.Row | None:
    return conn.execute("SELECT * FROM events WHERE id = ?", (event_id,)).fetchone()


def set_reference_model_hash(conn: sqlite3.Connection, event_id: int, sha256_hex: str) -> None:
    conn.execute(
        "UPDATE events SET reference_model_hash = ? WHERE id = ?", (sha256_hex, event_id)
    )
    conn.commit()


def get_all_events(conn: sqlite3.Connection, status: str | None = None) -> list[sqlite3.Row]:
    """All events, optionally filtered by status. Used by the audit log."""
    if status is not None:
        if status not in STATUSES:
            raise ValueError(f"unknown status: {status!r}")
        return conn.execute("SELECT * FROM events WHERE status = ? ORDER BY id", (status,)).fetchall()
    return conn.execute("SELECT * FROM events ORDER BY id").fetchall()


def set_onchain_cache(conn: sqlite3.Connection, event_id: int, verified: bool) -> None:
    """Performance-only cache of the on-chain `isVerified` result. Never treated as
    the source of truth -- see `GET /events/{id}`, which always re-checks the
    chain directly rather than trusting this column."""
    conn.execute(
        "UPDATE events SET onchain_verified_cache = ?, onchain_cache_updated_at = ? WHERE id = ?",
        (1 if verified else 0, _now(), event_id),
    )
    conn.commit()
