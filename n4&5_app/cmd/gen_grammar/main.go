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

	"n3_app/internal/furigana"
	"n3_app/internal/grammarcloze"
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

	fmt.Println("🧠 GRAMMAR GENERATOR: N4/N5 learner mode (5 cards per rule), same furigana rules as vocab")

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
			SELECT r.id, r.name, r.structure, r.meaning, COALESCE(NULLIF(TRIM(r.grammar_level), ''), 'N4/N5')
			FROM grammar_rules r
			LEFT JOIN grammar_cards c ON r.id = c.grammar_id
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

		prompt := fmt.Sprintf(`You create ONE grammar drill card for JLPT learners.

RULE NAME: %s
STRUCTURE / PATTERN (use this in the sentence): %s
MEANING: %s
LEVEL: %s
SCENE (loose hint only): %s — simple, everyday Japanese. Do NOT default to business, office, or heavy keigo.

TASK (JSON fields):
1) sentence_jp — natural Japanese showing the grammar. Must include the pattern from STRUCTURE.
2) sentence_en — accurate English.
3) cloze_sentence_jp — same as sentence_jp but replace ONLY the target grammar chunk with exactly "[____]" (one blank).
4) cloze_answer — the exact substring removed (same characters as in sentence_jp), including any furigana brackets on that chunk if present.

MECHANICAL FURIGANA (validated by code — same as vocabulary app):
- After each contiguous kanji block, put [hiragana] before ANY other kanji appears later in the string. Okurigana before [ is OK: 食べる[たべる], 行[い]きます.
- Katakana words: no furigana brackets.
- WRONG: 今日は… without 今日[きょう]は first. RIGHT: 私[わたし]は今日[きょう]…
- MATHEMATICAL PRECISION: strings.Replace(cloze_sentence_jp, "[____]", cloze_answer, 1) MUST equal sentence_jp exactly (character-for-character).
- Use only square brackets for readings; no parentheses for furigana.`, name, structure, meaning, gLevel, targetContext)

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
Furigana: every kanji cluster must have [reading] before the next kanji (same rules as N4/N5 vocabulary sentences in this app). Katakana: no brackets.
Cloze: one "[____]" only; cloze_answer must splice back to sentence_jp exactly.
Style: short, clear learner Japanese — daily life, not corporate.`,
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

			s, c, a, ok := grammarcloze.FinalizeAfterFuriganaPatch(res.SentenceJP, res.ClozeSentenceJP, res.ClozeAnswer)
			if !ok {
				fmt.Printf("⚠️ attempt %d: cloze math mismatch or blank\n", attempt)
				continue
			}
			res.SentenceJP, res.ClozeSentenceJP, res.ClozeAnswer = s, c, a

			if !furigana.HanClusterCoverageOK(res.SentenceJP) || !furigana.HanClusterCoverageOK(res.ClozeSentenceJP) {
				fmt.Printf("⚠️ attempt %d: furigana coverage failed (N4/N5 kanji rule)\n", attempt)
				continue
			}

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
