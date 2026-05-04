# Secrets and keys

## RevenueCat (in-app purchases)

The **public** RevenueCat Apple API key must **not** live in source control. It is supplied at **compile time**:

```bash
flutter run --dart-define=REVENUECAT_PUBLIC_API_KEY=appl_your_key_here
```

Release / archive builds (Xcode, CI) should inject the same `--dart-define` (or your pipeline’s equivalent). If the key is missing, the app skips RevenueCat configuration where the code path allows it (see `lib/iap_manager.dart`).

**If this key was ever committed to git before:** rotate it in the RevenueCat dashboard and update your local / CI defines only — do not put the new key back into the repo.

## Postgres (local Docker)

Default dev credentials can be overridden via environment variables (see `docker-compose.yml` and `.env.example`). Do not commit a `.env` file with real production passwords.

## OpenAI / LLM keys (Go pipelines)

Per-level factory apps use a root `.env` with `OPENAI_API_KEY`. That file is listed in `.gitignore` at the workspace root — keep it that way.
