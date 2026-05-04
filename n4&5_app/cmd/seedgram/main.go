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

	fmt.Println("🏗️  Seeding Grammar Rules (Rules Only)...")

	count := 0
	inputFiles := []struct {
		name  string
		level string
	}{
		{name: "n4_grammar.csv", level: "N4"},
		{name: "n5_grammar.csv", level: "N5"},
	}
	for _, meta := range inputFiles {
		file, err := os.Open(meta.name)
		if err != nil {
			log.Fatal(fmt.Sprintf("❌ Could not open CSV %s: %v", meta.name, err))
		}

		reader := csv.NewReader(file)
		// Skip header
		_, _ = reader.Read()

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
				VALUES ($1, $2, $3, $4)`,
				name, structure, meaning, meta.level)

			if err == nil {
				count++
			}
		}
		_ = file.Close()
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
