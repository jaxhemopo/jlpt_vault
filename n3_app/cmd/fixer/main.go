package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/joho/godotenv"
	_ "github.com/lib/pq"
	"github.com/sashabaranov/go-openai"
)

type FixResponse struct {
	SentenceJP string `json:"sentence_jp"`
	SentenceEN string `json:"sentence_en"`
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

	fmt.Println("🛠️ STARTING STRICT AUTO-FIXER (IRON-CLAD WORD RETENTION)...")
	fmt.Println("⏳ Sleep mode active: 5-second delay between fixes to maintain audit pace.")

	for {
		var id int
		var kanji, oldJP, oldEN, comment string

		err := db.QueryRow(`
            SELECT es.id, v.kanji, es.sentence_jp, es.sentence_en, es.audit_comment 
            FROM example_sentences es
            JOIN vocabulary v ON v.id = es.vocab_id
            WHERE es.audit_status = 'flagged'
            ORDER BY es.id ASC
            LIMIT 1`).Scan(&id, &kanji, &oldJP, &oldEN, &comment)

		if err == sql.ErrNoRows {
			fmt.Println("🎉 All flags cleared! No more sentences to fix.")
			break
		}

		fmt.Printf("\n🔧 Fixing ID %d (%s)\n🚩 Issue: %s\n", id, kanji, comment)

		// Updated iron-clad prompt: Change context, NOT the word.
		prompt := fmt.Sprintf(`Act as a strict JLPT N3 editor. 
        Fix the Japanese sentence for the vocabulary word: "%s".

        THE MOST IMPORTANT RULE:
        - You MUST keep the target word "%s" in the sentence. 
        - DO NOT replace the target word with a synonym, simpler version, or different Kanji.
        - If the auditor says the word is "incorrect for the context," DO NOT change the word. Instead, REWRITE THE ENTIRE CONTEXT of the sentence so the word "%s" makes perfect sense.
        
        FORMATTING RULES:
        1. You MUST use brackets for furigana: 漢字[かんじ].
        2. The Japanese must be natural and appropriate for its N3/N4 level.
        3. The English MUST be a direct and accurate translation of the NEW Japanese sentence.

        Original Sentence: %s
        Auditor Complaint: %s`,
			kanji, kanji, kanji, oldJP, comment)

		resp, err := client.CreateChatCompletion(
			context.Background(),
			openai.ChatCompletionRequest{
				Model:          openai.GPT4oMini,
				ResponseFormat: &openai.ChatCompletionResponseFormat{Type: openai.ChatCompletionResponseFormatTypeJSONObject},
				Messages: []openai.ChatCompletionMessage{
					{Role: openai.ChatMessageRoleSystem, Content: "Return JSON: {\"sentence_jp\": \"...\", \"sentence_en\": \"...\"}. You are forbidden from removing the target word."},
					{Role: openai.ChatMessageRoleUser, Content: prompt},
				},
			},
		)

		if err != nil {
			fmt.Printf("❌ OpenAI Error: %v\n", err)
			time.Sleep(5 * time.Second) // Also sleep on error to prevent rapid-fire retries
			continue
		}

		var fix FixResponse
		err = json.Unmarshal([]byte(resp.Choices[0].Message.Content), &fix)
		if err != nil {
			fmt.Printf("❌ JSON Unmarshal Error: %v\n", err)
			continue
		}

		// Update the database and reset status to 'pending' for re-auditing
		_, err = db.Exec(`
            UPDATE example_sentences 
            SET sentence_jp = $1, 
                sentence_en = $2, 
                audit_status = 'pending', 
                audit_comment = 'STRICT FIX: ' || $3 
            WHERE id = $4`,
			fix.SentenceJP, fix.SentenceEN, comment, id)

		if err == nil {
			fmt.Printf("✅ Updated ID %d. Target word '%s' preserved. ⏳ Sleeping 5s...\n", id, kanji)
		} else {
			fmt.Printf("❌ DB Update Error: %v\n", err)
		}

		// The 5-second sleeper to avoid outpacing the auditor
		time.Sleep(5 * time.Second)
	}
}
