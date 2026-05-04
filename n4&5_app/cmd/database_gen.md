# N4/N5: database setup and pipeline (step by step)

Work stays in **Postgres** (`mastermind_vault`) until vocab **and** grammar generation/audit/fix are done. Run **one** SQLite export at the very end.

**Convention:** Every `go run` below is from the **app root** [`n4&5_app`](../) (not from inside `cmd/`), so CSV paths and `.env` resolution match seed.

```bash
cd "/path/to/n4&5_app"
```

Put `OPENAI_API_KEY` in `.env` here (or export it) before any LLM commands.

---

## Full pipeline order (do not skip)

Work through **parts A → B → C → D** in order. Run **Part E (exporter)** only when you are happy with Postgres. The exporter copies **`example_sentences` and `grammar_cards` with `audit_status = 'verified'` only**; pending/flagged rows never ship to the app bundle.

| Order | Part | What |
|-------|------|------|
| 1–4 | **A** | Postgres up, schema, seed vocab, seed grammar |
| 5–7 | **B** | Categorize vocab, normalize to 8 pillars, optional SQL check |
| — | **C** | Vocab example sentences: **generator → auditor → fixer** (loop until ratio is acceptable) |
| — | **D** | Grammar cards: **gen_grammar → aud_grammar → fixer_grammar** (same loop idea; optional **scrubber**) |
| last | **E** | **exporter** → `apps/n45_vault/assets/n45_vault.db` |

---

## Part A — Fresh database (one time per machine / reset)

### Step 1 — Start Postgres

From `n4&5_app`:

```bash
docker compose up -d
```

Credentials match [`docker-compose.yml`](../docker-compose.yml): `dev_user` / `dev_password`, database `mastermind_vault`, port `5432`.

### Step 2 — Apply schema

Run the `-- +goose Up` sections in order from [`../schema`](../schema) (goose-style migration files).

### Step 3 — Seed vocabulary

With `n4.csv` and `n5.csv` in `n4&5_app`:

```bash
go run ./cmd/seed/seed.go
```

- `jlpt_level` **4** (N4) or **5** (N5) per row source.
- Initial `category` is heuristic: **`Daily Life`** or **`Work`** from meaning keywords.

### Step 4 — Seed grammar rules

With `n4_grammar.csv` and `n5_grammar.csv` present:

```bash
go run ./cmd/seedgram/main.go
```

- Rules get `grammar_level` **N4** or **N5** as appropriate.

**Stop here** until you are ready for LLM work. Do **not** export yet.

---

## Part B — Vocabulary categories (LLM + SQL)

### Step 5 — Categorize (eight pillars + frequency)

```bash
go run ./cmd/categorize/main.go
```

- Needs `OPENAI_API_KEY`.
- Processes rows where `category IS NULL` or `category = 'Daily Life'`. Seed **`Work`** rows are skipped (Work is a valid pillar); to force LLM on those, null them first:  
  `UPDATE vocabulary SET category = NULL WHERE category = 'Work';`
- Unknown model category strings are **clamped to `Society`** in code before `UPDATE`.

### Step 6 — Normalize to exactly eight categories

Allowed values (case-sensitive):

`Family`, `Work`, `Travel`, `Food`, `Health`, `Society`, `Nature`, `Emotions`

After categorize, merge long-tail labels in Postgres. Example (adjust `IN` lists if your `GROUP BY` shows extra labels):

```bash
PGPASSWORD=dev_password psql -h localhost -p 5432 -U dev_user -d mastermind_vault <<'SQL'
BEGIN;

UPDATE vocabulary SET category = 'Society'
WHERE category IN (
  'Time','Education','Clothing','Fashion','Arts','Culture','Colors',
  'Shopping','Media','Technology','Language','Knowledge','Numbers',
  'Math/Calculations','Daily Life'
);

UPDATE vocabulary SET category = 'Health' WHERE category = 'Sport';
UPDATE vocabulary SET category = 'Nature' WHERE category = 'Weather';
UPDATE vocabulary SET category = 'Family' WHERE category = 'Age';

COMMIT;

SELECT category, COUNT(*) AS n FROM vocabulary GROUP BY category ORDER BY category;
-- expect exactly 8 rows
SQL
```

### Step 7 — Quick check (optional)

```sql
SELECT category, COUNT(*) AS n FROM vocabulary GROUP BY category ORDER BY n DESC;
```

---

## Part C — Vocabulary example sentences (C.1–C.3, three terminals)

These steps assume **Part B** is done. They fill and clean **`example_sentences`**.

### Furigana rule (N4/N5 app vs N3)

The Flutter app for N4/N5 expects **full furigana**: every **contiguous kanji block** must have a **`[hiragana]`** reading **before any later kanji** appears. **Okurigana** between the kanji and the bracket is OK (e.g. `食べる[たべる]`, `好き[すき]`, `苦い[にがい]`). **Katakana-only** words stay **without** brackets. Bare patterns like `私は…` with the next kanji before any `[` still fail (e.g. need `私[わたし]は…`).

The **N3** project often omitted brackets on “easy” kanji; that is **not** the target here. The **generator** rejects JSON that fails this shape (see `internal/furigana`), and **auditor** / **fixer** prompts match.

### Full reset of vocab example sentences (keep `vocabulary`)

If an older run used looser furigana, wipe sentences and regenerate from **generator** so everything follows the current rules:

```bash
PGPASSWORD=dev_password psql -h localhost -p 5432 -U dev_user -d mastermind_vault \
  -c "DELETE FROM example_sentences;"
```

- **`vocabulary`** (categories, `frequency_score`, etc.) is unchanged.
- **`user_progress`** in this schema keys off `vocab_id`, not sentence ids, so it is unaffected.
- Then run **generator** → **auditor** → **fixer** again (three terminals as below).

---

**Step C.1 — Generate** → **Step C.2 — Audit** → **Step C.3 — Fix**, then repeat **C.2 ↔ C.3** until you like the verified share.

Generator fills `example_sentences` as **`pending`**. Auditor sets **`verified`** or **`flagged`**. Fixer rewrites **`flagged`** rows and sets them back to **`pending`** for another audit pass.

**Practical setup:** three terminals, all with `cd` to `n4&5_app` and `OPENAI_API_KEY` available.

| Step | Terminal | Command | Behavior |
|------|----------|---------|----------|
| **C.1** | 1 | `go run ./cmd/generator/main.go` | One vocab at a time; inserts daily + formal sentences until every categorized word has rows (or stop with Ctrl+C for a partial run). |
| **C.2** | 2 | `go run ./cmd/auditor/main.go` | Batches `pending` rows; when none left, sleeps and rechecks (good to leave running while fixer runs). |
| **C.3** | 3 | `go run ./cmd/fixer/main.go` | Fixes one `flagged` row at a time; **exits** when nothing is flagged. Re-run if new flags appear after more auditing. |

**Not vocab:** `go run ./cmd/scrubber/main.go` only cleans **`grammar_cards`** (kana/katakana bracket noise). Use it in the grammar phase, not for `example_sentences`.

**Sanity SQL:**

```sql
SELECT audit_status, COUNT(*) FROM example_sentences GROUP BY audit_status;
```

Iterate **C.2 + C.3** until you like the verified vs flagged ratio, then move on to **Part D**.

---

## Part D — Grammar cards (when vocab is far enough along)

Grammar uses the **same furigana expectations** as Part C (machine-checked via `internal/furigana`). Cards are **cloze drills**: `cloze_sentence_jp` contains exactly **`[____]`** once; replacing it with `cloze_answer` must equal `sentence_jp` after the pipeline’s furigana alignment (`internal/grammarcloze` keeps sentence/cloze/answer consistent with `PatchCommonFuriganaGaps`).

**Step D.1 — Generate** → **Step D.2 — Audit** → **Step D.3 — Fix**, then repeat **D.2 ↔ D.3** like vocabulary.

**Practical setup:** same as vocab — three terminals, `cd` to `n4&5_app`, `OPENAI_API_KEY` set.

| Step | Terminal | Command | Behavior |
|------|----------|---------|----------|
| **D.1** | 1 | `go run ./cmd/gen_grammar/main.go` | Picks the next `grammar_rules` row with **fewer than 5** `grammar_cards`, generates **one** card per loop (context rotates: Daily Life, Family & Friends, etc.). Skips and logs after 3 failed API attempts for that slot. Leave running until all rules have 5 cards or you stop manually. |
| **D.2** | 2 | `go run ./cmd/aud_grammar/main.go` | Processes a **batch of 5** `pending` grammar cards: mechanical cloze/furigana checks, then LLM **valid** / **invalid**; sets **`verified`** or **`flagged`**. Sleeps and retries when no `pending` cards. |
| **D.3** | 3 | `go run ./cmd/fixer_grammar/main.go` | Repairs **one** `flagged` card at a time; on success sets **`pending`** for another audit pass. **Exits** when nothing is `flagged` — start it again after more auditing if new flags appear. |

**Step D.4 — Optional scrubber** (any time grammar text has kana/katakana bracket noise you want normalized):

```bash
go run ./cmd/scrubber/main.go
```

Use **scrubber** on **`grammar_cards`**, not on vocab `example_sentences`.

**Sanity SQL (grammar):**

```sql
-- Cards by status
SELECT audit_status, COUNT(*) FROM grammar_cards GROUP BY audit_status;

-- Per rule: how many cards and sample Japanese
SELECT r.id, r.name, r.grammar_level, COUNT(c.id) AS n_cards,
       STRING_AGG(LEFT(c.sentence_jp, 40), ' | ' ORDER BY c.id) AS preview
FROM grammar_rules r
LEFT JOIN grammar_cards c ON c.grammar_id = r.id
GROUP BY r.id, r.name, r.grammar_level
HAVING COUNT(c.id) > 0
ORDER BY r.id;
```

**Reminder:** **`exporter`** only includes grammar cards with **`audit_status = 'verified'`**. Finish the **D.2 ↔ D.3** loop for grammar the same way you did for vocab before exporting.

---

## Part E — Ship to the Flutter app (once)

After vocab **and** grammar loops are in a good state (enough **`verified`** rows for what you want in the app):

```bash
go run ./cmd/exporter/main.go
```

Writes `apps/n45_vault/assets/n45_vault.db`. Vocab sentences and grammar cards in the bundle are **`verified` only**; all `grammar_rules` rows are exported so the app can show rules even if some have no verified cards yet.

---

## Where the tools live

| Phase | Step | Command |
|-------|------|---------|
| Seed vocab | A.3 | `./cmd/seed/seed.go` |
| Seed grammar | A.4 | `./cmd/seedgram/main.go` |
| Categorize | B.5 | `./cmd/categorize/main.go` |
| Vocab sentences | C.1 | `./cmd/generator/main.go` |
| Vocab audit | C.2 | `./cmd/auditor/main.go` |
| Vocab fix | C.3 | `./cmd/fixer/main.go` |
| Grammar generate | D.1 | `./cmd/gen_grammar/main.go` |
| Grammar audit | D.2 | `./cmd/aud_grammar/main.go` |
| Grammar fix | D.3 | `./cmd/fixer_grammar/main.go` |
| Grammar scrub | D.4 (optional) | `./cmd/scrubber/main.go` |
| SQLite export | E | `./cmd/exporter/main.go` |

The same **categorize** behavior (strict eight pillars + clamp + seed-row selection) is mirrored under **n3_app** and **n2_app** in their `cmd/categorize/main.go` if you repeat the pipeline there.
