# N1 Vault: Postgres pipeline → SQLite export

Work in **Postgres** (`mastermind_vault`). All N1 tools **scope by level** so a shared database with N2/N3/N4/N5 rows is safe:

- **Vocabulary / example_sentences:** `vocabulary.jlpt_level = 1`
- **Grammar:** `grammar_rules.grammar_level` **N1** (empty/null defaults to N1 in queries)

Run commands from **`n1_app`** root (not inside `cmd/`). Put `OPENAI_API_KEY` in `.env` there.

```bash
cd "/path/to/n1_app"
```

---

## Pipeline order

| Step | Part | What |
|------|------|------|
| 1–2 | **A** | Docker Postgres, apply `schema/` migrations (once per database) |
| 3–4 | **B** | Seed `n1.csv` → `jlpt_level = 1`; seed `n1_grammar.csv` → `grammar_level = 'N1'` |
| 5–7 | **C** | Categorize vocab (eight pillars), optional SQL normalize (see other apps’ docs) |
| — | **D** | Vocab sentences: **generator → auditor → fixer** (loop) |
| — | **E** | Grammar: **gen_grammar → aud_grammar → fixer_grammar** (loop); optional **scrubber** |
| last | **F** | **exporter** → `apps/n1_vault/assets/n1_vault.db` |

**Exporter** pulls **verified** sentences/cards only, and only **N1-scoped** rows as above.

---

## Part A — Database

```bash
docker compose up -d
```

Apply goose migrations in `schema/` in order. Credentials: `dev_user` / `dev_password`, DB `mastermind_vault`, port `5432`. If this Postgres was already migrated by another JLPT app, **do not** re-run migrations.

---

## Part B — Seeds

```bash
go run ./cmd/seed/seed.go      # n1.csv — jlpt_level = 1; deletes existing jlpt_level=1 rows only (safe on shared DB)
go run ./cmd/seedgram/main.go  # n1_grammar.csv — grammar_level N1; replaces N1 grammar (and linked cards) first
```

**Note:** `seed` uses `DELETE FROM vocabulary WHERE jlpt_level = 1`, not `TRUNCATE`, so other JLPT levels in the same database are preserved. Full-table `TRUNCATE` is only appropriate on an isolated factory database.

---

## Part C — Categorize

```bash
go run ./cmd/categorize/main.go
```

Processes rows with **`jlpt_level = 1`** and `category IS NULL` or `Daily Life` (same eight pillars as other apps).

---

## Part D — Vocabulary sentences (three terminals)

| Step | Command | Notes |
|------|---------|--------|
| **D.1** | `go run ./cmd/generator/main.go` | Inserts daily (`grammar_level` **N2**) + formal (**N1**) per word. **N1 furigana policy:** ruby optional on common kanji; no `HanClusterCoverageOK` gate. |
| **D.2** | `go run ./cmd/auditor/main.go` | Batches pending rows; **`jlpt_level = 1` only**. |
| **D.3** | `go run ./cmd/fixer/main.go` | One flagged row; **`jlpt_level = 1` only**. |

Loop **D.2 ↔ D.3** until satisfied.

---

## Part E — Grammar cards

| Step | Command | Notes |
|------|---------|--------|
| **E.1** | `go run ./cmd/gen_grammar/main.go` | Up to 5 cards per **N1** rule; cloze splice via `FinalizeN2LearnerCloze` (same mechanical validation as N2; no auto furigana patch). |
| **E.2** | `go run ./cmd/aud_grammar/main.go` | Pending cards for **N1** rules only. |
| **E.3** | `go run ./cmd/fixer_grammar/main.go` | Flagged cards for **N1** rules only. |
| **E.4** (optional) | `go run ./cmd/scrubber/main.go` | N1 grammar cards only. |

Optional legacy helper for missing English on cards:

```bash
go run ./cmd/eng_gen/main.go   # N1 grammar cards only
```

---

## Part F — Export

```bash
go run ./cmd/exporter/main.go
```

Writes **`apps/n1_vault/assets/n1_vault.db`** (N1 vocab + N1 grammar subset only).

---

## Tool index

| Command | Role |
|---------|------|
| `./cmd/seed/seed.go` | N1 vocab seed |
| `./cmd/seedgram/main.go` | N1 grammar rules seed |
| `./cmd/categorize/main.go` | N1 vocab categories |
| `./cmd/generator/main.go` | N1 vocab example sentences |
| `./cmd/auditor/main.go` | N1 vocab audit |
| `./cmd/fixer/main.go` | N1 vocab fix |
| `./cmd/gen_grammar/main.go` | N1 grammar cards |
| `./cmd/aud_grammar/main.go` | N1 grammar audit |
| `./cmd/fixer_grammar/main.go` | N1 grammar fix |
| `./cmd/scrubber/main.go` | N1 grammar scrub |
| `./cmd/eng_gen/main.go` | Fill missing `sentence_en` (N1 grammar) |
| `./cmd/exporter/main.go` | SQLite bundle |

Shared package: `internal/grammarcloze` (`FinalizeN2LearnerCloze` — same cloze math as N2; N1 prompts differ). `internal/furigana` for tests / optional tooling.

---

## Port conflict

Only one stack should bind host **5432** at a time, or remap the published port in `docker-compose.yml` for a second Postgres instance.
