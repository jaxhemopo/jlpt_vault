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

	fmt.Println("🔍 N1 GRAMMAR AUDITOR: grammar_level=N1 cards, batch 5")

	for {
		rows, err := db.Query(`
			SELECT c.id, c.sentence_jp, c.cloze_sentence_jp, c.cloze_answer, r.name, r.meaning
			FROM grammar_cards c
			JOIN grammar_rules r ON r.id = c.grammar_id
			WHERE c.audit_status = 'pending'
			AND COALESCE(NULLIF(TRIM(r.grammar_level), ''), 'N1') = 'N1'
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
			var sJP, cSJP, cAns, ruleName, ruleMeaning string
			if err := rows.Scan(&id, &sJP, &cSJP, &cAns, &ruleName, &ruleMeaning); err != nil {
				continue
			}

			reconstructed := strings.Replace(cSJP, "[____]", cAns, 1)

			status := "verified"

			if reconstructed != sJP || cAns == "" || strings.Contains(cAns, "][") ||
				strings.Count(cSJP, "[____]") != 1 {
				status = "flagged"
				fmt.Printf("🚩 Card %d: Logic failure (cloze math or blank). Flagging.\n", id)
			} else {
				resp, err := client.CreateChatCompletion(
					context.Background(),
					openai.ChatCompletionRequest{
						Model: openai.GPT4oMini,
						Messages: []openai.ChatCompletionMessage{
							{
								Role:    openai.ChatMessageRoleSystem,
								Content: "You are a strict JLPT N1 editor. Reply ONLY 'valid' or 'invalid'.",
							},
							{
								Role: openai.ChatMessageRoleUser,
								Content: fmt.Sprintf(`Check this JLPT N1 grammar card (N1 furigana policy: full ruby not required on common kanji).

Grammar rule: %s — %s

1) Cloze: replacing "[____]" once with cloze_answer must yield sentence_jp (already verified mechanically — sanity-check).
2) Furigana: if present, readings should be plausible; no brackets on katakana-only words. Omitting ruby on easy kanji is OK.
3) Japanese: natural N1 level; not unnecessarily business/office-heavy.
4) Grammar rule should appear correctly used in the sentence.

sentence_jp: %s
cloze_answer: %s

Reply valid or invalid only.`, ruleName, ruleMeaning, sJP, cAns),
							},
						},
					},
				)

				low := strings.ToLower(strings.TrimSpace(resp.Choices[0].Message.Content))
				fields := strings.Fields(low)
				first := ""
				if len(fields) > 0 {
					first = strings.TrimRight(fields[0], ".,!;:")
				}
				linguisticOK := err == nil && first == "valid"
				if !linguisticOK {
					status = "flagged"
					fmt.Printf("🚩 Card %d: Linguistic / style check. Flagging.\n", id)
				} else {
					fmt.Printf("✅ Card %d: Verified.\n", id)
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
			db.QueryRow(`
				SELECT COUNT(*) FROM grammar_cards c
				JOIN grammar_rules r ON r.id = c.grammar_id
				WHERE c.audit_status = 'pending'
				AND COALESCE(NULLIF(TRIM(r.grammar_level), ''), 'N1') = 'N1'`).Scan(&pendingCount)
			if pendingCount == 0 {
				fmt.Println("🛑 Auditor: All clear. Shutting down.")
				break
			}
		}
	}
}
