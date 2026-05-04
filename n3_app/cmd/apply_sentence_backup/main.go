// apply_sentence_backup reads a pg_dump file, finds example_sentences COPY data,
// and applies sentence_jp / sentence_en for rows whose backup audit_status != verified.
package main

import (
	"bufio"
	"database/sql"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/joho/godotenv"
	_ "github.com/lib/pq"
)

const defaultAuditComment = "applied_from_backup_2026-04-05"

func main() {
	backupPath := flag.String("backup", "", "path to mastermind_vault_*.sql pg_dump")
	dryRun := flag.Bool("dry-run", false, "parse and report only; no database writes")
	auditMode := flag.String("audit", "pending", "after apply: pending | as-backup | verified")
	flag.Parse()

	if *backupPath == "" {
		log.Fatal("-backup path to .sql dump is required")
	}
	am := strings.ToLower(strings.TrimSpace(*auditMode))
	if am != "pending" && am != "as-backup" && am != "verified" {
		log.Fatal(`-audit must be "pending", "as-backup", or "verified"`)
	}

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

	rows, err := parseExampleSentenceCOPY(*backupPath)
	if err != nil {
		log.Fatal(err)
	}

	var toApply []backupRow
	for _, r := range rows {
		if strings.TrimSpace(r.auditStatus) == "verified" {
			continue
		}
		toApply = append(toApply, r)
	}
	fmt.Printf("parsed %d example_sentences rows; %d not verified in backup\n", len(rows), len(toApply))

	if *dryRun {
		for _, r := range toApply {
			fmt.Printf("dry-run id=%d jp_len=%d en_len=%d backup_status=%q\n",
				r.id, len(r.sentenceJP), len(r.sentenceEN), r.auditStatus)
		}
		fmt.Println("dry-run: no database changes")
		return
	}

	db, err := sql.Open("postgres", "postgres://dev_user:dev_password@localhost:5432/mastermind_vault?sslmode=disable")
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()

	tx, err := db.Begin()
	if err != nil {
		log.Fatal(err)
	}
	defer tx.Rollback()

	updated, missing := 0, 0
	for _, r := range toApply {
		st, cmtPtr := resolveAudit(am, r)
		var cmtAny interface{}
		if cmtPtr != nil {
			cmtAny = *cmtPtr
		}
		res, err := tx.Exec(`
			UPDATE example_sentences
			SET sentence_jp = $1, sentence_en = $2, audit_status = $3, audit_comment = $4
			WHERE id = $5`,
			r.sentenceJP, r.sentenceEN, st, cmtAny, r.id)
		if err != nil {
			log.Fatalf("update id=%d: %v", r.id, err)
		}
		n, _ := res.RowsAffected()
		if n == 0 {
			missing++
			fmt.Printf("skip: no row id=%d\n", r.id)
			continue
		}
		updated++
	}
	if err := tx.Commit(); err != nil {
		log.Fatal(err)
	}
	fmt.Printf("done: updated=%d missing_id=%d\n", updated, missing)
}

type backupRow struct {
	id           int
	sentenceJP   string
	sentenceEN   string
	auditStatus  string
	auditComment string
}

func resolveAudit(mode string, r backupRow) (status string, comment *string) {
	switch mode {
	case "pending":
		return "pending", ptr(defaultAuditComment)
	case "as-backup":
		st := strings.TrimSpace(r.auditStatus)
		if st == "" || st == `\N` {
			st = "pending"
		}
		return st, nullIfBackupN(r.auditComment)
	case "verified":
		return "verified", nil
	default:
		return "pending", ptr(defaultAuditComment)
	}
}

func nullIfBackupN(s string) *string {
	s = strings.TrimSpace(s)
	if s == "" || s == `\N` {
		return nil
	}
	return &s
}

func ptr(s string) *string { return &s }

func parseExampleSentenceCOPY(path string) ([]backupRow, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	sc := bufio.NewScanner(f)
	const maxTok = 32 * 1024 * 1024
	buf := make([]byte, 0, 64*1024)
	sc.Buffer(buf, maxTok)

	inCopy := false
	var acc strings.Builder
	var out []backupRow

	for sc.Scan() {
		line := sc.Text()
		if !inCopy {
			if strings.HasPrefix(line, "COPY public.example_sentences ") {
				inCopy = true
			}
			continue
		}
		if line == `\.` {
			break
		}
		if acc.Len() > 0 {
			acc.WriteByte('\n')
		}
		acc.WriteString(line)

		parts := strings.SplitN(acc.String(), "\t", 9)
		if len(parts) < 9 {
			continue
		}

		id, err := strconv.Atoi(strings.TrimSpace(parts[0]))
		if err != nil {
			acc.Reset()
			continue
		}

		jp := parts[2]
		en := parts[3]
		st := parts[7]
		cmt := parts[8]

		out = append(out, backupRow{
			id:           id,
			sentenceJP:   jp,
			sentenceEN:   en,
			auditStatus:  st,
			auditComment: cmt,
		})
		acc.Reset()
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	if !inCopy {
		return nil, fmt.Errorf("COPY public.example_sentences block not found")
	}
	return out, nil
}
