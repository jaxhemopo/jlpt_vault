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
	if apiKey == "" {
		log.Fatal("❌ OPENAI_API_KEY not found")
	}

	client := openai.NewClient(apiKey)

	fmt.Println("🧠 N1 GRAMMAR GENERATOR: N1 rules only (5 cards); furigana optional on common kanji")

	// Simple everyday contexts — not business/office default (matches vocabulary generator)
	contexts := []string{
		"Daily Life",
		"Family & Friends",
		"School & Study",
		"Travel & Town",
		"Food & Shopping",
	}

	for {
		var id int
		var name, structure, meaning, gLevel string

		err := db.QueryRow(`
			SELECT r.id, r.name, r.structure, r.meaning, COALESCE(NULLIF(TRIM(r.grammar_level), ''), 'N1')
			FROM grammar_rules r
			LEFT JOIN grammar_cards c ON r.id = c.grammar_id
			WHERE COALESCE(NULLIF(TRIM(r.grammar_level), ''), 'N1') = 'N1'
			GROUP BY r.id, r.name, r.structure, r.meaning, r.grammar_level
			HAVING COUNT(c.id) < 5
			ORDER BY r.id ASC LIMIT 1`).Scan(&id, &name, &structure, &meaning, &gLevel)

		if err == sql.ErrNoRows {
			fmt.Println("🎉 MISSION ACCOMPLISHED!")
			break
		} else if err != nil {
			log.Fatal(err)
		}

		var currentCount int
		db.QueryRow("SELECT COUNT(*) FROM grammar_cards WHERE grammar_id = $1", id).Scan(&currentCount)
		targetContext := contexts[currentCount]

		fmt.Printf("✍️ Rule: %s [%d/5] | Level: %s | Context: %s\n", name, currentCount+1, gLevel, targetContext)

		prompt := fmt.Sprintf(`You create ONE grammar drill card for JLPT N1 learners.

RULE NAME: %s
STRUCTURE / PATTERN (use this in the sentence): %s
MEANING: %s
LEVEL: %s
SCENE (loose hint only): %s — natural Japanese at N1 level: media, abstract argument, formal prose, or educated conversation. Do NOT default to business, office, or heavy keigo only.

TASK (JSON fields):
1) sentence_jp — natural Japanese showing the grammar. Must include the pattern from STRUCTURE.
2) sentence_en — accurate English.
3) cloze_sentence_jp — same as sentence_jp but replace ONLY the target grammar chunk with exactly "[____]" (one blank).
4) cloze_answer — the grammar chunk removed for the blank (should match the substring of sentence_jp; if you add furigana only on the full sentence, the pipeline still aligns the blank from sentence_jp).

FURIGANA (N1 learners — not full-ruby like N4/N5):
- Optional on common kanji an advanced learner knows. Add 漢字[よみ] for harder / ambiguous characters or where it helps the learner.
- No brackets on katakana-only words. Square brackets for readings only.
- MATHEMATICAL PRECISION: strings.Replace(cloze_sentence_jp, "[____]", cloze_answer, 1) MUST equal sentence_jp exactly (character-for-character).`, name, structure, meaning, gLevel, targetContext)

		inserted := false
		for attempt := 1; attempt <= 3; attempt++ {
			resp, err := client.CreateChatCompletion(
				context.Background(),
				openai.ChatCompletionRequest{
					Model:          openai.GPT4oMini,
					Temperature:    0.35,
					ResponseFormat: &openai.ChatCompletionResponseFormat{Type: openai.ChatCompletionResponseFormatTypeJSONObject},
					Messages: []openai.ChatCompletionMessage{
						{
							Role: openai.ChatMessageRoleSystem,
							Content: `Return JSON only: sentence_jp, sentence_en, cloze_sentence_jp, cloze_answer.
Furigana: N1 policy — optional on common kanji; add readings where helpful. No brackets on katakana.
Cloze: one "[____]" only; cloze_answer must splice back to sentence_jp exactly.
Style: natural JLPT N1-level Japanese — not corporate-default.`,
						},
						{Role: openai.ChatMessageRoleUser, Content: prompt},
					},
				},
			)

			if err != nil {
				fmt.Printf("❌ API Error (attempt %d): %v\n", attempt, err)
				continue
			}

			var res GrammarCardResult
			if err = json.Unmarshal([]byte(resp.Choices[0].Message.Content), &res); err != nil {
				fmt.Printf("❌ JSON parse (attempt %d): %v\n", attempt, err)
				continue
			}

			res.SentenceEN = strings.TrimSpace(res.SentenceEN)

			s, c, a, ok := grammarcloze.FinalizeN2LearnerCloze(res.SentenceJP, res.ClozeSentenceJP, res.ClozeAnswer)
			if !ok {
				fmt.Printf("⚠️ attempt %d: cloze math mismatch or blank\n", attempt)
				continue
			}
			res.SentenceJP, res.ClozeSentenceJP, res.ClozeAnswer = s, c, a

			_, err = db.Exec(`
			INSERT INTO grammar_cards (grammar_id, sentence_jp, sentence_en, cloze_sentence_jp, cloze_answer, audit_status)
			VALUES ($1, $2, $3, $4, $5, 'pending')`,
				id, res.SentenceJP, res.SentenceEN, res.ClozeSentenceJP, res.ClozeAnswer)

			if err != nil {
				fmt.Printf("❌ DB Error: %v\n", err)
				break
			}
			inserted = true
			fmt.Printf("✅ Saved card (attempt %d)\n", attempt)
			break
		}
		if !inserted {
			fmt.Printf("🚨 SKIPPED rule card after 3 attempts: %s\n", name)
		}
	}
}
