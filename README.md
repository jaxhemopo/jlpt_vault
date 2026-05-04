# JLPT APPS (workspace)

This repository is the **full stack** for **JLPT Vault**: the Flutter client **and** the **Go + Docker Postgres** factories that build each JLPT level’s data (seed → categorize → LLM generate / audit / fix → export SQLite).

## What lives where

| Path | What it is |
|------|------------|
| [`jlpt_vault/`](jlpt_vault/) | **Shipping app** (Flutter under `app/n3_vault/`), merge tooling (`cmd/merge_sqlite`), ETL docs, Postgres schema for the unified vault. See [`jlpt_vault/README.md`](jlpt_vault/README.md). |
| [`n1_app/`](n1_app/) | N1 pipeline: `docker-compose.yml`, `schema/`, `cmd/` (seed, generator, auditor, exporter, …). |
| [`n2_app/`](n2_app/) | N2 factory — same pattern (Go CLIs + Postgres). |
| [`n3_app/`](n3_app/) | N3 factory (older layout; reference app under `apps/n3_vault/`). |
| [`n4&5_app/`](n4&5_app/) | N4/N5 factory. |

Each `*_app` folder is its own small Go module: spin up Postgres with Docker, run migrations, seed CSVs, then run the AI loop tools that talk to the OpenAI API (keys via `.env`, never committed). Output is typically a **`.db` SQLite file** bundled into the Flutter app’s assets (those binaries are **gitignored** here; the **code and schema** are what you’re meant to browse).

## Tech you can point at on a resume

- **Docker** — local Postgres for every factory + the unified `jlpt_vault` merge DB.
- **Go** — CLI-style `cmd/*` tools: HTTP calls to LLMs, JSON parsing, `database/sql` against Postgres, exporters to SQLite.
- **Postgres** — staging schema, audit columns, grammar + vocab tables.
- **Flutter** — client app under `jlpt_vault/app/n3_vault` (Anki-style SRS; see vault README).

## Clone and explore (no secrets required)

```bash
git clone https://github.com/jaxhemopo/jlpt_vault.git
cd jlpt_vault
# You are at the monorepo root: sibling folders n1_app/, jlpt_vault/ (Flutter app), etc.
# Pick any *_app, then: docker compose up -d, read cmd/database_gen.md
```

Use each project’s `.env.example` where present; copy to `.env` for real API keys locally.
