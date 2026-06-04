#!/bin/zsh
# Coverage-annotate job (runs daily ~07:00, rides the 6:55 wakepoweron).
# Shares a store-lock with the scrape job so the two never write the SwiftData
# store concurrently (Core Data is not safe for multi-process writes).
set -u

LOG_DIR="$HOME/Library/Logs/BlueX"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/annotate_$(date "+%Y-%m-%d_%H%M%S").log"
LOCK="$LOG_DIR/bluex-store.lock"

ANNOTATE="$HOME/.local/bin/blueX-annotate"
MODEL="phi4:14b"

# Reclaim a stale lock left by a crashed/killed/slept run (older than 18h —
# longer than any expected job). Bounds the damage of a never-released lock.
if [ -d "$LOCK" ] && [ -n "$(find "$LOCK" -maxdepth 0 -mmin +1080 2>/dev/null)" ]; then
  echo "$(date): reclaiming stale store-lock." >> "$LOG"
  rmdir "$LOCK" 2>/dev/null
fi

# Acquire the shared store-lock (atomic mkdir). Skip if scrape/annotate is active.
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "$(date): store busy ($LOCK) — annotate skipped." >> "$LOG"
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

{
  echo "=== annotate $(date) ==="

  echo "warming $MODEL…"
  curl -s -o /dev/null http://localhost:11434/api/generate \
    -d "{\"model\":\"$MODEL\",\"prompt\":\"warmup\",\"stream\":false}"

  echo "--- coverage annotate (backfill 1500, gentle) ---"
  "$ANNOTATE" --coverage --backfill 1500 --pass llm --model "$MODEL" --pace gentle
  annotate_rc=$?
  if [ "$annotate_rc" -ne 0 ]; then
    echo "✗ coverage annotate failed (exit $annotate_rc)."
  fi

  echo "=== done $(date) ==="
} >> "$LOG" 2>&1
