"""SQLite connections.

Reads go through a read-only connection, so no query path (REST API or chatbot
tool) can modify policy data. Only the AI-output tables (call_analysis,
audit_findings) are written, through write_conn().
"""

import sqlite3
from collections.abc import Iterator
from contextlib import contextmanager

from .config import settings


@contextmanager
def read_conn() -> Iterator[sqlite3.Connection]:
    conn = sqlite3.connect(f"{settings.db_path.as_uri()}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
    finally:
        conn.close()


@contextmanager
def write_conn() -> Iterator[sqlite3.Connection]:
    conn = sqlite3.connect(settings.db_path)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def rows(sql: str, params: tuple = ()) -> list[dict]:
    with read_conn() as conn:
        return [dict(r) for r in conn.execute(sql, params)]


def one(sql: str, params: tuple = ()) -> dict | None:
    found = rows(sql, params)
    return found[0] if found else None
