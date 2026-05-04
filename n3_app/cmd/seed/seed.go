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

	// 2. CLEAR THE DECK (Start fresh)
	_, err = db.Exec("TRUNCATE TABLE vocabulary RESTART IDENTITY CASCADE;")
	if err != nil {
		log.Fatal("❌ Could not truncate table:", err)
	}

	// 3. Open the Seed CSV
	file, err := os.Open("N3_2000.csv")
	if err != nil {
		log.Fatal("❌ Ensure N3_2000.csv is in this folder.")
	}
	defer file.Close()

	reader := csv.NewReader(file)
	_, _ = reader.Read() // Skip Header

	log.Println("🌱 Planting the N3 Vocabulary from CSV...")

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

		// 5. INDIVIDUAL INSERTS - Updated column to 'english_meaning'
		_, err = db.Exec(`INSERT INTO vocabulary (kanji, reading, english_meaning, category) 
						  VALUES ($1, $2, $3, $4)`,
			kanji, reading, meaning, category)
		if err != nil {
			log.Printf("⚠️ Skip error on %s: %v", kanji, err)
			continue
		}
		successCount++
	}

	log.Printf("✅ Rebirth Complete! %d words added to the vault.", successCount)
}
