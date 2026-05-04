# N4/N5 Vault: Offline SRS Engine

A specialized JLPT N4/N5 study utility built for offline learning. 

### 🛠 Tech Stack
- **Framework:** Flutter (Mobile)
- **Database:** SQLite (Relational Data Modeling)
- **Architecture:** Clean Architecture / Provider Pattern
- **Logic:** Custom Spaced Repetition System (SRS)

### 🚀 Engineering Highlights
- **Local-First Architecture:** 100% offline functionality ensuring zero-latency study sessions.
- **Relational Data Modeling:** Optimized schema for 4,750+ active study nodes.
- **Advanced UI:** Custom Glassmorphism implementation with dynamic Furigana rendering.

*Note: This repository contains the UI and Architectural framework. The proprietary dataset and core commercial logic are maintained in a private repository.*

### 🧠 AI-Augmented Data Pipeline
Engineered a Python-based ETL pipeline to generate and validate 4,750+ JLPT N4/N5 study items.

- **Iterative Refinement:** Implemented a 'Generate -> Audit -> Fix' loop using LLM APIs to ensure 99%+ accuracy in sentence parsing and furigana placement.
- **Postgres to SQLite Migration:** Managed the transition from a highly-relational Postgres development environment to a compact, optimized SQLite database for 100% offline mobile performance.
- **Automated QA:** Built custom Python scripts to identify and resolve linguistic inconsistencies before final production deployment.