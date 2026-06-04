#!/bin/zsh
# Nightly BlueX pipeline: warm model → scrape new posts → coverage-annotate.
# Installed as a launchd agent (net.pulsschlag.bluex.nightly).
set -u

LOG_DIR="$HOME/Library/Logs/BlueX"
mkdir -p "$LOG_DIR"
STAMP=$(date "+%Y-%m-%d_%H%M%S")
LOG="$LOG_DIR/nightly_${STAMP}.log"

BIN_DIR="$HOME/.local/bin"
SCRAPE="$BIN_DIR/blueX-scrape"
ANNOTATE="$BIN_DIR/blueX-annotate"
MODEL="phi4:14b"

{
  echo "=== BlueX nightly $(date) ==="

  # Warm the model so the first annotate request doesn't pay cold-start latency.
  echo "warming $MODEL…"
  curl -s -o /dev/null http://localhost:11434/api/generate \
    -d "{\"model\":\"$MODEL\",\"prompt\":\"warmup\",\"stream\":false}"

  echo "--- scrape ---"
  "$SCRAPE" --pace gentle

  echo "--- coverage annotate ---"
  "$ANNOTATE" --coverage --backfill 5000 --pass llm --model "$MODEL" --pace steady

  echo "=== done $(date) ==="
} >> "$LOG" 2>&1
