package main

import (
	"context"
	"database/sql"
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

func main() {
	// Robust .env loading
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
		log.Fatal("❌ Database Connection Error:", err)
	}
	defer db.Close()

	apiKey := os.Getenv("OPENAI_API_KEY")
	client := openai.NewClient(apiKey)

	fmt.Println("🔍 AUDITOR: STARTING BATCH WASH (5 CARDS)")

	for {
		rows, err := db.Query(`
			SELECT id, sentence_jp, cloze_sentence_jp, cloze_answer 
			FROM grammar_cards 
			WHERE audit_status = 'pending' 
			LIMIT 5`)

		if err != nil {
			fmt.Printf("❌ DB Query Error: %v\n", err)
			time.Sleep(10 * time.Second)
			continue
		}

		found := false
		for rows.Next() {
			found = true
			var id int
			var sJP, cSJP, cAns string
			if err := rows.Scan(&id, &sJP, &cSJP, &cAns); err != nil {
				continue
			}

			// 1. MATHEMATICAL PRECISION CHECK
			// Flutter logic: Concatenating the answer into the blank must create the full sentence exactly.
			reconstructed := strings.Replace(cSJP, "[____]", cAns, 1)

			status := "verified"

			if reconstructed != sJP || cAns == "" || strings.Contains(cAns, "][") {
				status = "flagged"
				fmt.Printf("🚩 Card %d: Logic Failure (Math Mismatch). Flagging.\n", id)
			} else {
				// 2. LINGUISTIC & FORMATTING AUDIT
				resp, err := client.CreateChatCompletion(
					context.Background(),
					openai.ChatCompletionRequest{
						Model: openai.GPT4oMini,
						Messages: []openai.ChatCompletionMessage{
							{
								Role:    openai.ChatMessageRoleSystem,
								Content: "You are a strict Japanese Linguist. Reply ONLY 'valid' or 'invalid'.",
							},
							{
								Role:    openai.ChatMessageRoleUser,
								Content: fmt.Sprintf("Verify: 1. No furigana on Katakana. 2. Brackets follow Kanji only. 3. The Japanese is natural and grammatically correct.\nSentence: %s\nAnswer: %s", sJP, cAns),
							},
						},
					},
				)

				if err != nil || !strings.Contains(strings.ToLower(resp.Choices[0].Message.Content), "valid") {
					status = "flagged"
					fmt.Printf("🚩 Card %d: Linguistic/Formatting Failure. Flagging.\n", id)
				} else {
					fmt.Printf("✅ Card %d: Passed all checks. Verified.\n", id)
				}
			}

			_, err = db.Exec("UPDATE grammar_cards SET audit_status = $1 WHERE id = $2", status, id)
		}
		rows.Close()

		if found {
			fmt.Println("⏳ Auditor batch complete. Sleeping 10s...")
			time.Sleep(10 * time.Second)
		} else {
			fmt.Println("💤 Auditor idle. Sleeping 10s for final check...")
			time.Sleep(10 * time.Second)

			var pendingCount int
			db.QueryRow("SELECT COUNT(*) FROM grammar_cards WHERE audit_status = 'pending'").Scan(&pendingCount)
			if pendingCount == 0 {
				fmt.Println("🛑 Auditor: All clear. Shutting down.")
				break
			}
		}
	}
}
