package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/joho/godotenv"
	_ "github.com/lib/pq"
	"github.com/sashabaranov/go-openai"
)

type AIResult struct {
	ID             int    `json:"id"`
	Category       string `json:"category"`
	FrequencyScore int    `json:"frequency_score"`
}

var validPillars = map[string]struct{}{
	"Family": {}, "Work": {}, "Travel": {}, "Food": {},
	"Health": {}, "Society": {}, "Nature": {}, "Emotions": {},
}

func normalizeCategory(s string) string {
	c := strings.TrimSpace(s)
	if _, ok := validPillars[c]; ok {
		return c
	}
	log.Printf("⚠️ Unknown category %q — clamping to Society", s)
	return "Society"
}

func clampFrequency(n int) int {
	if n < 1 {
		return 1
	}
	if n > 100 {
		return 100
	}
	return n
}

func main() {
	// 1. Optimized .env loading
	loadEnv()

	db, err := sql.Open("postgres", "postgres://dev_user:dev_password@localhost:5432/mastermind_vault?sslmode=disable")
	if err != nil {
		log.Fatal("❌ DB Connection Error:", err)
	}
	defer db.Close()

	// Optimize DB settings for batch processing
	db.SetMaxOpenConns(10)

	apiKey := os.Getenv("OPENAI_API_KEY")
	if apiKey == "" {
		log.Fatal("❌ OPENAI_API_KEY not found")
	}

	client := openai.NewClient(apiKey)

	// Prepare the update statement once to reuse it (Performance boost)
	stmt, err := db.Prepare("UPDATE vocabulary SET category = $1, frequency_score = $2 WHERE id = $3")
	if err != nil {
		log.Fatal(err)
	}
	defer stmt.Close()

	fmt.Println("🚀 Starting Optimized Categorization...")

	for {
		// Fetch next batch
		rows, err := db.Query(`
			SELECT id, kanji, reading FROM vocabulary
			WHERE jlpt_level = 2
			AND (category IS NULL OR category = 'Daily Life')
			LIMIT 25`)
		if err != nil {
			log.Printf("❌ Query Error: %v", err)
			time.Sleep(2 * time.Second)
			continue
		}

		var batch []map[string]interface{}
		for rows.Next() {
			var id int
			var kanji, reading string
			if err := rows.Scan(&id, &kanji, &reading); err == nil {
				batch = append(batch, map[string]interface{}{"id": id, "kanji": kanji, "reading": reading})
			}
		}
		rows.Close()

		if len(batch) == 0 {
			fmt.Println("🎉 All words categorized! Mission accomplished.")
			break
		}

		// 2. High-Precision Prompting
		resp, err := client.CreateChatCompletion(
			context.Background(),
			openai.ChatCompletionRequest{
				Model:          openai.GPT4oMini,
				ResponseFormat: &openai.ChatCompletionResponseFormat{Type: openai.ChatCompletionResponseFormatTypeJSONObject},
				Messages: []openai.ChatCompletionMessage{
					{
						Role: openai.ChatMessageRoleSystem,
						Content: `You are a Japanese Linguistics Expert. Categorize N2 words.
						The field "category" MUST be EXACTLY one of these 8 strings (case-sensitive, no synonyms):
						Family, Work, Travel, Food, Health, Society, Nature, Emotions.
						Assign frequency_score (integer 1-100) for daily-life frequency.
						Return JSON only: {"results": [{"id": 1, "category": "Work", "frequency_score": 85}]}`,
					},
					{Role: openai.ChatMessageRoleUser, Content: fmt.Sprintf("Categorize: %v", batch)},
				},
			},
		)

		if err != nil {
			log.Printf("❌ OpenAI Error: %v (Retrying in 5s)", err)
			time.Sleep(5 * time.Second)
			continue
		}

		var response struct {
			Results []AIResult `json:"results"`
		}
		if err := json.Unmarshal([]byte(resp.Choices[0].Message.Content), &response); err != nil {
			log.Printf("❌ JSON Error: %v", err)
			continue
		}

		// 3. Optimized Batch Update
		tx, err := db.Begin()
		if err != nil {
			log.Printf("❌ Begin tx: %v", err)
			continue
		}
		for _, res := range response.Results {
			cat := normalizeCategory(res.Category)
			freq := clampFrequency(res.FrequencyScore)
			_, err := tx.Stmt(stmt).Exec(cat, freq, res.ID)
			if err != nil {
				log.Printf("⚠️ Update error ID %d: %v", res.ID, err)
			}
		}
		if err := tx.Commit(); err != nil {
			log.Printf("❌ Commit: %v", err)
		}

		fmt.Printf("✅ Processed %d words. Continuing...\n", len(response.Results))
	}
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
