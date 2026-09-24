"""Build data/cru.db from data/schema.sql (drops any existing database)."""

import sqlite3
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCHEMA = ROOT / "data" / "schema.sql"
DB = ROOT / "data" / "cru.db"


def main() -> None:
    DB.unlink(missing_ok=True)
    with sqlite3.connect(DB) as conn:
        conn.executescript(SCHEMA.read_text(encoding="utf-8"))
        tables = conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
        ).fetchall()
        for (name,) in tables:
            count = conn.execute(f"SELECT COUNT(*) FROM {name}").fetchone()[0]
            print(f"{name:20} {count:>4}")
    conn.close()
    print(f"Built {DB.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
