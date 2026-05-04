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
			SELECT es.id, v.kanji, v.reading, es.sentence_jp, es.sentence_en 
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
			var kanji, reading, jp, en string
			rows.Scan(&id, &kanji, &reading, &jp, &en)
			batchData = append(batchData, map[string]interface{}{
				"id":              id,
				"target_headword": kanji,
				"target_reading":  reading,
				"sentence_jp":     jp,
				"sentence_en":     en,
			})
		}
		rows.Close()

		if len(batchData) == 0 {
			fmt.Println("⏳ No pending sentences found. Sleeping for 25 seconds before next check...")
			time.Sleep(25 * time.Second) // Wait for the Fixer to process some flags
			continue                     // Check the database again
		}

		batchJSON, _ := json.Marshal(batchData)

		prompt := fmt.Sprintf(`Audit these N4/N5 learner sentences (same rules as generator + fixer).

		1) Target: The Japanese must use the listed target_headword naturally in the sentence, consistent with target_reading (lemma + reading from the vocabulary table). English must match the Japanese meaning.
		2) Style: Simple, basic Japanese suitable for N4/N5 — everyday situations. Flag unnecessarily business/office-heavy or overly complex wording unless the headword requires it.
		3) Furigana: Every kanji cluster must have 漢字[hiragana] before any later kanji. Okurigana before [ is OK (食べる[たべる], 友達[ともだち]). Katakana-only words must NOT have brackets.
		4) If 1–3 pass, status "verified". Otherwise "flagged" with a short comment.

		Data: %s`, string(batchJSON))

		resp, err := client.CreateChatCompletion(
			context.Background(),
			openai.ChatCompletionRequest{
				Model:          openai.GPT4oMini,
				ResponseFormat: &openai.ChatCompletionResponseFormat{Type: openai.ChatCompletionResponseFormatTypeJSONObject},
				Messages: []openai.ChatCompletionMessage{
					{Role: openai.ChatMessageRoleSystem, Content: "Return JSON with a results array. Each item: id, status ('verified' or 'flagged' only), comment. Judge using target_headword + target_reading, furigana coverage, translation quality, and simple learner-appropriate Japanese (not business-default)."},
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
