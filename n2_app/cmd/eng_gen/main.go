package main

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/joho/godotenv"
	_ "github.com/lib/pq"
)

// OpenAIRequest defines the payload sent to the OpenAI API
type OpenAIRequest struct {
	Model       string    `json:"model"`
	Messages    []Message `json:"messages"`
	Temperature float32   `json:"temperature"`
	MaxTokens   int       `json:"max_tokens"`
}

// Message defines the chat messages inside the OpenAI payload
type Message struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// OpenAIResponse defines the expected response structure from OpenAI
type OpenAIResponse struct {
	Choices []struct {
		Message Message `json:"message"`
	} `json:"choices"`
}

func main() {
	// 1. Load Environment Variables
	// Assuming .env is in the root of your n3_app workspace
	err := godotenv.Load("../../.env")
	if err != nil {
		// Fallback: try looking in current directory just in case
		err = godotenv.Load(".env")
		if err != nil {
			log.Println("Warning: Could not load .env file. Falling back to system environment variables.")
		}
	}

	apiKey := os.Getenv("OPENAI_API_KEY")
	if apiKey == "" {
		log.Fatal("ERROR: OPENAI_API_KEY not found in environment!")
	}

	// 2. Database Connection Settings
	connStr := "user=dev_user password=dev_password dbname=mastermind_vault host=localhost port=5432 sslmode=disable"

	log.Println("Connecting to mastermind_vault database...")
	db, err := sql.Open("postgres", connStr)
	if err != nil {
		log.Fatalf("Failed to open database connection: %v", err)
	}
	defer db.Close()

	// Verify connection
	err = db.Ping()
	if err != nil {
		log.Fatalf("Failed to ping database (is the Docker container running?): %v", err)
	}

	// 3. Fetch missing English sentences
	query := `
		SELECT gc.id, gc.sentence_jp, gr.name 
		FROM grammar_cards gc
		LEFT JOIN grammar_rules gr ON gc.grammar_id = gr.id
		WHERE (gc.sentence_en IS NULL OR gc.sentence_en = '')
		AND COALESCE(NULLIF(TRIM(gr.grammar_level), ''), 'N2') = 'N2'
	`

	rows, err := db.Query(query)
	if err != nil {
		log.Fatalf("Failed to query database: %v", err)
	}
	defer rows.Close()

	type Card struct {
		ID          int
		SentenceJP  string
		GrammarRule sql.NullString
	}

	var cards []Card
	for rows.Next() {
		var c Card
		if err := rows.Scan(&c.ID, &c.SentenceJP, &c.GrammarRule); err != nil {
			log.Fatalf("Failed to scan row: %v", err)
		}
		cards = append(cards, c)
	}

	totalCards := len(cards)
	if totalCards == 0 {
		fmt.Println("🎉 No missing English sentences found! The database is fully populated.")
		return
	}

	fmt.Printf("Found %d cards missing English translations. Starting AI processing...\n\n", totalCards)

	// 4. Loop and Translate
	for index, card := range cards {
		ruleName := "Unknown Rule"
		if card.GrammarRule.Valid {
			ruleName = card.GrammarRule.String
		}

		fmt.Printf("[%d/%d] Translating Card ID %d...\n", index+1, totalCards, card.ID)

		translation, err := generateEnglishTranslation(apiKey, card.SentenceJP, ruleName)
		if err != nil {
			log.Printf("   Failed to translate Card ID %d: %v. Skipping...\n\n", card.ID, err)
			continue
		}

		fmt.Printf("   Rule: %s\n", ruleName)
		fmt.Printf("   JP:   %s\n", card.SentenceJP)
		fmt.Printf("   EN:   %s\n\n", translation)

		// 5. Update Database
		updateQuery := `UPDATE grammar_cards SET sentence_en = $1 WHERE id = $2;`
		_, err = db.Exec(updateQuery, translation, card.ID)
		if err != nil {
			log.Printf("   Failed to update database for Card ID %d: %v\n\n", card.ID, err)
			continue
		}

		// Small delay to respect API rate limits
		time.Sleep(300 * time.Millisecond)
	}

	fmt.Println("✅ Finished updating all missing sentences! Your database is whole again.")
}

// generateEnglishTranslation sends a prompt to OpenAI to get the translation
func generateEnglishTranslation(apiKey, japaneseSentence, grammarRule string) (string, error) {
	systemPrompt := `
    You are an expert JLPT N2 Japanese-to-English translator.
    Your task is to translate a Japanese sentence into natural, conversational English.
    
    STRICT RULES:
    1. Output ONLY the English translation. Do not include conversational filler, quotes, or markdown.
    2. The translation MUST accurately reflect the specific nuance of the provided grammar rule.
    3. Ignore inline furigana brackets (e.g., [さる] or (さる)) if they appear in the text. Just translate the raw meaning cleanly.
    `

	userPrompt := fmt.Sprintf("Grammar Rule: %s\nJapanese Sentence: %s\n\nTranslation:", grammarRule, japaneseSentence)

	reqPayload := OpenAIRequest{
		Model: "gpt-4o-mini",
		Messages: []Message{
			{Role: "system", Content: systemPrompt},
			{Role: "user", Content: userPrompt},
		},
		Temperature: 0.3,
		MaxTokens:   150,
	}

	jsonData, err := json.Marshal(reqPayload)
	if err != nil {
		return "", fmt.Errorf("failed to marshal JSON: %w", err)
	}

	req, err := http.NewRequest("POST", "https://api.openai.com/v1/chat/completions", bytes.NewBuffer(jsonData))
	if err != nil {
		return "", fmt.Errorf("failed to create request: %w", err)
	}

	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+apiKey)

	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("API request failed: %w", err)
	}
	defer resp.Body.Close()

	bodyText, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("failed to read response body: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("OpenAI API returned status %d: %s", resp.StatusCode, string(bodyText))
	}

	var openAIResp OpenAIResponse
	if err := json.Unmarshal(bodyText, &openAIResp); err != nil {
		return "", fmt.Errorf("failed to parse OpenAI response: %w", err)
	}

	if len(openAIResp.Choices) == 0 {
		return "", fmt.Errorf("no choices returned by OpenAI")
	}

	return openAIResp.Choices[0].Message.Content, nil
}
