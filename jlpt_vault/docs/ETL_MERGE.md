# JLPT Vault: Postgres schema and SQLite merge (ETL)

This document describes the **canonical relational schema** for unified storage, why **ID remapping** is mandatory when merging per-level SQLite exports, and how to apply migrations and run the optional importer.

## Canonical schema

Migrations live in [`../schema`](../schema). They are copied from the N3 app pipeline and define the logical tables the Flutter vault expects:

- `vocabulary` (with `jlpt_level`, `category`, `frequency_score`, unique `(kanji, reading)`)
- `example_sentences` (FK `vocab_id`, audit columns, optional `sentence_type` / `grammar_level`)
- `grammar_rules` (`grammar_level` e.g. `N5`, `N4`, `N3`, `N2`)
- `grammar_cards` (FK `grammar_id` → `grammar_rules`)
- `user_vocabulary_progress`, `user_grammar_progress` (app-local; usually not merged from exports)

Apply to the Docker Postgres instance (see root [`README.md`](../README.md)):

```bash
# From jlpt_vault/, with goose installed. Set DATABASE_URL yourself (see .env.example).
cd jlpt_vault
export DATABASE_URL="postgres://${POSTGRES_USER:-dev_user}:${POSTGRES_PASSWORD:-dev_password}@localhost:5433/${POSTGRES_DB:-jlpt_vault}?sslmode=disable"
goose -dir schema postgres "$DATABASE_URL" up
```

## Why remapping is required

Each level’s exporter produces SQLite files where **`id` columns start at 1** for `vocabulary`, `grammar_rules`, etc. If you `INSERT` rows from N3 and then N2 **without** remapping, you will:

- collide primary keys, or
- break foreign keys (`example_sentences.vocab_id`, `grammar_cards.grammar_id`).

**Rule:** Treat source `(sqlite_path, table, old_id)` as the identity when debugging; assign **new** surrogate IDs in Postgres (or in a merged SQLite) and rewrite all dependent FKs using a map built during import.

## Merge strategy (recommended v1)

1. **Target:** Empty content tables in Postgres (fresh DB after `goose up`), or an append-only import where your tool only **INSERT**s and never reuses source IDs.
2. **Order per source file:**
   - Insert `vocabulary` → build `old_vocab_id → new_id` (use `RETURNING id` in Postgres).
   - Insert `example_sentences` with `vocab_id` rewritten from the map.
   - Insert `grammar_rules` → build `old_grammar_id → new_id`.
   - Insert `grammar_cards` with `grammar_id` rewritten.
3. **Preserve level columns:** keep `vocabulary.jlpt_level` and `grammar_rules.grammar_level` from the source (or override with a CLI flag if the file is wrong).
4. **Do not** blindly merge `user_*_progress` from dev SQLite; if you migrate user data, remap `vocab_id` / `grammar_id` with the same maps and a stable `user_id` if you add multi-user support later.
5. **Uniqueness:** Postgres enforces `UNIQUE (kanji, reading)` on `vocabulary`. Duplicate lemmas across levels may conflict; resolve with `(kanji, reading, jlpt_level)` uniqueness in a future migration or skip/merge duplicates in ETL.

## Optional tool: `cmd/merge_sqlite`

[`../cmd/merge_sqlite`](../cmd/merge_sqlite) imports **one** level SQLite file into **Postgres** using new surrogate IDs (append-only). It does not truncate by default.

```bash
cd jlpt_vault
export DATABASE_URL="postgres://${POSTGRES_USER:-dev_user}:${POSTGRES_PASSWORD:-dev_password}@localhost:5433/${POSTGRES_DB:-jlpt_vault}?sslmode=disable"
go run ./cmd/merge_sqlite \
  -pg "$DATABASE_URL" \
  -sqlite ../n3_app/apps/n3_vault/assets/n3_vault.db
```

Run once per exported file (N45 bundle, N3, N2, …). Re-running on the same data without clearing tables may hit unique constraint violations on vocabulary.

## Single merged SQLite for the app (phase 2)

After Postgres is canonical, you can materialize **one** `jlpt_vault.db` with the same remapping rules and ship it in the app, then add `WHERE jlpt_level = ?` / `grammar_level = ?` to queries. The Flutter app’s **phase 1** path uses **separate bundled DBs** (and separate on-disk copies for N4 vs N5 from the same N45 asset) to avoid ID collisions and keep SRS progress isolated per level.
