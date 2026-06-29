#!/usr/bin/env python3
"""Apply automation triage fixes: mechanical lint, curated sentences, duplicate merges."""
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
CURATED = AUDIT / "automation_fixes.json"

FW_PAREN_RE = re.compile(r"([^（\s]+)（([^）]+)）")
JP_GLOSS_PAREN_RE = re.compile(r"\s*[\(\（][ぁ-んァ-ンー]+[\)\）]")
JP_GLOSS_BRACKET_RE = re.compile(r"\s*\[[ぁ-んァ-ンー]+\]")
JP_IN_EN_RE = re.compile(r"[ぁ-んァ-ン一-龠]")

MANUAL_EN: dict[int, str] = {
    648: (
        "Carrying a child on one's back (onbu) is one of Japan's traditional "
        "childcare methods and strengthens the bond between parent and child."
    ),
    1580: (
        'The character for "eternity" has five strokes, yet it contains the '
        "fundamentals of calligraphy."
    ),
    2750: (
        "Individuals who harbor suicidal intent may sometimes suffer "
        "unnoticed by those around them."
    ),
    3366: (
        "In recent society, this swear word has increasingly been used to "
        "express heightened emotions."
    ),
    4778: (
        "In society, maintaining one's reputation is crucial and directly "
        "linked to an individual's honor and trust."
    ),
}

MERGES: list[dict] = [
    {
        "db": "vault_n2.db",
        "keep_id": 645,
        "drop_id": 1784,
        "english_meaning": "(Japanese) maple",
    },
    {
        "db": "vault_n2.db",
        "keep_id": 1071,
        "drop_id": 1072,
        "english_meaning": (
            "frank, candid, honest, straightforward, openhearted, direct, outspoken"
        ),
    },
    {
        "db": "vault_n2.db",
        "keep_id": 1525,
        "drop_id": 1526,
        "english_meaning": "encyclopedia",
    },
    {
        "db": "vault_n3.db",
        "keep_id": 216,
        "drop_id": 610,
        "english_meaning": "number, figure, amount",
    },
]


def backup(db_name: str) -> None:
    ts = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    shutil.copy2(ASSETS / db_name, ASSETS / f"{db_name}.autofix_bak_{ts}")


def convert_fw_parens(text: str) -> str:
    prev = None
    while prev != text:
        prev = text
        text = FW_PAREN_RE.sub(r"\1[\2]", text)
    return text


def clean_en(text: str, sentence_id: int) -> str:
    if sentence_id in MANUAL_EN:
        return MANUAL_EN[sentence_id]
    cleaned = JP_GLOSS_PAREN_RE.sub("", text)
    cleaned = JP_GLOSS_BRACKET_RE.sub("", cleaned)
    cleaned = re.sub(r"\s{2,}", " ", cleaned).strip()
    return cleaned


def apply_mechanical(db_name: str) -> tuple[int, int]:
    conn = sqlite3.connect(ASSETS / db_name)
    jp_updates = en_updates = 0
    try:
        rows = conn.execute(
            "SELECT id, sentence_jp, sentence_en FROM example_sentences"
        ).fetchall()
        for sid, jp, en in rows:
            new_jp = convert_fw_parens(jp)
            if new_jp != jp:
                conn.execute(
                    "UPDATE example_sentences SET sentence_jp=? WHERE id=?",
                    (new_jp, sid),
                )
                jp_updates += 1
            if db_name in ("vault_n1.db", "vault_n2.db") and JP_IN_EN_RE.search(en or ""):
                new_en = clean_en(en or "", sid)
                if new_en != en:
                    conn.execute(
                        "UPDATE example_sentences SET sentence_en=? WHERE id=?",
                        (new_en, sid),
                    )
                    en_updates += 1
        conn.commit()
        if conn.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise RuntimeError(f"{db_name}: integrity failed after mechanical fixes")
        return jp_updates, en_updates
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def apply_curated(rows: list[dict]) -> int:
    by_db: dict[str, list[dict]] = {}
    for row in rows:
        by_db.setdefault(row["db"], []).append(row)
    updated = 0
    for db_name, db_rows in by_db.items():
        conn = sqlite3.connect(ASSETS / db_name)
        try:
            for row in db_rows:
                cur = conn.execute(
                    """
                    UPDATE example_sentences
                    SET sentence_jp=?, sentence_en=?, audit_status='verified'
                    WHERE id=?
                    """,
                    (row["sentence_jp"], row["sentence_en"], row["sentence_id"]),
                )
                if cur.rowcount != 1:
                    raise ValueError(f"{db_name}: sentence {row['sentence_id']} not found")
                updated += 1
            conn.commit()
            if conn.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                raise RuntimeError(f"{db_name}: integrity failed after curated fixes")
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()
    return updated


def merge_duplicate(db_name: str, keep_id: int, drop_id: int, english_meaning: str) -> None:
    conn = sqlite3.connect(ASSETS / db_name)
    try:
        conn.execute("PRAGMA foreign_keys=ON")
        drop_exists = conn.execute(
            "SELECT COUNT(*) FROM vocabulary WHERE id=?", (drop_id,)
        ).fetchone()[0]
        if not drop_exists:
            return
        keep_exists = conn.execute(
            "SELECT COUNT(*) FROM vocabulary WHERE id=?", (keep_id,)
        ).fetchone()[0]
        if not keep_exists:
            raise ValueError(f"{db_name}: keeper vocab {keep_id} missing")

        conn.execute("DELETE FROM example_sentences WHERE vocab_id=?", (drop_id,))
        conn.execute("DELETE FROM vocabulary WHERE id=?", (drop_id,))
        conn.execute(
            "UPDATE vocabulary SET english_meaning=? WHERE id=?",
            (english_meaning, keep_id),
        )
        conn.commit()
        if conn.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise RuntimeError(f"{db_name}: integrity failed after merge {keep_id}/{drop_id}")
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def main() -> None:
    dbs = ["vault_n1.db", "vault_n2.db", "vault_n3.db", "vault_n45.db"]
    for db in dbs:
        backup(db)

    print("Batch 1+2: mechanical fixes")
    for db in ("vault_n1.db", "vault_n2.db"):
        jp, en = apply_mechanical(db)
        print(f"  {db}: jp={jp} en={en}")

    curated = json.loads(CURATED.read_text(encoding="utf-8"))
    print(f"Batch 3+4: curated sentence fixes ({len(curated)})")
    print(f"  updated={apply_curated(curated)}")

    print("Batch 5: duplicate merges")
    for spec in MERGES:
        merge_duplicate(spec["db"], spec["keep_id"], spec["drop_id"], spec["english_meaning"])
        print(f"  {spec['db']}: kept {spec['keep_id']}, dropped {spec['drop_id']}")

    print("Done.")


if __name__ == "__main__":
    main()
