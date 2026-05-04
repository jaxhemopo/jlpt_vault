# JLPT Vault (merge + docs)

This directory sits inside the **monorepo root** next to the per-level factories (`n1_app/`, `n2_app/`, …). See the root [`README.md`](../README.md) for the full map.

The **Flutter client** — the app learners install — lives in [`app/jlpt_vault/`](app/jlpt_vault/) (Dart package **`jlpt_vault`**). It began as an **N3-only** prototype; the product name and folder now match **JLPT Vault** for clarity, while **store bundle IDs** on iOS/Android were left alone so releases did not turn into a full re-signing / resubmission project.

JLPT Vault is one app where you pick a level (N5 through N1) and study vocab + grammar from bundled SQLite. Reviews are **Anki-style SRS** — intervals, ease, lapses — not a static deck you read once.

## Why this exists

I built the first version for my own JLPT N3 prep (SRS, furigana, not generic flashcards). A friend needed N2, so I reused the bones for them. After that, folding everything into **one vault** beat maintaining separate apps per level.

## What I actually did vs where I got help

On the **backend / data** side I leaned on **Boot.dev**-style skills: Postgres, small Go tools, migrations, treating the DB as a real factory floor, not a junk drawer. Each JLPT level has its own **factory folder** so prompts, furigana policy, and SQL scoping can differ. Flow is **seed → categorize → multi-LLM loops (vocab: generator / auditor / fixer; grammar: gen_grammar / aud_grammar / fixer_grammar) → exporter → per-level `.db`**.

I have **basically no frontend background** and I am not a Flutter/Dart specialist. For **UI/UX** I leaned on AI assistance, then wired, debugged, and shipped the integration myself.

## Where the Flutter app lives

- **App Store (install / test on device):** [JLPT Vault](https://apps.apple.com/jp/app/jlpt-vault-jlpt-study-srs/id6760022205)  
- **Source:** [`app/jlpt_vault/`](app/jlpt_vault/) — run `flutter pub get` / `flutter run` from there.  
- **Assets:** bundled SQLite paths are in `app/jlpt_vault/pubspec.yaml`.

## Postgres (merge / ETL) — this `jlpt_vault/` folder only

```bash
docker compose up -d
```

| Setting | Value |
|--------|--------|
| Host | `localhost` |
| Port | **5433** (container listens on 5432 inside) |
| Database | `jlpt_vault` (override with env — see below) |

**Credentials:** copy [`.env.example`](.env.example) to `.env` here if you override defaults; `docker-compose.yml` reads `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`.

**Connection string for tools:** e.g.  
`postgres://$POSTGRES_USER:$POSTGRES_PASSWORD@localhost:5433/$POSTGRES_DB?sslmode=disable`  
after exporting vars from `.env` or your shell.

Apply schema with [goose](https://github.com/pressly/goose) from `jlpt_vault/schema` — [`docs/ETL_MERGE.md`](docs/ETL_MERGE.md).

**App / RevenueCat:** [`SECURITY.md`](SECURITY.md).

**Merge tool:** [`cmd/merge_sqlite`](cmd/merge_sqlite) + [`docs/ETL_MERGE.md`](docs/ETL_MERGE.md).

## Reference

The older **N3-only** reference Flutter tree still lives under `n3_app/apps/n3_vault/` in this monorepo; it is not the shipping JLPT Vault client.
