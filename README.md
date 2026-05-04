# JLPT APPS (workspace)

This repository is the **full stack** for **JLPT Vault**: the Flutter client plus the **Go + Docker Postgres** pipelines that manufacture each JLPT level’s SQLite data.

## Why `n1_app`, `n2_app`, `n3_app`, and `n4&5_app` are separate (on purpose)

Each level is built in **its own folder** — not copy-paste laziness. N5 and N1 do not get the same prompts, furigana rules, grammar-card validation, or “daily vs formal” sentence targets. Each factory:

- Own **Go module**, **`docker-compose.yml`**, and **`schema/`** migrations tuned for that level  
- Own **`cmd/`** tools with **SQL scoped to that JLPT level** (e.g. `jlpt_level`, `grammar_level`)  
- Own **`cmd/database_gen.md`** — the real runbook: exact command order and level-specific behaviour  

You run one factory at a time, export **one** `.db` per level (paths differ slightly; see each app’s `database_gen.md`), then ship those assets into the vault app (or merge them upstream — see below).

| Path | Role |
|------|------|
| [`jlpt_vault/`](jlpt_vault/) | **Shipping Flutter app** (`app/n3_vault/`), optional **merge / ETL** (`cmd/merge_sqlite`, `docs/ETL_MERGE.md`), and Postgres schema for a **unified** merge database (port **5433** — separate from per-factory Postgres on **5432**). [`jlpt_vault/README.md`](jlpt_vault/README.md) |
| [`n1_app/`](n1_app/) | N1 factory → e.g. `apps/n1_vault/assets/n1_vault.db` (see [`n1_app/cmd/database_gen.md`](n1_app/cmd/database_gen.md)) |
| [`n2_app/`](n2_app/) | N2 factory → [`n2_app/cmd/database_gen.md`](n2_app/cmd/database_gen.md) |
| [`n3_app/`](n3_app/) | N3 factory (includes legacy `apps/n3_vault/` under this tree) |
| [`n4&5_app/`](n4&5_app/) | N4/N5 factory (often one repo, two CSV sources) |

---

## How the multi-LLM pipeline works (same shape, different rules per level)

Every factory uses **Postgres as a staging database**, then **Go CLIs** that call an LLM API (OpenAI-style chat completions; **`OPENAI_API_KEY`** in a local `.env`, never committed). The pattern is a **generate → audit → fix loop** so bad rows get corrected instead of shipping silently.

**Typical lifecycle** (details and flags differ by level — read that level’s `cmd/database_gen.md`):

1. **Docker** — `docker compose up -d` → local Postgres (`mastermind_vault` on **5432** for the `*_app` factories).  
2. **Migrations** — apply `schema/*.sql` (goose or your usual process; each `database_gen.md` spells it out).  
3. **Seed** — CSV → `vocabulary` + `grammar_rules` (level columns set so tools only touch their JLPT slice).  
4. **Categorize** — LLM batches words into fixed category pillars + frequency hints.  
5. **Vocabulary sentences (multi-LLM)**  
   - **`generator`** — LLM writes example sentences (often “daily” + “formal” tiers with **different difficulty tags** per level).  
   - **`auditor`** — LLM (and sometimes mechanical checks) marks rows **verified** vs **flagged**.  
   - **`fixer`** — LLM rewrites **one flagged row** at a time; you **loop auditor ↔ fixer** until quality is good.  
6. **Grammar cards (multi-LLM)** — parallel track: e.g. **`gen_grammar`** → **`aud_grammar`** → **`fixer_grammar`**, plus optional **`scrubber`** / **`eng_gen`** where that level’s doc mentions them. Cloze math is validated in code (`internal/grammarcloze` on newer factories).  
7. **Exporter** — pulls **only verified** content into a **read-only SQLite** file the Flutter app bundles.

So “multi-LLM” here means **several distinct tools**, each with its own prompts and responsibilities, chained until the dataset is shippable — not a single one-shot prompt.

---

## Where `jlpt_vault` fits after the per-level `.db` files exist

The Flutter app under `jlpt_vault/app/n3_vault` loads **per-level** SQLite assets (see `pubspec.yaml`).  

**Optionally**, you can import multiple exported files into the **merge Postgres** on **5433** using [`jlpt_vault/cmd/merge_sqlite`](jlpt_vault/cmd/merge_sqlite) and the notes in [`jlpt_vault/docs/ETL_MERGE.md`](jlpt_vault/docs/ETL_MERGE.md) (ID remapping, uniqueness, order of imports). That path is for **unified ETL / experimentation**, not a requirement to run the study app day-to-day.

---

## Tech you can point at on a resume

- **Docker** — repeatable Postgres for every factory + separate merge DB in `jlpt_vault`.  
- **Go** — small CLIs: `database/sql`, LLM HTTP/JSON, exporters to SQLite.  
- **Postgres** — relational staging, audit columns, grammar + vocab graphs.  
- **Multi-step LLM QA** — generator / auditor / fixer loops for vocab and grammar.  
- **Flutter** — offline-first client, **Anki-style SRS** (see vault README).

---

## Clone and explore

```bash
git clone https://github.com/jaxhemopo/jlpt_vault.git jlpt-workspace
cd jlpt-workspace
# Repo root: n1_app/, n2_app/, jlpt_vault/ (Flutter + merge), …
# Open any n*_app/cmd/database_gen.md for the exact pipeline for that level.
```

Copy `.env` from each project’s `.env.example` where provided; never commit real API keys.
