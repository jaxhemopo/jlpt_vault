# 🏯 N3 Vault: The Language Engineering Factory

**N3 Vault** is more than just a Japanese study app—it’s a high-performance data pipeline designed to build language apps at scale. I built this as a **System Template**; by swapping the source CSV files and running the Go factory, you can generate a completely new app (N4, N5, Spanish, etc.) in minutes.

The project is split into two halves: a **Go/PostgreSQL backend** that handles the heavy data lifting and a **Flutter/SQLite mobile app** built for 100% offline study.

---

## 🏗️ Architecture Overview

1. **The Data Factory (Go + PostgreSQL)**: An ETL pipeline that ingests raw words, uses AI to generate sentences, audits them for quality, and exports a compressed SQLite database.
2. **The Vault App (Flutter + SQLite)**: A mobile client featuring a strict Anki-standard Spaced Repetition System (SRS) and a UI built for raw retention.

---

## 🏭 1. The Data Factory (Go/Postgres)
**Location:** `/cmd/` and `/schema/`

Instead of serving data over the internet, I use Postgres as a "factory floor" to clean and prep data before shipping it to the device.

### The Pipeline Lifecycle:
* **Ingestion (`/seed`)**: Grabs raw `.csv` files and seeds the core words into Postgres.
* **Generation (`/generator`)**: Orchestrates LLMs to generate two distinct Japanese example sentences (Casual & Formal) for every single word, including English translations.
* **The Audit Loop (`/auditor`, `/fixer`)**: This is the secret sauce. The auditor programmatically flags AI generations that use the wrong Kanji or grammar levels. The `fixer` then re-processes those specific records until they are perfect. 
* **The Build (`/exporter`)**: Compiles only the "verified" rows into a highly optimized, read-only `n3_vault.db` SQLite file and drops it straight into the Flutter assets.

---

## 📱 2. The Vault App (Flutter)
**Location:** `/apps/n3_vault/`

The app is built to be fast and 100% offline. It reads from the injected SQLite database and tracks your progress locally.

### Anki-Standard SRS (SM-2)
I skipped the basic "flashcard" logic and implemented a mathematically rigorous **Spaced Repetition System**:
* 📘 **New (Blue)**: Unseen cards limited by your daily quota.
* 📕 **Learning (Red)**: Items in the active memorization phase (1m, 10m steps).
* 📗 **Review (Green)**: Mature cards scheduled for long-term review based on your performance.

### Independent Quotas
Vocabulary and Grammar are treated as separate ecosystems. If you set a 20-card limit, you get 20 of each, ensuring you don't neglect grammar for easy vocab wins.

---

## 🚀 How to Launch a New App (e.g., N4 Vault)
The "System Template" approach makes scaling easy:
1. Drop a new `N4_Words.csv` into the root.
2. Spin up Postgres (`docker-compose up -d`) and run migrations.
3. Run the Go factory sequence: `seed` → `generate` → `audit` → `export`.
4. Grab the new `.db` file, update the Flutter theme, and ship.

---

## 📋 Technical Skills Demonstrated
* **Go (Golang)**: Building CLI tools, handling SQL logic, and structured data processing.
* **PostgreSQL**: Schema design, data normalization, and state persistence.
* **System Design**: Orchestrating the transition from a heavy Postgres staging environment to a compact Mobile SQLite engine.
* **Automation**: Building self-correcting AI audit loops to ensure data integrity.

---
*Built by [Jackson Hemopo](https://github.com/jaxhemopo)*