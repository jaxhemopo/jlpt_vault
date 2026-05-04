package main

import (
	"database/sql"
	"encoding/csv"
	"io"
	"log"
	"os"
	"strings"

	_ "github.com/lib/pq"
)

func main() {
	// 1. Connect using your Docker Compose credentials
	connStr := "postgres://dev_user:dev_password@localhost:5432/mastermind_vault?sslmode=disable"
	db, err := sql.Open("postgres", connStr)
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()

	// 2. Remove only N1 rows (safe on shared mastermind_vault — does not wipe other JLPT levels)
	_, err = db.Exec("DELETE FROM vocabulary WHERE jlpt_level = 1")
	if err != nil {
		log.Fatal("❌ Could not delete N1 vocabulary:", err)
	}

	// 3. Open the Seed CSV
	file, err := os.Open("n1.csv")
	if err != nil {
		log.Fatal("❌ Ensure n1.csv is in the n1_app root when you run this command.")
	}
	defer file.Close()

	reader := csv.NewReader(file)
	_, _ = reader.Read() // Skip Header

	log.Println("🌱 Planting the N1 Vocabulary from CSV...")

	successCount := 0
	for {
		record, err := reader.Read()
		if err == io.EOF {
			break
		}

		// Mapping based on your CSV:
		// 0: expression (kanji), 1: reading, 2: meaning, 3: tags
		kanji := record[0]
		reading := record[1]
		meaning := record[2]

		// 4. Default category logic
		category := "Daily Life"
		if strings.Contains(strings.ToLower(meaning), "participation") || strings.Contains(strings.ToLower(meaning), "management") {
			category = "Work"
		}

		// 5. INDIVIDUAL INSERTS
		_, err = db.Exec(`INSERT INTO vocabulary (kanji, reading, english_meaning, category, jlpt_level) 
						  VALUES ($1, $2, $3, $4, 1)`,
			kanji, reading, meaning, category)
		if err != nil {
			log.Printf("⚠️ Skip error on %s: %v", kanji, err)
			continue
		}
		successCount++
	}

	log.Printf("✅ Rebirth Complete! %d N1 words added to the vault.", successCount)
}
