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

type SentenceResult struct {
	ID             int    `json:"id"`
	DailySentence  string `json:"daily_sentence"`
	FormalSentence string `json:"formal_sentence"`
	EnglishDaily   string `json:"english_daily"`
	EnglishFormal  string `json:"english_formal"`
}

func stripBrackets(s string) string {
	for {
		start := strings.Index(s, "[")
		end := strings.Index(s, "]")
		if start == -1 || end == -1 || end < start {
			break
		}
		s = s[:start] + s[end+1:]
	}
	return s
}

func cleanWord(w string) string {
	parts := strings.Split(w, ";")
	w = parts[0]
	w = strings.ReplaceAll(w, "(かん)", "")
	w = strings.ReplaceAll(w, "（かん）", "")
	return strings.TrimSpace(w)
}

func getStem(w string) string {
	runes := []rune(w)
	if len(runes) < 2 {
		return w
	}
	return string(runes[:len(runes)-1])
}

func stripSlotPrefix(word string) (after string, isPattern bool) {
	word = strings.TrimSpace(word)
	if strings.HasPrefix(word, "～") {
		return strings.TrimPrefix(word, "～"), true
	}
	if strings.HasPrefix(word, "~") {
		return strings.TrimPrefix(word, "~"), true
	}
	return word, false
}

func unifyWave(w string) string {
	return strings.ReplaceAll(strings.TrimSpace(w), "~", "～")
}

func normalizeHeadwordMatch(w string) string {
	w = unifyWave(w)
	w = strings.ReplaceAll(w, "（て）", "て")
	w = strings.ReplaceAll(w, "(て)", "て")
	return strings.TrimSpace(w)
}

func headwordMatchHint(cleanK string) string {
	nk := normalizeHeadwordMatch(cleanK)
	if sfx, ok := stripSlotPrefix(nk); ok && sfx != "" {
		return "suffix after ～: " + sfx
	}
	if strings.HasSuffix(nk, "する") {
		return strings.TrimSuffix(nk, "する") + " (+する)"
	}
	return getStem(cleanK)
}

func wordAppearsInJapanese(plain, raw, cleanK, cleanR string) bool {
	checks := []string{plain, raw}
	nk := normalizeHeadwordMatch(cleanK)
	nr := normalizeHeadwordMatch(cleanR)

	for _, s := range checks {
		for _, w := range []string{cleanK, cleanR, nk, nr} {
			if w != "" && strings.Contains(s, w) {
				return true
			}
		}
	}

	for _, w := range []string{nk, nr} {
		if w == "" {
			continue
		}
		if strings.Contains(w, "～") {
			parts := strings.Split(w, "～")
			if wavePartsAllIn(parts, checks) {
				return true
			}
		}
	}

	for _, w := range []string{nk, nr} {
		if strings.HasSuffix(w, "する") {
			base := strings.TrimSuffix(w, "する")
			if len([]rune(base)) >= 1 {
				for _, s := range checks {
					if strings.Contains(s, base) {
						return true
					}
				}
			}
		}
	}

	for _, s := range checks {
		if !strings.HasSuffix(cleanK, "する") {
			st := getStem(cleanK)
			if st != "" && strings.Contains(s, st) {
				return true
			}
		}
		if !strings.HasSuffix(cleanR, "する") {
			st := getStem(cleanR)
			if st != "" && strings.Contains(s, st) {
				return true
			}
		}
	}

	for _, w := range []string{nk, nr} {
		rest, slot := stripSlotPrefix(w)
		if !slot || rest == "" {
			continue
		}
		rest = strings.TrimSpace(rest)
		for _, s := range checks {
			if rest != "" && strings.Contains(s, rest) {
				return true
			}
			if strings.Contains(rest, "しまう") &&
				(strings.Contains(s, "しまう") || strings.Contains(s, "てしまう") || strings.Contains(s, "でしまう")) {
				return true
			}
		}
	}

	return false
}

func wavePartsAllIn(parts []string, checks []string) bool {
	seen := false
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		seen = true
		ok := false
		for _, s := range checks {
			if strings.Contains(s, p) {
				ok = true
				break
			}
		}
		if !ok {
			return false
		}
	}
	return seen
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
		log.Fatal("❌ DB Connection Error:", err)
	}
	defer db.Close()

	apiKey := os.Getenv("OPENAI_API_KEY")
	if apiKey == "" {
		log.Fatal("❌ OPENAI_API_KEY not found")
	}

	client := openai.NewClient(apiKey)

	fmt.Println("📢 STARTING GENERATOR - AUDIT MODE (PENDING)")

	for {
		var id int
		var kanji, reading, category string

		// Fetch words that have been categorized but have NO sentences yet
		err := db.QueryRow(`
            SELECT v.id, v.kanji, v.reading, v.category 
            FROM vocabulary v
            LEFT JOIN example_sentences es ON v.id = es.vocab_id
            WHERE v.category IS NOT NULL
            AND es.vocab_id IS NULL
            ORDER BY v.id ASC
            LIMIT 1`).Scan(&id, &kanji, &reading, &category)

		if err == sql.ErrNoRows {
			fmt.Println("🎉 MISSION ACCOMPLISHED: All current words have sentences!")
			break
		} else if err != nil {
			log.Fatal("❌ SQL Query Error:", err)
		}

		cleanK := cleanWord(kanji)
		cleanR := cleanWord(reading)

		success := false
		for attempts := 1; attempts <= 3; attempts++ {
			fmt.Printf("\n--- 🎯 [%d/3] Target: %s (%s) | Category: %s ---\n", attempts, cleanK, cleanR, category)

			prompt := fmt.Sprintf(`Act as a JLPT N3 teacher. 
            Generate 2 sentences for the word: %s. Use the category '%s' for context.
            1. Daily: Use N4 level grammar. 
            2. Formal: Use N3 level grammar.
            If the headword starts with ～, that marks a slot (number/name/etc.): do NOT need the ～ in the sentence—use a natural filled-in example (e.g. ３月 for ～月, ３区 for ～区) and include the fixed part (after ～) with furigana.
            Formatting: You MUST use brackets for furigana like 漢字[かんじ].`, cleanK, category)

			resp, err := client.CreateChatCompletion(
				context.Background(),
				openai.ChatCompletionRequest{
					Model:          openai.GPT4oMini,
					ResponseFormat: &openai.ChatCompletionResponseFormat{Type: openai.ChatCompletionResponseFormatTypeJSONObject},
					Messages: []openai.ChatCompletionMessage{
						{
							Role: openai.ChatMessageRoleSystem,
							Content: `Return JSON. Fields: id, daily_sentence, formal_sentence, english_daily, english_formal. 
                            IMPORTANT: The sentence MUST make logical sense. If the category doesn't fit the word naturally, prioritize natural usage over the category.`,
						},
						{Role: openai.ChatMessageRoleUser, Content: prompt},
					},
				},
			)

			if err != nil {
				fmt.Printf("❌ OpenAI API Error: %v\n", err)
				time.Sleep(2 * time.Second)
				continue
			}

			var res SentenceResult
			err = json.Unmarshal([]byte(resp.Choices[0].Message.Content), &res)
			if err != nil {
				fmt.Printf("❌ JSON PARSE ERROR: %v\n", err)
				continue
			}

			dailyJP := stripBrackets(res.DailySentence)
			formalJP := stripBrackets(res.FormalSentence)
			if wordAppearsInJapanese(dailyJP, res.DailySentence, cleanK, cleanR) &&
				wordAppearsInJapanese(formalJP, res.FormalSentence, cleanK, cleanR) {

				_, err := db.Exec(`
                    INSERT INTO example_sentences (vocab_id, sentence_jp, sentence_en, sentence_type, grammar_level, audit_status)
                    VALUES ($1, $2, $3, 'daily', 'N4', 'pending'), ($1, $4, $5, 'formal', 'N3', 'pending')`,
					id, res.DailySentence, res.EnglishDaily, res.FormalSentence, res.EnglishFormal)

				if err == nil {
					fmt.Printf("✅ SAVED AS PENDING: %s\n", cleanK)
					success = true
					break
				} else {
					fmt.Printf("❌ DATABASE INSERT ERROR: %v\n", err)
				}
			} else {
				fmt.Printf("⚠️ VALIDATION FAILED: target not found in both JP sentences (%s)\n", headwordMatchHint(cleanK))
			}
		}

		if !success {
			fmt.Printf("🚨 SKIPPING: %s after 3 failed attempts.\n", cleanK)
			// Small sleep to prevent infinite rapid looping on a problematic word
			time.Sleep(1 * time.Second)
		}
	}
}

func loadEnv() {
	dir, _ := os.Getwd()
	for {
		envPath := filepath.Join(dir, ".env")
		if _, err := os.Stat(envPath); err == nil {
			godotenv.Load(envPath)
			return
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return
		}
		dir = parent
	}
}
