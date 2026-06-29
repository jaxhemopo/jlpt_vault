#!/usr/bin/env python3
"""Insert second example sentences and verify DB readiness."""
from __future__ import annotations

import json
import re
import shutil
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
ASSETS = REPO / "jlpt_vault" / "app" / "jlpt_vault" / "assets"
AUDIT = REPO / "jlpt_vault" / "audit"

FURIGANA_RE = re.compile(r"[^ \s\[\(\n\r]+[\[\(][^\]\)]+[\]\)]")
KANJI_RE = re.compile(r"[一-龠]")


def load_sentences(name: str) -> list[dict]:
    rows = json.loads((AUDIT / name).read_text(encoding="utf-8"))
    for row in rows:
        for key in ("vocab_id", "sentence_jp", "sentence_en"):
            if key not in row:
                raise ValueError(f"{name}: missing {key} in {row}")
    return rows


def validate_row(row: dict) -> None:
    jp, en = row["sentence_jp"], row["sentence_en"]
    if not jp.strip() or not en.strip():
        raise ValueError(f"vocab {row['vocab_id']}: empty sentence")
    if jp.count("[") != jp.count("]"):
        raise ValueError(f"vocab {row['vocab_id']}: unbalanced brackets in {jp}")
    if KANJI_RE.search(jp) and not FURIGANA_RE.search(jp):
        raise ValueError(f"vocab {row['vocab_id']}: kanji without furigana in {jp}")


def apply(db_name: str, rows: list[dict]) -> int:
    db_path = ASSETS / db_name
    ts = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    shutil.copy2(db_path, ASSETS / f"{db_name}.secondsent_bak_{ts}")

    conn = sqlite3.connect(db_path)
    try:
        conn.execute("PRAGMA foreign_keys=ON")
        max_id = conn.execute("SELECT MAX(id) FROM example_sentences").fetchone()[0] or 0
        inserted = 0
        for row in rows:
            validate_row(row)
            vid = row["vocab_id"]
            exists = conn.execute(
                "SELECT COUNT(*) FROM vocabulary WHERE id=?", (vid,)
            ).fetchone()[0]
            if not exists:
                raise ValueError(f"{db_name}: vocab_id {vid} not found")
            count = conn.execute(
                "SELECT COUNT(*) FROM example_sentences WHERE vocab_id=?", (vid,)
            ).fetchone()[0]
            if count >= 2:
                continue
            max_id += 1
            conn.execute(
                """
                INSERT INTO example_sentences
                  (id, vocab_id, sentence_jp, sentence_en, cloze_deletion_index, audit_status)
                VALUES (?, ?, ?, ?, 0, 'verified')
                """,
                (max_id, vid, row["sentence_jp"], row["sentence_en"]),
            )
            inserted += 1
        conn.commit()
        integrity = conn.execute("PRAGMA integrity_check").fetchone()[0]
        if integrity != "ok":
            raise RuntimeError(f"{db_name}: integrity_check={integrity}")
        return inserted
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def report(db_name: str) -> None:
    db_path = ASSETS / db_name
    conn = sqlite3.connect(db_path)
    try:
        rows = conn.execute(
            """
            SELECT
              (SELECT COUNT(*) FROM vocabulary) AS vocab,
              (SELECT COUNT(*) FROM example_sentences) AS sents,
              (SELECT COUNT(*) FROM example_sentences WHERE audit_status='verified') AS verified,
              (SELECT COUNT(*) FROM vocabulary v WHERE
                (SELECT COUNT(*) FROM example_sentences e WHERE e.vocab_id=v.id AND e.audit_status='verified') < 2) AS lt2
            """
        ).fetchone()
        print(f"{db_name}: vocab={rows[0]} sents={rows[1]} verified={rows[2]} cards_lt2_visible={rows[3]}")
    finally:
        conn.close()


def main() -> None:
    n45 = load_sentences("n45_second_sentences.json")
    n1 = load_sentences("n1_second_sentences.json")
    if len(n45) != 214:
        raise SystemExit(f"expected 214 N45 rows, got {len(n45)}")
    if len(n1) != 1:
        raise SystemExit(f"expected 1 N1 row, got {len(n1)}")

    n45_inserted = apply("vault_n45.db", n45)
    n1_inserted = apply("vault_n1.db", n1)
    print(f"Inserted {n45_inserted} N45 + {n1_inserted} N1 sentences")
    for db in ("vault_n1.db", "vault_n2.db", "vault_n3.db", "vault_n45.db"):
        report(db)


if __name__ == "__main__":
    main()
