#!/bin/zsh
# tools/jobs/bluex-nightly.sh — the BlueX nightly run. User LaunchAgent, 03:31.
#
# Fires on a plain StartCalendarInterval at 03:31 — the mini currently has
# `pmset sleep 0` (never idle-sleeps), so no wake mechanism is needed and there
# is no privileged component in this design. Still holds a caffeinate power
# assertion for the whole run as insurance: `sleep` was flipped from 1 to 0
# once already today, and if it's ever re-enabled a long scrape must not be
# cut short by an idle-sleep mid-run.
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

# Wall-clock stop. The spec's constraints say no scraping or annotation during
# working hours, and nothing else bounds the run: a 03:31 start on a large backfill
# would otherwise still be scraping at noon, holding caffeinate through the day.
# 07:00 sits before the 06:55 wake window closes and before the working day.
DEADLINE_TIME="07:00"

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
  # The credential path is the one thing that cannot be checked any other way
  # before 03:30, and it is fragile: the CLIs are ad-hoc signed, so a rebuild can
  # invalidate the Keychain ACL and an ACL prompt at 03:31 has nobody to answer it.
  #
  # This used to call --list-accounts and claim a zero exit proved the unattended
  # path worked. It did not: that mode returns before KeychainCredentials.load() is
  # ever reached, so the Keychain was never touched. --check-credentials does the
  # real thing (Keychain read + live createSession) and deliberately does NOT open
  # the store, which also keeps preflight off the store entirely — the lock below
  # is what serialises store access.
  if [ -x "$SCRAPE" ] && ! "$SCRAPE" --check-credentials >/dev/null 2>&1; then
    echo "✗ blueX-scrape --check-credentials failed — Keychain ACL or app password?"
    echo "  fix: run '$SCRAPE --check-credentials' interactively to see why"
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

# Reclaim a lock left behind by a crashed, killed or slept run (older than 18h —
# longer than any expected run). Bounds the damage of a never-released lock.
if [ -d "$BLUEX_LOCK" ] && [ -n "$(find "$BLUEX_LOCK" -maxdepth 0 -mmin +1080 2>/dev/null)" ]; then
  echo "$(date): reclaiming stale store-lock." >>"$LOG"
  rmdir "$BLUEX_LOCK" 2>/dev/null
fi

# Atomic mkdir lock, taken BEFORE preflight so nothing this script runs can touch
# the store outside it.
#
# What this lock actually covers: nightly-vs-nightly only. BlueX.app and an
# interactive CLI invocation do not take it, so it does NOT make store access
# mutually exclusive in general — it only stops a second nightly run (a launchd
# replay, or a manual invocation) from overlapping one already in flight. Avoiding
# concurrent CoreData writers against the GUI is still a matter of not launching
# the app during a run.
if ! mkdir "$BLUEX_LOCK" 2>/dev/null; then
  echo "$(date): store busy ($BLUEX_LOCK) — nightly skipped." >>"$LOG"
  exit 0
fi

caffeinate -i -s -w $$ &
CAFFEINATE_PID=$!
trap 'kill "$CAFFEINATE_PID" 2>/dev/null; rmdir "$BLUEX_LOCK" 2>/dev/null' EXIT

if ! preflight >>"$LOG" 2>&1; then
  bluex_notify "BlueX nightly" "Preflight failed — see $LOG"
  exit 78
fi

# ---- deadline ---------------------------------------------------------------
# Absolute epoch of today's DEADLINE_TIME; if that is already past (a manual or
# replayed run late in the day), the deadline is the same time tomorrow.
DEADLINE_EPOCH=$(date -j -f "%Y-%m-%d %H:%M" "$(date "+%Y-%m-%d") $DEADLINE_TIME" "+%s" 2>/dev/null)
if [ -z "$DEADLINE_EPOCH" ]; then
  echo "$(date): could not compute deadline from '$DEADLINE_TIME' — running unbounded." >>"$LOG"
  DEADLINE_EPOCH=0
elif [ "$DEADLINE_EPOCH" -le "$(date +%s)" ]; then
  DEADLINE_EPOCH=$(( DEADLINE_EPOCH + 86400 ))
fi

STOPPED_AT_DEADLINE=0

# Run a CLI with a wall-clock budget. At the deadline the child gets SIGINT, never
# SIGKILL: installSIGINTHandler in both CLIs stops at the next post/page boundary
# and everything already scraped is persisted, whereas a KILL would drop in-flight
# work. Returns the child's exit status; sets STOPPED_AT_DEADLINE if the timer
# fired.
run_bounded() {
  local budget=0
  if [ "$DEADLINE_EPOCH" -gt 0 ]; then
    budget=$(( DEADLINE_EPOCH - $(date +%s) ))
    if [ "$budget" -le 0 ]; then
      STOPPED_AT_DEADLINE=1
      echo "⏰ ${DEADLINE_TIME} deadline reached — skipping: $*"
      return 0
    fi
  fi

  local fired="$BLUEX_LOG_DIR/.deadline-fired.$$"
  rm -f "$fired"

  "$@" &
  local child=$!
  local timer=0
  if [ "$budget" -gt 0 ]; then
    # Touch the flag only if the INT was actually delivered — a child that finished
    # first makes the kill fail and leaves no flag. A "is the timer still alive?"
    # check cannot be used instead: an exited-but-unreaped timer is a zombie and
    # still answers `kill -0`.
    ( sleep "$budget"; kill -INT "$child" 2>/dev/null && : >"$fired" ) &
    timer=$!
  fi

  wait "$child"
  local rc=$?

  if [ "$timer" -ne 0 ]; then
    kill "$timer" 2>/dev/null
    wait "$timer" 2>/dev/null
  fi

  if [ -f "$fired" ]; then
    STOPPED_AT_DEADLINE=1
    echo "⏰ stopped at the ${DEADLINE_TIME} deadline — NOT a failure; work up to the last post boundary is saved."
  fi
  rm -f "$fired"
  return $rc
}

scrape_rc=0
annotate_rc=0

# A brace group, not a subshell — the exit codes below must survive into the
# heartbeat written afterwards.
{
  echo "=== nightly $(date) ==="
  if [ "$DEADLINE_EPOCH" -gt 0 ]; then
    echo "deadline: $(date -r "$DEADLINE_EPOCH")"
  else
    echo "deadline: none"
  fi
  echo "--- scrape (gentle, max-window-days $MAX_WINDOW_DAYS) ---"
  run_bounded "$SCRAPE" --pace gentle --max-window-days "$MAX_WINDOW_DAYS"
  scrape_rc=$?
  [ "$scrape_rc" -ne 0 ] && echo "✗ scrape failed (exit $scrape_rc)."

  echo "--- Apple NLTagger sentiment ---"
  run_bounded "$ANNOTATE" --pass nltagger
  annotate_rc=$?
  [ "$annotate_rc" -ne 0 ] && echo "✗ sentiment failed (exit $annotate_rc)."

  echo "=== done $(date) (stoppedAtDeadline=$STOPPED_AT_DEADLINE) ==="
} >>"$LOG" 2>&1

# Heartbeat. Lets the watchdog tell "ran but found nothing new" from "never ran",
# and — via the exit codes plus stoppedAtDeadline — a failing run from a run that
# simply ran out of night. A multi-day initial scrape legitimately hits the
# deadline every night, so that case must not be read as a failure.
deadline_json=false
[ "$STOPPED_AT_DEADLINE" -eq 1 ] && deadline_json=true
cat >"$BLUEX_HEARTBEAT" <<JSON
{
  "finishedAt": "$(date -u "+%Y-%m-%dT%H:%M:%SZ")",
  "scrapeExit": $scrape_rc,
  "sentimentExit": $annotate_rc,
  "stoppedAtDeadline": $deadline_json,
  "log": "$LOG"
}
JSON

if [ "$STOPPED_AT_DEADLINE" -eq 1 ]; then
  echo "$(date): stopped at the $DEADLINE_TIME deadline (scrape=$scrape_rc sentiment=$annotate_rc) — no alert." >>"$LOG"
  exit 0
fi

if [ "$scrape_rc" -ne 0 ] || [ "$annotate_rc" -ne 0 ]; then
  bluex_notify "BlueX nightly failed" "scrape=$scrape_rc sentiment=$annotate_rc — see $LOG"
  exit 1
fi
exit 0
