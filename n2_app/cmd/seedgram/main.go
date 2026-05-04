package main

import (
	"database/sql"
	"encoding/csv"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"

	"github.com/joho/godotenv"
	_ "github.com/lib/pq"
)

func main() {
	loadEnv()

	db, err := sql.Open("postgres", "postgres://dev_user:dev_password@localhost:5432/mastermind_vault?sslmode=disable")
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()

	file, err := os.Open("n2_grammar.csv")
	if err != nil {
		log.Fatal("❌ Could not open CSV:", err)
	}
	defer file.Close()

	reader := csv.NewReader(file)
	// Skip header
	reader.Read()

	fmt.Println("🏗️  Seeding Grammar Rules (Rules Only)...")

	count := 0
	for {
		record, err := reader.Read()
		if err == io.EOF {
			break
		}

		// Columns: 0:grammar, 1:usage, 2:meaning
		name := record[0]
		structure := record[1]
		meaning := record[2]

		_, err = db.Exec(`
			INSERT INTO grammar_rules (name, structure, meaning, grammar_level)
			VALUES ($1, $2, $3, 'N2')`,
			name, structure, meaning)

		if err == nil {
			count++
		}
	}

	fmt.Printf("✅ Success! Seeded %d grammar rules. Ready for AI Generation.\n", count)
}

func loadEnv() {
	dir, _ := os.Getwd()
	for {
		envPath := filepath.Join(dir, ".env")
		if _, err := os.Stat(envPath); err == nil {
			godotenv.Load(envPath)
			return
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return
		}
		dir = parent
	}
}
