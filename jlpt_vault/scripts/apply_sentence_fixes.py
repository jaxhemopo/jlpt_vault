#!/usr/bin/env python3
"""Apply curated sentence rewrites to vault DBs."""
from __future__ import annotations

import json
import re
import shutil
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
ASSETS = REPO / "jlpt_vault" / "app" / "jlpt_vault" / "assets"
FIXES = REPO / "jlpt_vault" / "audit" / "sentence_fixes.json"

FURIGANA_RE = re.compile(r"[^ \s\[\(\n\r]+[\[\(][^\]\)]+[\]\)]")
KANJI_RE = re.compile(r"[一-龠]")


def validate(jp: str, en: str) -> None:
    if not jp.strip() or not en.strip():
        raise ValueError("empty sentence")
    if jp.count("[") != jp.count("]"):
        raise ValueError(f"unbalanced brackets: {jp}")
    if KANJI_RE.search(jp) and not FURIGANA_RE.search(jp):
        raise ValueError(f"kanji without furigana: {jp}")


def apply_db(db_name: str, rows: list[dict]) -> int:
    db_path = ASSETS / db_name
    ts = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    shutil.copy2(db_path, ASSETS / f"{db_name}.awkfix_bak_{ts}")

    conn = sqlite3.connect(db_path)
    try:
        updated = 0
        for row in rows:
            validate(row["sentence_jp"], row["sentence_en"])
            cur = conn.execute(
                """
                UPDATE example_sentences
                SET sentence_jp = ?, sentence_en = ?, audit_status = 'verified'
                WHERE id = ?
                """,
                (row["sentence_jp"], row["sentence_en"], row["sentence_id"]),
            )
            if cur.rowcount != 1:
                raise ValueError(f"{db_name}: sentence id {row['sentence_id']} not found")
            updated += 1
        conn.commit()
        if conn.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise RuntimeError(f"{db_name}: integrity check failed")
        return updated
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def main() -> None:
    fixes = json.loads(FIXES.read_text(encoding="utf-8"))
    n45 = [f for f in fixes if f.get("db", "vault_n45.db") == "vault_n45.db"]
    n1 = [f for f in fixes if f.get("db") == "vault_n1.db"]
    print(f"Applying {len(n45)} N45 + {len(n1)} N1 fixes")
    print("N45:", apply_db("vault_n45.db", n45))
    if n1:
        print("N1:", apply_db("vault_n1.db", n1))


if __name__ == "__main__":
    main()
