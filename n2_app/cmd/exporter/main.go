package main

import (
	"database/sql"
	"fmt"
	"log"
	"os"
	"path/filepath"

	_ "github.com/lib/pq"
	_ "github.com/mattn/go-sqlite3"
)

func main() {
	// 1. Connect to Postgres (The Factory) using your migration schema
	pgConn := "postgres://dev_user:dev_password@localhost:5432/mastermind_vault?sslmode=disable"
	pgDB, err := sql.Open("postgres", pgConn)
	if err != nil {
		log.Fatal("❌ Failed to connect to Postgres:", err)
	}
	defer pgDB.Close()

	// 2. Create the SQLite file (The Asset) for N2 Vault
	cwd, _ := os.Getwd()
	var dbPath string
	if filepath.Base(cwd) == "exporter" {
		dbPath = "../../apps/n2_vault/assets/n2_vault.db"
	} else {
		dbPath = "apps/n2_vault/assets/n2_vault.db"
	}

	fmt.Printf("📂 Target Database: %s\n", dbPath)

	// Force-create the folder structure if it doesn't exist
	if err := os.MkdirAll(filepath.Dir(dbPath), 0755); err != nil {
		log.Fatal("❌ Failed to create directories:", err)
	}

	// Remove old version if it exists to ensure a clean mirror
	_ = os.Remove(dbPath)

	sqliteDB, err := sql.Open("sqlite3", dbPath)
	if err != nil {
		log.Fatal("❌ Failed to create SQLite file:", err)
	}
	defer sqliteDB.Close()

	fmt.Println("🏗️  N2 SQLITE EXPORT (jlpt_level=2 vocab + N2 grammar only)...")

	// 3. Create Tables in SQLite matching your Postgres Migrations (0001 - 0007)
	_, err = sqliteDB.Exec(`
		CREATE TABLE vocabulary (
			id INTEGER PRIMARY KEY,
			kanji TEXT,
			reading TEXT,
			english_meaning TEXT,
			category TEXT,
			jlpt_level INTEGER DEFAULT 2
		);
		CREATE TABLE example_sentences (
			id INTEGER PRIMARY KEY,
			vocab_id INTEGER,
			sentence_jp TEXT,
			sentence_en TEXT,
			cloze_deletion_index INTEGER,
			audit_status TEXT,
			FOREIGN KEY(vocab_id) REFERENCES vocabulary(id) ON DELETE CASCADE
		);
		CREATE TABLE user_vocabulary_progress (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			vocab_id INTEGER UNIQUE,
			state TEXT DEFAULT 'new',
			interval_days INTEGER DEFAULT 0,
			ease_factor REAL DEFAULT 2.5,
			repetition_count INTEGER DEFAULT 0,
			lapses INTEGER DEFAULT 0,
			last_reviewed_at TEXT,
			next_review_at TEXT DEFAULT CURRENT_TIMESTAMP,
			FOREIGN KEY(vocab_id) REFERENCES vocabulary(id) ON DELETE CASCADE
		);
		CREATE TABLE user_grammar_progress (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			grammar_id INTEGER UNIQUE,
			state TEXT DEFAULT 'new',
			interval_days INTEGER DEFAULT 0,
			ease_factor REAL DEFAULT 2.5,
			repetition_count INTEGER DEFAULT 0,
			lapses INTEGER DEFAULT 0,
			last_reviewed_at TEXT,
			next_review_at TEXT DEFAULT CURRENT_TIMESTAMP,
			FOREIGN KEY(grammar_id) REFERENCES grammar_rules(id) ON DELETE CASCADE
		);
		CREATE TABLE grammar_rules (
			id INTEGER PRIMARY KEY,
			name TEXT NOT NULL,
			structure TEXT,
			meaning TEXT,
			grammar_level TEXT DEFAULT 'N2'
		);
		CREATE TABLE grammar_cards (
			id INTEGER PRIMARY KEY,
			grammar_id INTEGER,
			sentence_jp TEXT NOT NULL,
			sentence_en TEXT NOT NULL,
			cloze_sentence_jp TEXT NOT NULL,
			cloze_answer TEXT NOT NULL,
			audit_status TEXT DEFAULT 'pending',
			FOREIGN KEY(grammar_id) REFERENCES grammar_rules(id) ON DELETE CASCADE
		);
	`)
	if err != nil {
		log.Fatal("❌ SQLite Table Creation Error:", err)
	}

	// 4. Export Vocabulary
	fmt.Print("📝 Exporting Vocabulary...")
	vRows, err := pgDB.Query("SELECT id, kanji, reading, english_meaning, category, jlpt_level FROM vocabulary WHERE jlpt_level = 2")
	if err != nil {
		log.Fatal("❌ Postgres Vocabulary Query Error:", err)
	}
	defer vRows.Close()

	for vRows.Next() {
		var id, jlpt int
		var kanji, reading, meaning, cat sql.NullString
		err := vRows.Scan(&id, &kanji, &reading, &meaning, &cat, &jlpt)
		if err != nil {
			log.Fatal("❌ Vocabulary Scan Error:", err)
		}
		_, err = sqliteDB.Exec(`
			INSERT INTO vocabulary (id, kanji, reading, english_meaning, category, jlpt_level) 
			VALUES (?, ?, ?, ?, ?, ?)`,
			id, kanji.String, reading.String, meaning.String, cat.String, jlpt)
		if err != nil {
			log.Fatal("❌ SQLite Vocabulary Insert Error:", err)
		}
	}
	fmt.Println(" Done.")

	// 5. Export ONLY Verified Example Sentences (Vocab)
	fmt.Print("🎴 Exporting Verified Vocab Sentences...")
	sRows, err := pgDB.Query(`
		SELECT es.id, es.vocab_id, es.sentence_jp, es.sentence_en, es.cloze_deletion_index, es.audit_status
		FROM example_sentences es
		JOIN vocabulary v ON v.id = es.vocab_id
		WHERE v.jlpt_level = 2 AND es.audit_status = 'verified'`)
	if err != nil {
		log.Fatal("❌ Postgres Sentences Query Error:", err)
	}
	defer sRows.Close()

	for sRows.Next() {
		var id, vID int
		var cloze sql.NullInt64
		var jp, en, status sql.NullString
		err := sRows.Scan(&id, &vID, &jp, &en, &cloze, &status)
		if err != nil {
			log.Fatal("❌ Sentence Scan Error:", err)
		}
		_, err = sqliteDB.Exec(`
			INSERT INTO example_sentences (id, vocab_id, sentence_jp, sentence_en, cloze_deletion_index, audit_status) 
			VALUES (?, ?, ?, ?, ?, ?)`,
			id, vID, jp.String, en.String, cloze.Int64, status.String)
		if err != nil {
			log.Fatal("❌ SQLite Sentence Insert Error:", err)
		}
	}
	fmt.Println(" Done.")

	// 6. Export Grammar Rules
	fmt.Print("📜 Exporting Grammar Rules...")
	gRulesRows, err := pgDB.Query(`
		SELECT id, name, structure, meaning, grammar_level FROM grammar_rules
		WHERE COALESCE(NULLIF(TRIM(grammar_level), ''), 'N2') = 'N2'`)
	if err != nil {
		log.Fatal("❌ Postgres Grammar Rules Query Error:", err)
	}
	defer gRulesRows.Close()

	for gRulesRows.Next() {
		var id int
		var name, structure, meaning, level sql.NullString
		err := gRulesRows.Scan(&id, &name, &structure, &meaning, &level)
		if err != nil {
			log.Fatal("❌ Grammar Rules Scan Error:", err)
		}
		_, err = sqliteDB.Exec(`
			INSERT INTO grammar_rules (id, name, structure, meaning, grammar_level) 
			VALUES (?, ?, ?, ?, ?)`,
			id, name.String, structure.String, meaning.String, level.String)
		if err != nil {
			log.Fatal("❌ SQLite Grammar Rule Insert Error:", err)
		}
	}
	fmt.Println(" Done.")

	// 7. Export ONLY Verified Grammar Cards
	fmt.Print("🃏 Exporting Verified Grammar Cards...")
	gCardRows, err := pgDB.Query(`
		SELECT gc.id, gc.grammar_id, gc.sentence_jp, gc.sentence_en, gc.cloze_sentence_jp, gc.cloze_answer, gc.audit_status
		FROM grammar_cards gc
		JOIN grammar_rules r ON r.id = gc.grammar_id
		WHERE gc.audit_status = 'verified'
		AND COALESCE(NULLIF(TRIM(r.grammar_level), ''), 'N2') = 'N2'`)
	if err != nil {
		log.Fatal("❌ Postgres Grammar Cards Query Error:", err)
	}
	defer gCardRows.Close()

	gCount := 0
	for gCardRows.Next() {
		var id, gID int
		var jp, en, cJP, ans, status sql.NullString
		err := gCardRows.Scan(&id, &gID, &jp, &en, &cJP, &ans, &status)
		if err != nil {
			log.Fatal("❌ Grammar Card Scan Error:", err)
		}
		_, err = sqliteDB.Exec(`
			INSERT INTO grammar_cards (id, grammar_id, sentence_jp, sentence_en, cloze_sentence_jp, cloze_answer, audit_status) 
			VALUES (?, ?, ?, ?, ?, ?, ?)`,
			id, gID, jp.String, en.String, cJP.String, ans.String, status.String)
		if err != nil {
			log.Fatal("❌ SQLite Grammar Card Insert Error:", err)
		}
		gCount++
	}
	fmt.Printf(" Done (%d grammar cards).\n", gCount)

	fmt.Printf("\n✨ UNIFIED EXPORT COMPLETE! Database saved to: %s\n", dbPath)
}
