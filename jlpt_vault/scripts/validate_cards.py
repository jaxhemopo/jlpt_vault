#!/usr/bin/env python3
"""Lint vocabulary rows and example sentences against audit/card_rules.md §11."""
from __future__ import annotations

import argparse
import re
import sqlite3
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
ASSETS = REPO / "jlpt_vault" / "app" / "jlpt_vault" / "assets"
AUDIT = REPO / "jlpt_vault" / "audit"

DBS: dict[str, str] = {
    "N1": "vault_n1.db",
    "N2": "vault_n2.db",
    "N3": "vault_n3.db",
    "N45": "vault_n45.db",
}

FURIGANA_RE = re.compile(r"([^ \s\[\(\n\r]+)[\[\(]([^\]\)]+)[\]\)]")
KANJI_RE = re.compile(r"[一-龠]")
JP_IN_EN_RE = re.compile(r"[ぁ-んァ-ン一-龠]")
TAG_RE = re.compile(r"\([^)]*\)|（[^）]*）")
FULLWIDTH_PAREN_RE = re.compile(r"[（）]")
AWKWARD_RE = re.compile(r"友達.*公園.*遊")


def katakana_to_hiragana(text: str) -> str:
    out: list[str] = []
    for ch in text:
        code = ord(ch)
        if 0x30A1 <= code <= 0x30F6:
            out.append(chr(code - 0x60))
        else:
            out.append(ch)
    return "".join(out)


def strip_furigana(text: str) -> str:
    return FURIGANA_RE.sub(lambda m: m.group(1), text)


def normalize_reading(text: str) -> str:
    cleaned = TAG_RE.sub("", text)
    cleaned = cleaned.replace("～", "").replace("〜", "").strip()
    return katakana_to_hiragana(cleaned)


def reading_alternatives(reading: str) -> list[str]:
    parts = [p.strip() for p in reading.split(";") if p.strip()]
    return parts or [reading.strip()]


def kanji_core(kanji: str) -> str:
    core = TAG_RE.sub("", kanji)
    return core.replace("～", "").replace("〜", "").strip()


def build_target_regex(target: str) -> re.Pattern[str] | None:
    core = kanji_core(target)
    if not core:
        return None
    try:
        source = "".join(
            f"{re.escape(char)}(?:[\\[\\(][^\\]\\)]+[\\]\\)])?" for char in core
        )
        return re.compile(source)
    except re.error:
        return None


def readings_compatible(a: str, b: str) -> bool:
    na = normalize_reading(a)
    nb = normalize_reading(b)
    if not na or not nb:
        return False
    if na == nb or na in nb or nb in na:
        return True
    if len(na) >= 2 and len(nb) >= 2 and (na.startswith(nb) or nb.startswith(na)):
        return True
    return False


def sentence_matches_headword(kanji: str, reading: str, sentence_jp: str) -> bool:
    core = kanji_core(kanji)
    if core and build_target_regex(core):
        rx = build_target_regex(core)
        assert rx is not None
        if rx.search(sentence_jp):
            return True

    plain = strip_furigana(sentence_jp)
    plain_norm = normalize_reading(plain)
    for alt in reading_alternatives(reading):
        alt_norm = normalize_reading(alt)
        if not alt_norm:
            continue
        if alt_norm in plain_norm:
            return True
        if core and KANJI_RE.search(core):
            kanji_chars = {c for c in core if KANJI_RE.match(c)}
            if kanji_chars and any(c in sentence_jp for c in kanji_chars):
                return True
        if core and not KANJI_RE.search(core):
            if normalize_reading(core) in plain_norm:
                return True
    return False


def bracket_readings(sentence_jp: str) -> list[str]:
    return [normalize_reading(m.group(2)) for m in FURIGANA_RE.finditer(sentence_jp)]


def parse_issues(sentence_jp: str) -> list[str]:
    issues: list[str] = []
    if sentence_jp.count("[") != sentence_jp.count("]"):
        issues.append("unbalanced []")
    if sentence_jp.count("(") != sentence_jp.count(")"):
        issues.append("unbalanced ()")
    if FULLWIDTH_PAREN_RE.search(sentence_jp):
        issues.append("full-width parens")
    for m in FURIGANA_RE.finditer(sentence_jp):
        if KANJI_RE.search(m.group(2)):
            issues.append(f"kanji inside brackets: {m.group(0)}")
    return issues


@dataclass
class DeckReport:
    label: str
    integrity: str = "ok"
    vocab_count: int = 0
    verified_count: int = 0
    tag_in_fields: list[tuple[int, str, str, str]] = field(default_factory=list)
    empty_reading: list[int] = field(default_factory=list)
    duplicate_lemma: list[tuple[int, int, str, str]] = field(default_factory=list)
    card_drift: list[tuple[int, str, str, str]] = field(default_factory=list)
    headword_missing: list[tuple[int, int, str, str]] = field(default_factory=list)
    parse_hits: list[tuple[int, int, str, list[str]]] = field(default_factory=list)
    japanese_in_en: list[tuple[int, int, str]] = field(default_factory=list)
    japanese_in_meaning: list[tuple[int, str]] = field(default_factory=list)
    coverage_gaps: list[tuple[int, str, int]] = field(default_factory=list)
    awkward: list[tuple[int, int, str]] = field(default_factory=list)
    orphan_sentences: int = 0


def validate_db(label: str, db_name: str) -> DeckReport:
    report = DeckReport(label=label)
    db_path = ASSETS / db_name
    if not db_path.exists():
        report.integrity = f"missing: {db_path}"
        return report

    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    try:
        report.integrity = conn.execute("PRAGMA integrity_check").fetchone()[0]
        if report.integrity != "ok":
            return report

        vocab_rows = conn.execute(
            "SELECT id, kanji, reading, english_meaning FROM vocabulary ORDER BY id"
        ).fetchall()
        report.vocab_count = len(vocab_rows)

        sentences = conn.execute(
            """
            SELECT id, vocab_id, sentence_jp, sentence_en, audit_status
            FROM example_sentences
            ORDER BY vocab_id, id
            """
        ).fetchall()
        verified = [s for s in sentences if s["audit_status"] == "verified"]
        report.verified_count = len(verified)

        vocab_ids = {r["id"] for r in vocab_rows}
        by_vocab: dict[int, list[sqlite3.Row]] = defaultdict(list)
        for s in verified:
            by_vocab[s["vocab_id"]].append(s)

        report.orphan_sentences = sum(
            1 for s in sentences if s["vocab_id"] not in vocab_ids
        )

        lemma_index: dict[tuple[str, str], list[int]] = defaultdict(list)
        for row in vocab_rows:
            vid = row["id"]
            kanji = row["kanji"] or ""
            reading = row["reading"] or ""

            if not reading.strip():
                report.empty_reading.append(vid)

            for field_name, value in (("kanji", kanji), ("reading", reading)):
                if TAG_RE.search(value) and not re.search(r"\(する\)", value):
                    if re.search(r"\(かん\)|\(タイム\)|\(レンズ\)|\(マーケット\)", value):
                        report.tag_in_fields.append((vid, field_name, kanji, reading))
                    elif re.search(r"\([^)]+\)", value) and field_name == "reading":
                        if "(する)" not in value:
                            report.tag_in_fields.append((vid, field_name, kanji, reading))
                    elif re.search(r"\([^)]+\)", value):
                        report.tag_in_fields.append((vid, field_name, kanji, reading))

            meaning = row["english_meaning"] or ""
            if JP_IN_EN_RE.search(meaning):
                report.japanese_in_meaning.append((vid, meaning[:80]))

            key = (kanji_core(kanji), normalize_reading(reading))
            lemma_index[key].append(vid)

            sents = by_vocab.get(vid, [])
            if len(sents) < 2:
                report.coverage_gaps.append((vid, kanji, len(sents)))

            missing = [
                s
                for s in sents
                if not sentence_matches_headword(kanji, reading, s["sentence_jp"])
            ]
            for s in missing:
                preview = s["sentence_jp"][:72].replace("\n", " ")
                report.headword_missing.append((vid, s["id"], kanji, preview))

            if len(sents) >= 1 and len(missing) == len(sents):
                card_norm = normalize_reading(reading)
                bracket_sets = [set(bracket_readings(s["sentence_jp"])) for s in sents]
                common = set.intersection(*bracket_sets) if bracket_sets else set()
                common.discard("")
                if common and all(not readings_compatible(card_norm, c) for c in common):
                    alt = sorted(common, key=len, reverse=True)[0]
                    if alt and len(alt) >= 2:
                        report.card_drift.append((vid, kanji, reading, alt))

            for s in sents:
                issues = parse_issues(s["sentence_jp"])
                if issues:
                    report.parse_hits.append((vid, s["id"], s["sentence_jp"][:60], issues))
                if JP_IN_EN_RE.search(s["sentence_en"] or ""):
                    report.japanese_in_en.append((vid, s["id"], (s["sentence_en"] or "")[:80]))
                if AWKWARD_RE.search(s["sentence_jp"]):
                    report.awkward.append((vid, s["id"], s["sentence_jp"][:80]))

        for (_k, _r), ids in lemma_index.items():
            if _k and _r and len(ids) > 1:
                for i in range(1, len(ids)):
                    report.duplicate_lemma.append((ids[0], ids[i], _k, _r))

    finally:
        conn.close()

    return report


def write_markdown(reports: list[DeckReport], out_path: Path) -> None:
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    lines = [
        f"# Card validation report — {ts}",
        "",
        "Generated by `scripts/validate_cards.py`. See `audit/card_rules.md` §11.",
        "",
    ]

    for r in reports:
        lines.extend(
            [
                f"## {r.label}",
                f"- integrity: `{r.integrity}`",
                f"- vocabulary: {r.vocab_count}, verified sentences: {r.verified_count}",
                f"- orphan sentences: **{r.orphan_sentences}**",
                f"- tag in kanji/reading: **{len(r.tag_in_fields)}**",
                f"- empty reading: **{len(r.empty_reading)}**",
                f"- duplicate (kanji, reading): **{len(r.duplicate_lemma)}**",
                f"- unanimous sentence reading ≠ card: **{len(r.card_drift)}**",
                f"- headword missing in sentence: **{len(r.headword_missing)}**",
                f"- parse issues: **{len(r.parse_hits)}**",
                f"- Japanese in English: **{len(r.japanese_in_en)}**",
                f"- Japanese in english_meaning: **{len(r.japanese_in_meaning)}**",
                f"- coverage gaps (<2 verified): **{len(r.coverage_gaps)}**",
                f"- awkward template (友達+公園+遊): **{len(r.awkward)}**",
                "",
            ]
        )

        def sample(title: str, items: list, fmt, limit: int = 15) -> None:
            if not items:
                return
            lines.append(f"### {title}")
            for item in items[:limit]:
                lines.append(f"- {fmt(item)}")
            if len(items) > limit:
                lines.append(f"- … and {len(items) - limit} more")
            lines.append("")

        sample(
            "Tags in kanji/reading (sample)",
            r.tag_in_fields,
            lambda t: f"id {t[0]} `{t[1]}`: {t[2]} / {t[3]}",
        )
        sample(
            "Card reading likely wrong (sentences agree)",
            r.card_drift,
            lambda t: f"id {t[0]} **{t[1]}**: card `{t[2]}` → sentences use `{t[3]}`",
            20,
        )
        sample(
            "Headword missing (sample)",
            r.headword_missing,
            lambda t: f"vocab {t[0]} sentence {t[1]} `{t[2]}`: {t[3]}…",
        )
        sample(
            "Parse issues (sample)",
            r.parse_hits,
            lambda t: f"vocab {t[0]} sentence {t[1]}: {', '.join(t[3])} — {t[2]}…",
            10,
        )
        sample(
            "Japanese in English (sample)",
            r.japanese_in_en,
            lambda t: f"vocab {t[0]} sentence {t[1]}: {t[2]}",
        )
        sample(
            "Coverage gaps",
            r.coverage_gaps,
            lambda t: f"id {t[0]} `{t[1]}` — {t[2]} verified sentence(s)",
        )

    out_path.write_text("\n".join(lines), encoding="utf-8")


def print_summary(reports: list[DeckReport]) -> int:
    exit_code = 0
    for r in reports:
        print(f"\n{r.label} ({DBS[r.label]}) integrity={r.integrity}")
        if r.integrity != "ok":
            exit_code = 1
            continue
        blockers = (
            len(r.coverage_gaps)
            + len(r.duplicate_lemma)
            + r.orphan_sentences
            + len(r.empty_reading)
        )
        warnings = (
            len(r.headword_missing)
            + len(r.parse_hits)
            + len(r.japanese_in_en)
            + len(r.card_drift)
            + len(r.tag_in_fields)
        )
        print(
            f"  blockers={blockers} warnings={warnings} "
            f"(coverage={len(r.coverage_gaps)} parse={len(r.parse_hits)} "
            f"headword={len(r.headword_missing)})"
        )
        if blockers:
            exit_code = 1
    return exit_code


def main() -> None:
    parser = argparse.ArgumentParser(description="Validate JLPT Vault card DBs.")
    parser.add_argument(
        "--report",
        action="store_true",
        help="Write audit/automation_YYYYMMDD.md (default: on)",
    )
    parser.add_argument(
        "--no-report",
        action="store_true",
        help="Skip writing markdown report",
    )
    parser.add_argument(
        "--fail-on-warnings",
        action="store_true",
        help="Exit 1 if any warnings (not just blockers)",
    )
    args = parser.parse_args()
    write_report = not args.no_report

    reports = [validate_db(label, db_name) for label, db_name in DBS.items()]

    if write_report:
        stamp = datetime.now(timezone.utc).strftime("%Y%m%d")
        out_path = AUDIT / f"automation_{stamp}.md"
        write_markdown(reports, out_path)
        print(f"Report: {out_path}")

    code = print_summary(reports)
    if args.fail_on_warnings and code == 0:
        if any(
            r.headword_missing or r.parse_hits or r.japanese_in_en or r.card_drift
            for r in reports
        ):
            code = 1
    raise SystemExit(code)


if __name__ == "__main__":
    main()
