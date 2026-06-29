#!/bin/bash
# Weekly JLPT Vault card validation (no LLM — mechanical checks only).
set -euo pipefail

REPO="/Users/jacksonhemopo/workspace/JLPT APPS"
LOG_DIR="$REPO/jlpt_vault/audit/logs"
mkdir -p "$LOG_DIR"

STAMP="$(date -u +%Y%m%d_%H%M%S)"
LOG="$LOG_DIR/validate_${STAMP}.log"

{
  echo "=== JLPT Vault validate_cards — $(date -u '+%Y-%m-%d %H:%M:%S UTC') ==="
  cd "$REPO"
  RC=0
  /usr/bin/python3 jlpt_vault/scripts/validate_cards.py --report || RC=$?
  echo "=== done exit=$RC ==="
} >> "$LOG" 2>&1

# Keep last 8 weekly logs
ls -1t "$LOG_DIR"/validate_*.log 2>/dev/null | tail -n +9 | while IFS= read -r f; do rm -f "$f"; done
