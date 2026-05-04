# JLPT Vault

On GitHub this directory sits inside the **monorepo root** next to the per-level factories (`n1_app/`, `n2_app/`, `n3_app/`, `n4&5_app/`). See the root [`README.md`](../README.md) for the full map.

JLPT Vault is a single Flutter app where you pick a level (N5 through N1) and study vocab + grammar offline-style from bundled SQLite databases. Reviews are **Anki-style spaced repetition (SRS)** — intervals, ease, lapses, that whole rhythm — not a static deck you read once. I built it for myself first, then kept going.

## Why this exists

I originally hacked together an N3-focused study app because I was sitting the JLPT N3 and wanted something that matched how I actually revise (Anki-style SRS, furigana, not another generic flashcard dump). A friend was doing N2 around the same time, so I reused the bones of that N3 build and spun an N2-flavoured version for them. After that it felt silly to maintain separate apps per level, so I folded everything into one “vault” app with all levels in one place.

## What I actually did vs where I got help

On the **backend / data** side I leaned on what I picked up from **Boot.dev** (Postgres, thinking in schemas, small Go tools, not treating the database like a junk drawer). Each JLPT level has its own **factory folder** next to this one in the repo: CSVs → Docker Postgres → generate / audit / fix loops (LLM-assisted) → export SQLite → bundle into the app.

I have **basically no frontend background** and I’m not a Flutter/Dart person. For **UI and UX** I used AI heavily to get screens that don’t look like I drew them in MS Paint, then I wired things up, broke them, fixed them, and lived with whatever Apple’s review process threw at me. I still own the architecture, the data pipeline, and what ships.

## Where the app lives (yes, the folder name is weird)

The **shipping app** is under [`app/n3_vault`](app/n3_vault). The folder is still called `n3_vault` on purpose: the binary was already on the App Store under that project, and renaming the module / bundle just to match marketing copy would have meant more review churn than I cared to deal with. So the repo says “vault for all levels” and the directory says `n3_vault` — same app, don’t read too much into the path.

At runtime the user picks a level; the app loads the right bundled SQLite (e.g. per-level vault DBs under assets — see `pubspec.yaml` in that project for what’s actually bundled).

## Monorepo bits (if you’re me in six months)

**Postgres (merge / ETL playground)** — from *this* `jlpt_vault` directory:

```bash
docker compose up -d
```

| Setting | Value |
|--------|--------|
| Host | `localhost` |
| Port | **5433** (container listens on 5432 inside) |
| Database | `jlpt_vault` (override with env — see below) |

**Credentials:** don’t paste passwords into docs or commits. Copy [`.env.example`](.env.example) to `.env` in `jlpt_vault/` if you want non-default values; `docker-compose.yml` reads `POSTGRES_USER`, `POSTGRES_PASSWORD`, and `POSTGRES_DB` (defaults match local dev).

**Connection string for tools (goose, psql):** build it yourself, e.g.  
`postgres://$POSTGRES_USER:$POSTGRES_PASSWORD@localhost:5433/$POSTGRES_DB?sslmode=disable`  
after exporting those vars from `.env` or your shell.

Apply schema with [goose](https://github.com/pressly/goose) from `jlpt_vault/schema` — details in [`docs/ETL_MERGE.md`](docs/ETL_MERGE.md).

**App / RevenueCat:** see [`SECURITY.md`](SECURITY.md) for how IAP keys are supplied without committing them.

**Merging exports / building assets** — see [`docs/ETL_MERGE.md`](docs/ETL_MERGE.md) and [`cmd/merge_sqlite`](cmd/merge_sqlite).

**Flutter** — open [`app/n3_vault`](app/n3_vault), run `flutter pub get`, then `flutter run` (or build from Xcode/Android Studio like any other Flutter app).

## Reference

The older N3-only reference app still lives under `n3_app/apps/n3_vault` in the parent workspace; I didn’t migrate that history into this repo’s app folder.
