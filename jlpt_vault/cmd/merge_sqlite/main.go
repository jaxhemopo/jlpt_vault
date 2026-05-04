// Command merge_sqlite imports one level-export SQLite file into jlpt_vault Postgres
// with new surrogate IDs (vocabulary, example_sentences, grammar_rules, grammar_cards).
package main

import (
	"database/sql"
	"flag"
	"fmt"
	"log"
	"os"

	_ "github.com/lib/pq"
	_ "modernc.org/sqlite"
)

func main() {
	pgDSN := flag.String("pg", "postgres://dev_user:dev_password@localhost:5433/jlpt_vault?sslmode=disable", "Postgres DSN")
	sqlitePath := flag.String("sqlite", "", "path to exported vault .db (required)")
	flag.Parse()

	if *sqlitePath == "" {
		fmt.Fprintf(os.Stderr, "usage: merge_sqlite -sqlite /path/to/vault.db [-pg DSN]\n")
		flag.PrintDefaults()
		os.Exit(2)
	}

	sdb, err := sql.Open("sqlite", "file:"+*sqlitePath+"?mode=ro")
	if err != nil {
		log.Fatal(err)
	}
	defer sdb.Close()

	pdb, err := sql.Open("postgres", *pgDSN)
	if err != nil {
		log.Fatal(err)
	}
	defer pdb.Close()

	if err := importVocabulary(sdb, pdb); err != nil {
		log.Fatal("vocabulary: ", err)
	}
	if err := importExampleSentences(sdb, pdb); err != nil {
		log.Fatal("example_sentences: ", err)
	}
	if err := importGrammarRules(sdb, pdb); err != nil {
		log.Fatal("grammar_rules: ", err)
	}
	if err := importGrammarCards(sdb, pdb); err != nil {
		log.Fatal("grammar_cards: ", err)
	}

	log.Println("merge_sqlite: done")
}

var vocabOldToNew = map[int64]int64{}
var grammarOldToNew = map[int64]int64{}

func importVocabulary(sdb, pdb *sql.DB) error {
	rows, err := sdb.Query(`
		SELECT id, kanji, reading, english_meaning, jlpt_level, category
		FROM vocabulary ORDER BY id`)
	if err != nil {
		return err
	}
	defer rows.Close()

	tx, err := pdb.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	stmt, err := tx.Prepare(`
		INSERT INTO vocabulary (kanji, reading, english_meaning, jlpt_level, category, frequency_score)
		VALUES ($1, $2, $3, $4, $5, $6) RETURNING id`)
	if err != nil {
		return err
	}
	defer stmt.Close()

	for rows.Next() {
		var oldID int64
		var kanji, reading, meaning, category sql.NullString
		var jlpt sql.NullInt64
		if err := rows.Scan(&oldID, &kanji, &reading, &meaning, &jlpt, &category); err != nil {
			return err
		}
		jlptVal := int64(3)
		if jlpt.Valid {
			jlptVal = jlpt.Int64
		}
		freqVal := 0
		var newID int64
		err := stmt.QueryRow(
			nullableString(kanji),
			nullableString(reading),
			nullableString(meaning),
			jlptVal,
			nullableString(category),
			freqVal,
		).Scan(&newID)
		if err != nil {
			return fmt.Errorf("old vocab id %d: %w", oldID, err)
		}
		vocabOldToNew[oldID] = newID
	}
	return tx.Commit()
}

func importExampleSentences(sdb, pdb *sql.DB) error {
	rows, err := sdb.Query(`
		SELECT id, vocab_id, sentence_jp, sentence_en, cloze_deletion_index,
		       COALESCE(audit_status, 'pending')
		FROM example_sentences ORDER BY id`)
	if err != nil {
		return err
	}
	defer rows.Close()

	tx, err := pdb.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	stmt, err := tx.Prepare(`
		INSERT INTO example_sentences
		(vocab_id, sentence_jp, sentence_en, cloze_deletion_index, audit_status, audit_comment, sentence_type, grammar_level)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`)
	if err != nil {
		return err
	}
	defer stmt.Close()

	for rows.Next() {
		var oldID, vocabID int64
		var jp, en string
		var cloze sql.NullInt64
		var auditStatus string
		if err := rows.Scan(&oldID, &vocabID, &jp, &en, &cloze, &auditStatus); err != nil {
			return err
		}
		nv, ok := vocabOldToNew[vocabID]
		if !ok {
			return fmt.Errorf("example_sentences id %d: unknown vocab_id %d", oldID, vocabID)
		}
		var clozeV any
		if cloze.Valid {
			clozeV = cloze.Int64
		}
		_, err := stmt.Exec(nv, jp, en, clozeV, auditStatus, nil, nil, nil)
		if err != nil {
			return fmt.Errorf("example_sentences old id %d: %w", oldID, err)
		}
	}
	return tx.Commit()
}

func importGrammarRules(sdb, pdb *sql.DB) error {
	rows, err := sdb.Query(`SELECT id, name, structure, meaning, grammar_level FROM grammar_rules ORDER BY id`)
	if err != nil {
		return err
	}
	defer rows.Close()

	tx, err := pdb.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	stmt, err := tx.Prepare(`
		INSERT INTO grammar_rules (name, structure, meaning, grammar_level)
		VALUES ($1, $2, $3, $4) RETURNING id`)
	if err != nil {
		return err
	}
	defer stmt.Close()

	for rows.Next() {
		var oldID int64
		var name string
		var structure, meaning, level sql.NullString
		if err := rows.Scan(&oldID, &name, &structure, &meaning, &level); err != nil {
			return err
		}
		var newID int64
		err := stmt.QueryRow(name, nullableString(structure), nullableString(meaning), nullableString(level)).Scan(&newID)
		if err != nil {
			return fmt.Errorf("grammar_rules old id %d: %w", oldID, err)
		}
		grammarOldToNew[oldID] = newID
	}
	return tx.Commit()
}

func importGrammarCards(sdb, pdb *sql.DB) error {
	rows, err := sdb.Query(`
		SELECT id, grammar_id, sentence_jp, sentence_en, cloze_sentence_jp, cloze_answer,
		       COALESCE(audit_status, 'pending')
		FROM grammar_cards ORDER BY id`)
	if err != nil {
		return err
	}
	defer rows.Close()

	tx, err := pdb.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	stmt, err := tx.Prepare(`
		INSERT INTO grammar_cards (grammar_id, sentence_jp, sentence_en, cloze_sentence_jp, cloze_answer, audit_status)
		VALUES ($1, $2, $3, $4, $5, $6)`)
	if err != nil {
		return err
	}
	defer stmt.Close()

	for rows.Next() {
		var oldID, grammarID int64
		var jp, en, cjp, cans, audit string
		if err := rows.Scan(&oldID, &grammarID, &jp, &en, &cjp, &cans, &audit); err != nil {
			return err
		}
		ng, ok := grammarOldToNew[grammarID]
		if !ok {
			return fmt.Errorf("grammar_cards id %d: unknown grammar_id %d", oldID, grammarID)
		}
		if _, err := stmt.Exec(ng, jp, en, cjp, cans, audit); err != nil {
			return fmt.Errorf("grammar_cards old id %d: %w", oldID, err)
		}
	}
	return tx.Commit()
}

func nullableString(ns sql.NullString) any {
	if !ns.Valid {
		return nil
	}
	return ns.String
}
