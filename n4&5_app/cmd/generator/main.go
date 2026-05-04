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
	"unicode"

	"github.com/joho/godotenv"
	"github.com/lib/pq"
	"github.com/sashabaranov/go-openai"

	"n3_app/internal/furigana"
)

type SentenceResult struct {
	DailySentence  string `json:"daily_sentence"`
	FormalSentence string `json:"formal_sentence"`
	EnglishDaily   string `json:"english_daily"`
	EnglishFormal  string `json:"english_formal"`
}

func headwordHasKanji(s string) bool {
	for _, r := range s {
		if unicode.Is(unicode.Han, r) {
			return true
		}
	}
	return false
}

func clipRunes(s string, max int) string {
	r := []rune(s)
	if len(r) <= max {
		return s
	}
	return string(r[:max]) + "…"
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

// stripSlotPrefix returns the headword after a leading ～ / ~ slot marker (JLPT pattern entries like ～区, ～月).
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

// normalizeHeadwordMatch normalizes parenthetical て so ～(て) しまう matches ～て しまう-style output.
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

// wordAppearsInJapanese checks the target headword appears in model output.
// plain is bracket-stripped (legacy); raw keeps readings inside […] so 怪我[けが] still matches けが.
// Handles: ～する (do not use stem けがす), いくら～ても, leading ～, ～(て) しまう.
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
		// ～おわる headword: model often writes 終わる/終わりました without kana "おわる" substring.
		if rest == "おわる" {
			for _, s := range checks {
				if strings.Contains(s, "終わ") || strings.Contains(s, "おわり") ||
					strings.Contains(s, "おわっ") || strings.Contains(s, "おわる") {
					return true
				}
			}
		}
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

	skipped := make(map[int]struct{})

	for {
		var id int
		var kanji, reading, category string

		skipIDs := make([]int64, 0, len(skipped))
		for sid := range skipped {
			skipIDs = append(skipIDs, int64(sid))
		}

		// Fetch words that have been categorized but have NO sentences yet (skip IDs that failed this run)
		err := db.QueryRow(`
            SELECT v.id, v.kanji, v.reading, v.category 
            FROM vocabulary v
            LEFT JOIN example_sentences es ON v.id = es.vocab_id
            WHERE v.category IS NOT NULL
            AND es.vocab_id IS NULL
            AND NOT (v.id = ANY($1::bigint[]))
            ORDER BY v.id ASC
            LIMIT 1`, pq.Array(skipIDs)).Scan(&id, &kanji, &reading, &category)

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

			kanaOnlyNote := ""
			if !headwordHasKanji(cleanK) {
				kanaOnlyNote = `
            KANA-ONLY TARGET (no kanji in the headword): Prefer writing BOTH Japanese sentences using only hiragana and katakana. If you introduce ANY kanji at all, every kanji cluster must use 漢字[よみ] before the next kanji in the sentence (same mechanical rule as below).`
			}

			prompt := fmt.Sprintf(`Act as a JLPT N4/N5 teacher.

            TARGET (from database — you MUST use this lemma in BOTH Japanese sentences, with this reading when the word uses kanji):
            - Headword (kanji/kana column): %s
            - Reading (must match how the learner says it): %s
            Category "%s" is a loose theme only: prefer simple, everyday situations (home, school, friends, shopping). Do NOT default to business, office, or formal workplace Japanese unless the headword itself is clearly work-specific.
            %s
            Output: exactly 2 Japanese sentences + 2 English translations.
            1) daily_sentence + english_daily: easy N5-level grammar, short and natural.
            2) formal_sentence + english_formal: still learner-friendly N4-level grammar — polite but not corporate/business tone.

            If the headword starts with ～, that marks a slot: omit ～ in the sentence; fill naturally (e.g. 新宿[しんじゅく] for a place + 区[く] for ～区) and furigana EVERY kanji in the sentence the same way.

            MECHANICAL FURIGANA (validated by code — violations are rejected):
            Read left-to-right. After each contiguous block of kanji, you must place [hiragana] before ANY other kanji appears later in the string. Hiragana/katakana/punctuation between two kanji blocks is OK; another kanji before [ is NOT OK.
            Okurigana attached to the kanji may appear before the bracket: 踏[ふ]みます, 食べる[たべる], 友達[ともだち].
            WRONG: 私は今日はいい天気です。 (「今」 appears before 「私」 has [よみ])
            RIGHT: 私[わたし]は今日[きょう]はいい天気[てんき]です。
            WRONG: 公園で道を踏みます。
            RIGHT: 公園[こうえん]で道[みち]を踏[ふ]みます。
            Katakana-only words: no brackets.`, cleanK, cleanR, category, kanaOnlyNote)

			resp, err := client.CreateChatCompletion(
				context.Background(),
				openai.ChatCompletionRequest{
					Model:       openai.GPT4oMini,
					Temperature: 0.35,
					ResponseFormat: &openai.ChatCompletionResponseFormat{Type: openai.ChatCompletionResponseFormatTypeJSONObject},
					Messages: []openai.ChatCompletionMessage{
						{
							Role: openai.ChatMessageRoleSystem,
							Content: `Return JSON only. Fields: daily_sentence, formal_sentence, english_daily, english_formal.
                            Japanese must include the target headword from the user message in BOTH daily_sentence and formal_sentence, using the listed reading.
                            Style: simple, basic N4/N5 Japanese for learners — everyday life, not business or office scenarios unless the word demands it.
                            Furigana (machine-checked): after every kanji cluster, [hiragana] must appear before the next kanji anywhere in the string. Okurigana before [ is OK (踏[ふ]みます, 食べる[たべる]). Never 私は今日… — use 私[わたし]は今日[きょう]…. Katakana-only words: no brackets.
                            English lines must accurately translate the Japanese lines.`,
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

			res.DailySentence = furigana.PatchCommonFuriganaGaps(strings.TrimSpace(res.DailySentence))
			res.FormalSentence = furigana.PatchCommonFuriganaGaps(strings.TrimSpace(res.FormalSentence))

			dailyJP := stripBrackets(res.DailySentence)
			formalJP := stripBrackets(res.FormalSentence)
			if !wordAppearsInJapanese(dailyJP, res.DailySentence, cleanK, cleanR) ||
				!wordAppearsInJapanese(formalJP, res.FormalSentence, cleanK, cleanR) {
				fmt.Printf("⚠️ VALIDATION FAILED: target not found in both JP sentences (%s)\n", headwordMatchHint(cleanK))
				continue
			}
			if !furigana.HanClusterCoverageOK(res.DailySentence) || !furigana.HanClusterCoverageOK(res.FormalSentence) {
				fmt.Printf("⚠️ VALIDATION FAILED: N4/N5 furigana — each kanji block needs [reading] before the next 漢字 (okurigana before [ is OK)\n")
				if !furigana.HanClusterCoverageOK(res.DailySentence) {
					fmt.Printf("   daily JP: %s\n", clipRunes(res.DailySentence, 240))
				}
				if !furigana.HanClusterCoverageOK(res.FormalSentence) {
					fmt.Printf("   formal JP: %s\n", clipRunes(res.FormalSentence, 240))
				}
				continue
			}

			_, err = db.Exec(`
                    INSERT INTO example_sentences (vocab_id, sentence_jp, sentence_en, sentence_type, grammar_level, audit_status)
                    VALUES ($1, $2, $3, 'daily', 'N5', 'pending'), ($1, $4, $5, 'formal', 'N4', 'pending')`,
				id, res.DailySentence, res.EnglishDaily, res.FormalSentence, res.EnglishFormal)

			if err == nil {
				fmt.Printf("✅ SAVED AS PENDING: %s\n", cleanK)
				success = true
				break
			}
			fmt.Printf("❌ DATABASE INSERT ERROR: %v\n", err)
		}

		if !success {
			fmt.Printf("🚨 SKIPPING: %s after 3 failed attempts.\n", cleanK)
			skipped[id] = struct{}{}
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
