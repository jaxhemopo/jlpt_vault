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

type GrammarCardResult struct {
	SentenceJP      string `json:"sentence_jp"`
	SentenceEN      string `json:"sentence_en"`
	ClozeSentenceJP string `json:"cloze_sentence_jp"`
	ClozeAnswer     string `json:"cloze_answer"`
}

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

	fmt.Println("🛠️ SURGICAL FIXER v8: ANCHOR MODE & AUTO-RETRY")

	for {
		var id int
		var rule, meaning, sJP string

		// Fetch one flagged card with target grammar rule context
		err := db.QueryRow(`
			SELECT c.id, r.name, r.meaning, c.sentence_jp 
			FROM grammar_cards c JOIN grammar_rules r ON c.grammar_id = r.id
			WHERE c.audit_status = 'flagged' LIMIT 1`).Scan(&id, &rule, &meaning, &sJP)

		if err == sql.ErrNoRows {
			fmt.Println("😴 Fixer: No flagged items. Waiting 15s...")
			time.Sleep(15 * time.Second)
			continue
		}

		fmt.Printf("\n--- 🛠️ REPAIRING ID: %d (%s) ---\n", id, rule)

		success := false
		// Give the AI 3 attempts to get the math and anchor right
		for attempt := 1; attempt <= 3; attempt++ {
			fmt.Printf("  👉 Attempt %d/3...", attempt)

			//
			prompt := fmt.Sprintf(`Act as a Master JLPT Linguist and String Logic Expert. 

TARGET RULE: "%s"
MEANING: %s

TASK:
1. Provide a natural, high-quality Japanese sentence (sentence_jp).
2. Use EXACT Kanji-level brackets: 成[せい]功[こう] is RIGHT, 成功[せいこう] is WRONG.
3. Identify the 'cloze_answer' as ONLY the target grammar point (%s). 
   - DO NOT include nouns, verbs, or unrelated particles in the answer.
   - Example: If the rule is "とか", the answer must be "とか", NOT "映画[えいが]とか".
4. Create 'cloze_sentence_jp' by replacing that exact anchor with "[____]".

STRICT RULES:
- MATHEMATICAL PRECISION: (cloze_sentence_jp) + (cloze_answer) MUST = (sentence_jp) exactly.
- NO TAIL-END AMNESIA: Keep the punctuation and characters after the blank.
- NO FURIGANA ON KANA: No よう[よう], no プロジェクト[ぷろじぇくと].
- OUTPUT FORMAT: VALID JSON ONLY.`, rule, meaning, rule)

			resp, err := client.CreateChatCompletion(
				context.Background(),
				openai.ChatCompletionRequest{
					Model:          openai.GPT4o,
					ResponseFormat: &openai.ChatCompletionResponseFormat{Type: openai.ChatCompletionResponseFormatTypeJSONObject},
					Messages: []openai.ChatCompletionMessage{
						{Role: openai.ChatMessageRoleSystem, Content: "You are a surgical string-logic expert. Always return data in JSON format."},
						{Role: openai.ChatMessageRoleUser, Content: prompt},
					},
				},
			)

			if err != nil {
				fmt.Printf(" API Error: %v\n", err)
				continue
			}

			var res GrammarCardResult
			if err := json.Unmarshal([]byte(resp.Choices[0].Message.Content), &res); err == nil {
				// Reconstruct and verify
				reconstructed := strings.Replace(res.ClozeSentenceJP, "[____]", res.ClozeAnswer, 1)

				if reconstructed == res.SentenceJP {
					fmt.Printf(" ✅ MATCH FOUND\n")
					_, err = db.Exec(`
						UPDATE grammar_cards 
						SET sentence_jp = $1, sentence_en = $2, cloze_sentence_jp = $3, cloze_answer = $4, audit_status = 'pending' 
						WHERE id = $5`,
						res.SentenceJP, res.SentenceEN, res.ClozeSentenceJP, res.ClozeAnswer, id)

					if err == nil {
						success = true
						break
					}
				} else {
					fmt.Printf(" ❌ MATH MISMATCH\n")
				}
			}
		}

		if !success {
			fmt.Printf(" 🚨 ID %d failed after 3 attempts. Moving to manual_review.\n", id)
			db.Exec("UPDATE grammar_cards SET audit_status = 'manual_review' WHERE id = $1", id)
		}
	}
}
