# JLPT Vault

**Monorepo** — one **Flutter** study client (`jlpt_vault/app/jlpt_vault`) plus separate **Go + Docker Postgres** “factories” (`n1_app`, `n2_app`, `n3_app`, `n4&5_app`) that each export level-specific SQLite for the app.

---

## Description

JLPT Vault is an **offline-first** JLPT prep app (N5–N1) with **Anki-style spaced repetition** for vocabulary and grammar. The interesting part for engineers is how the content is built: each JLPT level has its own **multi-LLM QA pipeline** (generate → audit → fix loops) running against Postgres, then an exporter produces the bundled `.db` files the Flutter app ships.

---

## Try it (App Store)

You can install and test the shipping build on **iPhone or iPad** without cloning this repo: **[JLPT Vault on the App Store](https://apps.apple.com/jp/app/jlpt-vault-jlpt-study-srs/id6760022205)** (Apple Japan storefront listing; opens in the App Store app when viewed on a device).

---

## Motivation

This started as an **N3-only** tool for my own exam prep, grew into versions for friends on other levels, and became one vault-style app instead of four separate store listings. The per-level **folders stay separate on purpose**: prompts, furigana rules, grammar validation, and SQL scoping are **not** the same at N5 and N1 — each tree has its own `cmd/database_gen.md` runbook.

---

## Repository layout

| Path | Role |
|------|------|
| [`jlpt_vault/app/jlpt_vault/`](jlpt_vault/app/jlpt_vault/) | **Shipping Flutter app** (Dart package name `jlpt_vault`). |
| [`jlpt_vault/`](jlpt_vault/) (rest of folder) | **Merge / ETL**: `cmd/merge_sqlite`, `docs/ETL_MERGE.md`, Postgres schema for the unified merge DB on port **5433** (factories use **5432**). [`jlpt_vault/README.md`](jlpt_vault/README.md) |
| [`n1_app/`](n1_app/) | N1 factory → see [`n1_app/cmd/database_gen.md`](n1_app/cmd/database_gen.md) |
| [`n2_app/`](n2_app/) | N2 factory → [`n2_app/cmd/database_gen.md`](n2_app/cmd/database_gen.md) |
| [`n3_app/`](n3_app/) | N3 factory (legacy Flutter reference under `apps/n3_vault/`) |
| [`n4&5_app/`](n4&5_app/) | N4/N5 factory |

---

## How the multi-LLM pipeline works

Postgres is the **staging factory**. **Go CLIs** call an LLM API (`OPENAI_API_KEY` in local `.env`, never committed). Typical flow (details vary by level — read that level’s `cmd/database_gen.md`):

1. **Docker** — `docker compose up -d` in the factory folder.  
2. **Migrations** — `schema/*.sql`.  
3. **Seed** — CSV → vocab + grammar rules (level-scoped SQL).  
4. **Categorize** — LLM assigns category pillars.  
5. **Vocab** — `generator` → `auditor` ↔ `fixer` (loop until clean).  
6. **Grammar** — `gen_grammar` → `aud_grammar` → `fixer_grammar` (+ optional `scrubber` / `eng_gen`).  
7. **Exporter** — **verified** rows only → SQLite for the app.

“Multi-LLM” = **several tools with different prompts**, not one-shot generation.

The Flutter app loads **per-level** assets from `pubspec.yaml`. Optionally import multiple exports via [`jlpt_vault/cmd/merge_sqlite`](jlpt_vault/cmd/merge_sqlite) ([`docs/ETL_MERGE.md`](jlpt_vault/docs/ETL_MERGE.md)).

---

## Quick start (Flutter app)

```bash
git clone https://github.com/jaxhemopo/jlpt_vault.git jlpt-workspace
cd jlpt-workspace/jlpt_vault/app/jlpt_vault
flutter pub get
flutter run
```

RevenueCat / IAP keys: [`jlpt_vault/SECURITY.md`](jlpt_vault/SECURITY.md) (`--dart-define=REVENUECAT_PUBLIC_API_KEY=...`).

---

## Quick start (one data factory, e.g. N2)

```bash
cd n2_app
docker compose up -d
# Apply schema (goose — see n2_app/cmd/database_gen.md)
# go run ./cmd/seed/… then generator / auditor / …
```

---

## Tech highlights (resume-friendly)

- **Docker**, **Postgres**, **Go** (`database/sql`, LLM HTTP/JSON, SQLite export)  
- **Multi-step LLM QA** for dataset integrity  
- **Flutter** — offline study, SRS  

---

## Contributing

Personal / portfolio project — issues and PRs welcome for typos and docs; for larger changes, open an issue first.

---

## Secrets

Never commit `.env` or store keys in source. See [`.gitignore`](.gitignore) and [`jlpt_vault/SECURITY.md`](jlpt_vault/SECURITY.md).
