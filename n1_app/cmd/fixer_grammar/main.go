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

	"n1_app/internal/grammarcloze"
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

	fmt.Println("🛠️ N1 GRAMMAR FIXER: grammar_level=N1 flagged cards")

	for {
		var id int
		var rule, structure, meaning, sJP string

		err := db.QueryRow(`
			SELECT c.id, r.name, r.structure, r.meaning, c.sentence_jp 
			FROM grammar_cards c JOIN grammar_rules r ON c.grammar_id = r.id
			WHERE c.audit_status = 'flagged'
			AND COALESCE(NULLIF(TRIM(r.grammar_level), ''), 'N1') = 'N1'
			LIMIT 1`).Scan(&id, &rule, &structure, &meaning, &sJP)

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
			prompt := fmt.Sprintf(`Fix this grammar drill card for a JLPT N1 app (furigana optional on common kanji).

RULE NAME: %s
STRUCTURE / PATTERN: %s
MEANING: %s

TASK:
1) sentence_jp — natural Japanese at N1 level (not corporate-default). Must use the grammar pattern.
2) Furigana: add 漢字[よみ] only where it helps N1 learners; plain kanji OK for common vocabulary. No brackets on katakana.
3) cloze_answer — the exact substring removed for the blank (may include furigana on kanji inside the chunk).
4) cloze_sentence_jp — sentence_jp with that exact chunk replaced by "[____]" once only.

MATHEMATICAL PRECISION: strings.Replace(cloze_sentence_jp, "[____]", cloze_answer, 1) MUST equal sentence_jp exactly.

Broken card (for context): %s`, rule, structure, meaning, sJP)

			resp, err := client.CreateChatCompletion(
				context.Background(),
				openai.ChatCompletionRequest{
					Model:          openai.GPT4oMini,
					Temperature:    0.35,
					ResponseFormat: &openai.ChatCompletionResponseFormat{Type: openai.ChatCompletionResponseFormatTypeJSONObject},
					Messages: []openai.ChatCompletionMessage{
						{Role: openai.ChatMessageRoleSystem, Content: "Return JSON only: sentence_jp, sentence_en, cloze_sentence_jp, cloze_answer. N1 furigana policy (optional on common kanji); one [____]; cloze must splice exactly."},
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
				res.SentenceEN = strings.TrimSpace(res.SentenceEN)

				s, c, a, ok := grammarcloze.FinalizeN2LearnerCloze(res.SentenceJP, res.ClozeSentenceJP, res.ClozeAnswer)
				if !ok {
					fmt.Printf(" ❌ CLOZE MATH\n")
					continue
				}
				res.SentenceJP, res.ClozeSentenceJP, res.ClozeAnswer = s, c, a

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
			}
		}

		if !success {
			fmt.Printf(" 🚨 ID %d failed after 3 attempts. Moving to manual_review.\n", id)
			db.Exec("UPDATE grammar_cards SET audit_status = 'manual_review' WHERE id = $1", id)
		}
	}
}
