#!/bin/zsh
# tools/jobs/bluex-nightly.sh — the BlueX nightly run. User LaunchAgent, 03:31.
#
# Fires on a one-shot pmset wake armed at 07:00 the previous morning by the root
# arm-wake daemon. Holds a power assertion for the whole run: with `pmset sleep 1`
# the mini sleeps one minute after going idle, which would cut the run short.
#
# Runs as a user agent (not root) because the scrape reads Bluesky credentials
# from the user Keychain and alerting uses osascript.
set -u

JOBS_DIR="${0:A:h}"
source "$JOBS_DIR/lib-bluex-job.sh"

SCRAPE="$BLUEX_BIN/blueX-scrape"
ANNOTATE="$BLUEX_BIN/blueX-annotate"
# Reply-tree refresh window. A post's tree freezes once the previous scrape falls
# outside this window of the post's createdAt.
MAX_WINDOW_DAYS=7

preflight() {
  local problems=0
  local bin
  for bin in "$SCRAPE" "$ANNOTATE"; do
    if [ ! -x "$bin" ]; then
      echo "✗ missing or not executable: $bin"
      echo "  fix: run tools/install-jobs.sh from the repo"
      problems=1
    fi
  done
  if ! bluex_wait_for_store 0; then
    echo "✗ store volume not mounted: ${BLUEX_STORE_DIR:h}"
    echo "  fix: attach the Eregion drive"
    problems=1
  fi
  if [ ! -e "$BLUEX_STORE" ]; then
    echo "✗ store not found: $BLUEX_STORE"
    problems=1
  fi
  # --list-accounts opens the store and reads Keychain credentials, so a zero exit
  # proves the unattended path works. This is the one thing that cannot be checked
  # any other way before 03:30.
  if [ -x "$SCRAPE" ] && ! "$SCRAPE" --list-accounts >/dev/null 2>&1; then
    echo "✗ blueX-scrape --list-accounts failed — Keychain credentials or store?"
    problems=1
  fi
  [ "$problems" -eq 0 ] && echo "✓ preflight ok"
  return $problems
}

if [ "${1:-}" = "--preflight" ]; then
  preflight
  exit $?
fi

LOG="$(bluex_log_path nightly)"

# The store lives on an external volume, so wait for the mount before anything else.
# Bounded: a launchd job that hangs forever is worse than one that reports and exits.
if ! bluex_wait_for_store 180; then
  echo "$(date): store volume ${BLUEX_STORE_DIR:h} not mounted after 180s — skipped." >>"$LOG"
  bluex_notify "BlueX nightly skipped" "Eregion not mounted after 180s — see $LOG"
  exit 75
fi

if ! preflight >>"$LOG" 2>&1; then
  bluex_notify "BlueX nightly" "Preflight failed — see $LOG"
  exit 78
fi

# Reclaim a lock left behind by a crashed, killed or slept run (older than 18h —
# longer than any expected run). Bounds the damage of a never-released lock.
if [ -d "$BLUEX_LOCK" ] && [ -n "$(find "$BLUEX_LOCK" -maxdepth 0 -mmin +1080 2>/dev/null)" ]; then
  echo "$(date): reclaiming stale store-lock." >>"$LOG"
  rmdir "$BLUEX_LOCK" 2>/dev/null
fi

# Atomic mkdir lock — CoreData is not safe for concurrent multi-process writes.
if ! mkdir "$BLUEX_LOCK" 2>/dev/null; then
  echo "$(date): store busy ($BLUEX_LOCK) — nightly skipped." >>"$LOG"
  exit 0
fi

caffeinate -i -s -w $$ &
CAFFEINATE_PID=$!
trap 'kill "$CAFFEINATE_PID" 2>/dev/null; rmdir "$BLUEX_LOCK" 2>/dev/null' EXIT

scrape_rc=0
annotate_rc=0

# A brace group, not a subshell — the exit codes below must survive into the
# heartbeat written afterwards.
{
  echo "=== nightly $(date) ==="
  echo "--- scrape (gentle, max-window-days $MAX_WINDOW_DAYS) ---"
  "$SCRAPE" --pace gentle --max-window-days "$MAX_WINDOW_DAYS"
  scrape_rc=$?
  [ "$scrape_rc" -ne 0 ] && echo "✗ scrape failed (exit $scrape_rc)."

  echo "--- Apple NLTagger sentiment ---"
  "$ANNOTATE" --pass nltagger
  annotate_rc=$?
  [ "$annotate_rc" -ne 0 ] && echo "✗ sentiment failed (exit $annotate_rc)."

  echo "=== done $(date) ==="
} >>"$LOG" 2>&1

# Heartbeat. Lets the watchdog tell "ran but found nothing new" from "never ran".
cat >"$BLUEX_HEARTBEAT" <<JSON
{
  "finishedAt": "$(date -u "+%Y-%m-%dT%H:%M:%SZ")",
  "scrapeExit": $scrape_rc,
  "sentimentExit": $annotate_rc,
  "log": "$LOG"
}
JSON

if [ "$scrape_rc" -ne 0 ] || [ "$annotate_rc" -ne 0 ]; then
  bluex_notify "BlueX nightly failed" "scrape=$scrape_rc sentiment=$annotate_rc — see $LOG"
  exit 1
fi
exit 0
