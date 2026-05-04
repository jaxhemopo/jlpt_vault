package main

import (
	"database/sql"
	"fmt"
	"log"
	"net/http"
	"os"

	"github.com/joho/godotenv"
	_ "github.com/lib/pq"
)

func main() {
	// 1. Load .env for local development
	_ = godotenv.Load()

	// 2. Connect to Database (using Docker service name 'postgres_db')
	dbURL := os.Getenv("DB_URL")
	if dbURL == "" {
		dbURL = "postgres://dev_user:dev_password@localhost:5432/mastermind_vault?sslmode=disable"
	}

	db, err := sql.Open("postgres", dbURL)
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()

	// 3. Simple Health Check
	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "Mastermind App is running! 🚀")
	})

	fmt.Println("Server starting on :8080...")
	log.Fatal(http.ListenAndServe(":8080", nil))
}
