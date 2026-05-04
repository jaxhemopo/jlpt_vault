package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"strings"
	"time" // Added for the sleep functionality

	"github.com/joho/godotenv"
	_ "github.com/lib/pq"
	"github.com/sashabaranov/go-openai"
)

type AuditResult struct {
	ID      int    `json:"id"`
	Status  string `json:"status"` // MUST be "verified" or "flagged"
	Comment string `json:"comment"`
}

type AuditBatchResponse struct {
	Results []AuditResult `json:"results"`
}

func main() {
	// Robust Env Loader: Search multiple levels up for .env
	_ = godotenv.Load(".env")
	_ = godotenv.Load("../.env")
	_ = godotenv.Load("../../.env")
	_ = godotenv.Load("../../../.env")

	apiKey := os.Getenv("OPENAI_API_KEY")
	if apiKey == "" {
		log.Fatal("❌ API Key not found. Ensure OPENAI_API_KEY is set in your .env file.")
	}

	db, err := sql.Open("postgres", "postgres://dev_user:dev_password@localhost:5432/mastermind_vault?sslmode=disable")
	if err != nil {
		log.Fatal("❌ DB Connection Error:", err)
	}
	defer db.Close()

	client := openai.NewClient(apiKey)

	fmt.Println("🔎 STARTING STRICT AUDIT (THROTTLED MODE)...")

	for {
		rows, err := db.Query(`
			SELECT es.id, v.kanji, es.sentence_jp, es.sentence_en 
			FROM example_sentences es
			JOIN vocabulary v ON v.id = es.vocab_id
			WHERE es.audit_status = 'pending'
			LIMIT 20`)
		if err != nil {
			log.Fatal(err)
		}

		var batchData []map[string]interface{}
		for rows.Next() {
			var id int
			var kanji, jp, en string
			rows.Scan(&id, &kanji, &jp, &en)
			batchData = append(batchData, map[string]interface{}{
				"id":       id,
				"target":   kanji,
				"sentence": jp,
				"english":  en,
			})
		}
		rows.Close()

		if len(batchData) == 0 {
			fmt.Println("⏳ No pending sentences found. Sleeping for 25 seconds before next check...")
			time.Sleep(25 * time.Second) // Wait for the Fixer to process some flags
			continue                     // Check the database again
		}

		batchJSON, _ := json.Marshal(batchData)

		prompt := fmt.Sprintf(`Audit these Japanese sentences.
		Rules:
		1. If the sentence correctly uses the target word, has correct furigana brackets 漢字[かんじ], and accurate English, status is "verified".
		2. Otherwise, status is "flagged" and you MUST provide a comment explaining why.
		
		Data: %s`, string(batchJSON))

		resp, err := client.CreateChatCompletion(
			context.Background(),
			openai.ChatCompletionRequest{
				Model:          openai.GPT4oMini,
				ResponseFormat: &openai.ChatCompletionResponseFormat{Type: openai.ChatCompletionResponseFormatTypeJSONObject},
				Messages: []openai.ChatCompletionMessage{
					{Role: openai.ChatMessageRoleSystem, Content: "Return JSON. Status field MUST be exactly 'verified' or 'flagged'. Do not use slashes."},
					{Role: openai.ChatMessageRoleUser, Content: prompt},
				},
			},
		)

		if err != nil {
			fmt.Printf("❌ OpenAI Error: %v\n", err)
			time.Sleep(5 * time.Second) // Short sleep on error to avoid spamming
			continue
		}

		var auditResponse AuditBatchResponse
		err = json.Unmarshal([]byte(resp.Choices[0].Message.Content), &auditResponse)
		if err != nil {
			fmt.Printf("❌ JSON Error: %v\n", err)
			continue
		}

		for _, res := range auditResponse.Results {
			finalStatus := strings.ToLower(res.Status)
			if strings.Contains(finalStatus, "flag") {
				finalStatus = "flagged"
			} else {
				finalStatus = "verified"
			}

			_, err := db.Exec(`
				UPDATE example_sentences 
				SET audit_status = $1, audit_comment = $2 
				WHERE id = $3`,
				finalStatus, res.Comment, res.ID)

			if err == nil {
				icon := "✅"
				if finalStatus == "flagged" {
					icon = "🚩"
				}
				fmt.Printf("%s ID %d: %s\n", icon, res.ID, finalStatus)
			}
		}

		// Optional: Even after a successful batch, wait a few seconds to let the Fixer breathe
		fmt.Println("⏲️ Batch complete. Cooling down for 5 seconds...")
		time.Sleep(5 * time.Second)
	}
}
