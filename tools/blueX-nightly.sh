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

# Overlap guard: a run can outlast 24h (large backfill + slow Ollama + thermal
# back-off). Two annotators against the same SwiftData store risk corruption, so
# refuse to start if a previous run still holds the lock. mkdir is atomic.
LOCK="$LOG_DIR/nightly.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "$(date): previous nightly run still active ($LOCK exists) — skipping." >> "$LOG"
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

{
  echo "=== BlueX nightly $(date) ==="

  # Warm the model so the first annotate request doesn't pay cold-start latency.
  echo "warming $MODEL…"
  curl -s -o /dev/null http://localhost:11434/api/generate \
    -d "{\"model\":\"$MODEL\",\"prompt\":\"warmup\",\"stream\":false}"

  echo "--- scrape ---"
  "$SCRAPE" --pace gentle
  scrape_rc=$?
  if [ "$scrape_rc" -ne 0 ]; then
    # Don't annotate against a half-scraped or stale store on scrape failure —
    # fail loudly so a log check (or launchd) sees the non-zero exit.
    echo "✗ scrape failed (exit $scrape_rc) — skipping annotate."
    exit 1
  fi

  echo "--- coverage annotate ---"
  # --pace gentle (2s between posts) + a smaller backfill keep the run short and
  # the GPU cool: it finishes in fewer hours and idles the rest of the day. The
  # CLI also self-throttles via ProcessInfo.thermalState back-off.
  "$ANNOTATE" --coverage --backfill 2500 --pass llm --model "$MODEL" --pace gentle
  annotate_rc=$?
  if [ "$annotate_rc" -ne 0 ]; then
    echo "✗ coverage annotate failed (exit $annotate_rc)."
    exit 1
  fi

  echo "=== done $(date) ==="
} >> "$LOG" 2>&1
