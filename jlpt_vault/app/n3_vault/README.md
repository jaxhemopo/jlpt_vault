# JLPT Vault (Flutter project)

This is the **actual app** that ships — JLPT N5 through N1 in one binary. Study flow is **Anki-style SRS** (spaced repetition with intervals / ease / lapses), not one-and-done flashcards. The folder name stayed `n3_vault` because the App Store listing / Xcode project started life as N3-only and I didn’t want to rename everything and re-trigger half the universe.

For the full story (why I built it, data pipeline, Postgres merge repo), read the repo root [`README.md`](../../README.md).

## Run it

```bash
cd app/n3_vault
flutter pub get
flutter run
```

Bundled SQLite assets and whatever else the app expects are declared in `pubspec.yaml` — if a level’s DB is missing after a fresh clone, that’s the first place to look.

## RevenueCat / IAP

Do not commit API keys. For local runs and release builds, pass the public SDK key at compile time:

```bash
flutter run --dart-define=REVENUECAT_PUBLIC_API_KEY=appl_your_key_here
```

See [`../../SECURITY.md`](../../SECURITY.md) if this repo is ever public or shared.
