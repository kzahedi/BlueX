#!/bin/zsh
# Scrape job (runs daily ~18:00). Shares a store-lock with the annotate job so
# the two never write the SwiftData store concurrently (Core Data is not safe
# for multi-process writes).
set -u

LOG_DIR="$HOME/Library/Logs/BlueX"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/scrape_$(date "+%Y-%m-%d_%H%M%S").log"
LOCK="$LOG_DIR/bluex-store.lock"

SCRAPE="$HOME/.local/bin/blueX-scrape"

# Reclaim a stale lock left by a crashed/killed/slept run (older than 18h).
if [ -d "$LOCK" ] && [ -n "$(find "$LOCK" -maxdepth 0 -mmin +1080 2>/dev/null)" ]; then
  echo "$(date): reclaiming stale store-lock." >> "$LOG"
  rmdir "$LOCK" 2>/dev/null
fi

# Acquire the shared store-lock (atomic mkdir). Skip if scrape/annotate is active.
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "$(date): store busy ($LOCK) — scrape skipped." >> "$LOG"
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

{
  echo "=== scrape $(date) ==="
  "$SCRAPE" --pace gentle
  scrape_rc=$?
  if [ "$scrape_rc" -ne 0 ]; then
    echo "✗ scrape failed (exit $scrape_rc)."
  fi
  echo "=== done $(date) ==="
} >> "$LOG" 2>&1
