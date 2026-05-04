package main

import (
	"database/sql"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"regexp"

	"github.com/joho/godotenv"
	_ "github.com/lib/pq"
)

func main() {
	dir, _ := os.Getwd()
	for {
		envPath := filepath.Join(dir, ".env")
		if _, err := os.Stat(envPath); err == nil {
			godotenv.Load(envPath)
			break
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}

	db, err := sql.Open("postgres", "postgres://dev_user:dev_password@localhost:5432/mastermind_vault?sslmode=disable")
	if err != nil {
		log.Fatal("❌ DB Connection Error:", err)
	}
	defer db.Close()

	fmt.Println("🧹 N2 GRAMMAR SCRUBBER: grammar_level=N2 cards — kana/katakana bracket cleanup")

	// Regex 1: Matches any Kana character followed by the same kana in brackets (e.g., な[な])
	kanaFurigana := regexp.MustCompile(`([ぁ-んァ-ヶ])\[[ぁ-ん]+\]`)

	// Regex 2: Matches Katakana words followed by brackets (e.g., プロジェクト[ぷろじぇくと])
	katakanaBrackets := regexp.MustCompile(`([ァ-ヶー]+)\[[ぁ-ん]+\]`)

	rows, _ := db.Query(`
		SELECT c.id, c.sentence_jp, c.cloze_sentence_jp, c.cloze_answer
		FROM grammar_cards c
		JOIN grammar_rules r ON r.id = c.grammar_id
		WHERE COALESCE(NULLIF(TRIM(r.grammar_level), ''), 'N2') = 'N2'`)
	count := 0

	for rows.Next() {
		var id int
		var sJP, cSJP, cAns string
		rows.Scan(&id, &sJP, &cSJP, &cAns)

		// Apply the "Surgical Scrub"
		newSJP := kanaFurigana.ReplaceAllString(sJP, "$1")
		newSJP = katakanaBrackets.ReplaceAllString(newSJP, "$1")

		newCSJP := kanaFurigana.ReplaceAllString(cSJP, "$1")
		newCSJP = katakanaBrackets.ReplaceAllString(newCSJP, "$1")

		newCAns := kanaFurigana.ReplaceAllString(cAns, "$1")
		newCAns = katakanaBrackets.ReplaceAllString(newCAns, "$1")

		if newSJP != sJP || newCAns != cAns {
			count++
			db.Exec(`UPDATE grammar_cards 
				SET sentence_jp = $1, cloze_sentence_jp = $2, cloze_answer = $3 
				WHERE id = $4`, newSJP, newCSJP, newCAns, id)
		}
	}
	fmt.Printf("🛑 Scrubbing complete. Cleaned %d cards.\n", count)
}
