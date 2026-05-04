# N2 Vault: Postgres pipeline → SQLite export

Work in **Postgres** (`mastermind_vault`). All N2 tools **scope by level** so a shared database with N4/N5 rows is safe:

- **Vocabulary / example_sentences:** `vocabulary.jlpt_level = 2`
- **Grammar:** `grammar_rules.grammar_level` treated as **N2** (empty/null defaults to N2)

Run commands from **`n2_app`** root (not inside `cmd/`). Put `OPENAI_API_KEY` in `.env` there.

```bash
cd "/path/to/n2_app"
```

---

## Pipeline order

| Step | Part | What |
|------|------|------|
| 1–2 | **A** | Docker Postgres, apply `schema/` migrations |
| 3–4 | **B** | Seed `n2.csv` → `jlpt_level = 2`; seed `n2_grammar.csv` → `grammar_level = 'N2'` |
| 5–7 | **C** | Categorize vocab (eight pillars), optional SQL normalize (see N4/N5 `database_gen.md` pattern) |
| — | **D** | Vocab sentences: **generator → auditor → fixer** (loop) |
| — | **E** | Grammar: **gen_grammar → aud_grammar → fixer_grammar** (loop); optional **scrubber** |
| last | **F** | **exporter** → `apps/n2_vault/assets/n2_vault.db` |

**Exporter** pulls **verified** sentences/cards only, and only **N2-scoped** rows as above.

---

## Part A — Database

```bash
docker compose up -d
```

Apply goose migrations in `schema/` in order. Credentials: `dev_user` / `dev_password`, DB `mastermind_vault`, port `5432`.

---

## Part B — Seeds

```bash
go run ./cmd/seed/seed.go      # requires n2.csv — sets jlpt_level = 2
go run ./cmd/seedgram/main.go  # requires n2_grammar.csv — grammar_level N2
```

---

## Part C — Categorize

```bash
go run ./cmd/categorize/main.go
```

Processes rows with **`jlpt_level = 2`** and `category IS NULL` or `Daily Life` (same eight pillars as other apps).

---

## Part D — Vocabulary sentences (three terminals)

| Step | Command | Notes |
|------|---------|--------|
| **D.1** | `go run ./cmd/generator/main.go` | Inserts daily (`grammar_level` N3) + formal (N2) per word. **N2 furigana policy:** ruby optional on common N4–N5 kanji; no `HanClusterCoverageOK` gate. |
| **D.2** | `go run ./cmd/auditor/main.go` | Batches pending rows; **`jlpt_level = 2` only**. |
| **D.3** | `go run ./cmd/fixer/main.go` | One flagged row; **`jlpt_level = 2` only**. |

Loop **D.2 ↔ D.3** until satisfied.

---

## Part E — Grammar cards

| Step | Command | Notes |
|------|---------|--------|
| **E.1** | `go run ./cmd/gen_grammar/main.go` | Up to 5 cards per **N2** rule; cloze splice via `FinalizeN2LearnerCloze` (no auto furigana patch). |
| **E.2** | `go run ./cmd/aud_grammar/main.go` | Pending cards for **N2** rules only. |
| **E.3** | `go run ./cmd/fixer_grammar/main.go` | Flagged cards for **N2** rules only. |
| **E.4** (optional) | `go run ./cmd/scrubber/main.go` | N2 grammar cards only. |

Optional legacy helper for missing English on cards:

```bash
go run ./cmd/eng_gen/main.go   # N2 grammar cards only
```

---

## Part F — Export

```bash
go run ./cmd/exporter/main.go
```

Writes **`apps/n2_vault/assets/n2_vault.db`** (N2 vocab + N2 grammar subset only).

---

## Tool index

| Command | Role |
|---------|------|
| `./cmd/seed/seed.go` | N2 vocab seed |
| `./cmd/seedgram/main.go` | N2 grammar rules seed |
| `./cmd/categorize/main.go` | N2 vocab categories |
| `./cmd/generator/main.go` | N2 vocab example sentences |
| `./cmd/auditor/main.go` | N2 vocab audit |
| `./cmd/fixer/main.go` | N2 vocab fix |
| `./cmd/gen_grammar/main.go` | N2 grammar cards |
| `./cmd/aud_grammar/main.go` | N2 grammar audit |
| `./cmd/fixer_grammar/main.go` | N2 grammar fix |
| `./cmd/scrubber/main.go` | N2 grammar scrub |
| `./cmd/eng_gen/main.go` | Fill missing `sentence_en` (N2 grammar) |
| `./cmd/exporter/main.go` | SQLite bundle |

Shared package: `internal/grammarcloze` (N2 uses `FinalizeN2LearnerCloze` — no auto furigana patch). `internal/furigana` remains for tests / optional tooling; N2 sentence pipelines do not call `HanClusterCoverageOK`.
