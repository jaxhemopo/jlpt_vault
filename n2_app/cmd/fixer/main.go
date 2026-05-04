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

	fmt.Println("🛠️ N2 VOCAB FIXER (jlpt_level=2 only, iron-clad headword retention)...")
	fmt.Println("⏳ Sleep mode active: 5-second delay between fixes to maintain audit pace.")

	for {
		var id int
		var kanji, reading, oldJP, oldEN, comment string

		err := db.QueryRow(`
            SELECT es.id, v.kanji, v.reading, es.sentence_jp, es.sentence_en, es.audit_comment 
            FROM example_sentences es
            JOIN vocabulary v ON v.id = es.vocab_id
            WHERE v.jlpt_level = 2
            AND es.audit_status = 'flagged'
            ORDER BY es.id ASC
            LIMIT 1`).Scan(&id, &kanji, &reading, &oldJP, &oldEN, &comment)

		if err == sql.ErrNoRows {
			fmt.Println("🎉 All flags cleared! No more sentences to fix.")
			break
		}

		fmt.Printf("\n🔧 Fixing ID %d (%s / %s)\n🚩 Issue: %s\n", id, kanji, reading, comment)

		prompt := fmt.Sprintf(`Act as a strict JLPT N2 editor.

        TARGET (from vocabulary table — do not change the lemma):
        - Headword: %s
        - Reading (learner must use this reading): %s

        IRON RULES:
        - Keep the target headword "%s" in the fixed Japanese. Do not swap for a synonym or different kanji.
        - If the auditor complained about "context," rewrite the rest of the sentence so "%s" fits naturally — do not remove the headword.

        STYLE (same as generator): Daily line ~N3 grammar; formal line ~N2. Natural everyday / study / travel contexts — avoid corporate-default tone unless the word demands it.

        FORMATTING:
        - Furigana (N2 policy): optional on common N4–N5 kanji; add 漢字[よみ] for harder/ambiguous kanji and for the target headword when it uses kanji. No brackets on katakana-only words.

        Original Japanese: %s
        Original English: %s
        Auditor complaint: %s`,
			kanji, reading, kanji, kanji, oldJP, oldEN, comment)

		resp, err := client.CreateChatCompletion(
			context.Background(),
			openai.ChatCompletionRequest{
				Model:          openai.GPT4oMini,
				ResponseFormat: &openai.ChatCompletionResponseFormat{Type: openai.ChatCompletionResponseFormatTypeJSONObject},
				Messages: []openai.ChatCompletionMessage{
					{Role: openai.ChatMessageRoleSystem, Content: "Return JSON: {\"sentence_jp\": \"...\", \"sentence_en\": \"...\"}. Preserve the target headword. Furigana optional on common kanji; add readings where helpful for N2. N2-appropriate Japanese (daily ~N3 / formal ~N2). English must match the new Japanese."},
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
