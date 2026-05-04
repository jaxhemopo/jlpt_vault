package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"

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
	if apiKey == "" {
		log.Fatal("❌ OPENAI_API_KEY not found")
	}

	client := openai.NewClient(apiKey)

	fmt.Println("🧠 GRAMMAR GENERATOR: ONE-SHOT FURIGANA MODE (5 CARDS PER RULE)")

	// Added two more contexts to support the 5-card limit
	contexts := []string{"Daily Life", "Professional/Work", "Social/General", "Travel/Dining", "Casual/Friends"}

	for {
		var id int
		var name, structure, meaning string

		// CHANGED: HAVING COUNT(c.id) < 5
		err := db.QueryRow(`
			SELECT r.id, r.name, r.structure, r.meaning 
			FROM grammar_rules r
			LEFT JOIN grammar_cards c ON r.id = c.grammar_id
			GROUP BY r.id, r.name, r.structure, r.meaning
			HAVING COUNT(c.id) < 5
			ORDER BY r.id ASC LIMIT 1`).Scan(&id, &name, &structure, &meaning)

		if err == sql.ErrNoRows {
			fmt.Println("🎉 MISSION ACCOMPLISHED!")
			break
		} else if err != nil {
			log.Fatal(err)
		}

		var currentCount int
		db.QueryRow("SELECT COUNT(*) FROM grammar_cards WHERE grammar_id = $1", id).Scan(&currentCount)
		targetContext := contexts[currentCount]

		fmt.Printf("✍️ Rule: %s [%d/5] | Context: %s\n", name, currentCount+1, targetContext)

		prompt := fmt.Sprintf(`Target Grammar: "%s"
Meaning: %s
Context: %s

TASK:
1. Create a Japanese sentence (sentence_jp) with furigana for EVERY Kanji.
2. Create 'cloze_sentence_jp' where ONLY the grammar point is replaced by [____].
3. Identify 'cloze_answer' as the missing piece.
4. Make sure the sentence is natural and grammatically correct.

STRICT RULES:
- Use SQUARE BRACKETS for furigana: 漢字[かんじ].
- NO PARENTHESES.
- MATHEMATICAL PRECISION: cloze_sentence_jp + cloze_answer MUST = sentence_jp.

EXAMPLE JSON OUTPUT:
{
  "sentence_jp": "会議[かいぎ]が終[お]わり次第[しだい]、連絡[れらぬく]します。",
  "sentence_en": "I will contact you as soon as the meeting ends.",
  "cloze_sentence_jp": "会議[かいぎ]が終[お]わり[____]、連絡[れらぬく]します。",
  "cloze_answer": "次第[しだい]"
}`, name, meaning, targetContext)

		resp, err := client.CreateChatCompletion(
			context.Background(),
			openai.ChatCompletionRequest{
				Model:          openai.GPT4oMini,
				ResponseFormat: &openai.ChatCompletionResponseFormat{Type: openai.ChatCompletionResponseFormatTypeJSONObject},
				Messages: []openai.ChatCompletionMessage{
					{
						Role:    openai.ChatMessageRoleSystem,
						Content: "You are a Japanese linguist. Always return JSON with furigana in [brackets].",
					},
					{Role: openai.ChatMessageRoleUser, Content: prompt},
				},
			},
		)

		if err != nil {
			fmt.Printf("❌ API Error: %v\n", err)
			continue
		}

		var res GrammarCardResult
		err = json.Unmarshal([]byte(resp.Choices[0].Message.Content), &res)
		if err != nil {
			continue
		}

		_, err = db.Exec(`
			INSERT INTO grammar_cards (grammar_id, sentence_jp, sentence_en, cloze_sentence_jp, cloze_answer, audit_status)
			VALUES ($1, $2, $3, $4, $5, 'pending')`,
			id, res.SentenceJP, res.SentenceEN, res.ClozeSentenceJP, res.ClozeAnswer)

		if err != nil {
			fmt.Printf("❌ DB Error: %v\n", err)
		}
	}
}
