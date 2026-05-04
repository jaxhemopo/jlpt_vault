# JLPT Vault (Flutter)

This is the **shipping app** — JLPT N5 through N1 in one binary, with **Anki-style SRS** (intervals, ease, lapses), not one-and-done flashcards.

The Dart package and this folder are named **`jlpt_vault`** so the repo reads cleanly for hiring. It **started as an N3-only side project** for my own exam prep; the Xcode / Android **bundle IDs stayed tied to that original ship** so I did not have to fight App Store churn while the product grew into all levels.

For the full monorepo (factories, Docker, LLM pipelines), read the workspace root [`README.md`](../../../README.md) and [`jlpt_vault/README.md`](../../README.md).

**App Store:** [JLPT Vault (iPhone / iPad)](https://apps.apple.com/jp/app/jlpt-vault-jlpt-study-srs/id6760022205)

## Run it

```bash
cd jlpt_vault/app/jlpt_vault
flutter pub get
flutter run
```

Bundled SQLite assets are listed in `pubspec.yaml`.

## RevenueCat / IAP

Do not commit API keys. Pass the public SDK key at compile time:

```bash
flutter run --dart-define=REVENUECAT_PUBLIC_API_KEY=<your_public_sdk_key>
```

See [`../../SECURITY.md`](../../SECURITY.md).
