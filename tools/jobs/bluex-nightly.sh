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
# 07:00 is before the working day and only a few minutes after the 06:55 wake.
#
# Note the ordering against the watchdog, which runs at 06:56 — BEFORE this
# deadline. A run that goes the distance is therefore still in flight when the
# watchdog looks, so its heartbeat is from the previous night and is not judged
# until the following morning. That is fine: an immediate failure is notified
# directly by this script, so the watchdog is the backstop, not the first line.
#
# Overridable purely so the regression tests in test_jobs.py can put the deadline a
# few seconds away instead of sleeping until 07:00. Unset in production (launchd
# passes no environment), so the effective value there is still exactly 07:00.
DEADLINE_TIME="${DEADLINE_TIME:-07:00}"

# Budget reserved for the sentiment pass out of the run's total. Without it the
# scrape eats the whole night on a multi-day backfill and NLTagger annotation never
# runs at all — for weeks, with both exit codes 0 and a store mtime that stays
# fresh.
#
# What the reserve guarantees is a START slot, NOT a bounded finish. The deadline
# SIGINT is a no-op for the annotation step: blueX-annotate runs NLTaggerPass.run()
# synchronously on the main actor, while installSIGINTHandler's DispatchSource sits
# on queue .main, so the main queue cannot drain while the pass is executing and
# the pass's once-per-page isCancelled() poll never observes the flag. (Ctrl-C
# cannot interrupt a long nltagger pass either, for the same reason.) A large
# backlog can therefore overrun DEADLINE_TIME into working hours.
#
# That is tolerated only because NLTagger is microseconds per post, so the overrun
# is small in practice. It is a reason, not a guarantee.
#
# Overridable for the same reason as DEADLINE_TIME: it is the only knob that lets a
# test give the scrape a budget of a few seconds. Unset in production, so 20 minutes.
SENTIMENT_RESERVE_SECONDS="${SENTIMENT_RESERVE_SECONDS:-$(( 20 * 60 ))}"

# Poll interval of the deadline timer in run_bounded. It bounds two things: how long
# after the deadline the SIGINT is delivered, and how long the run lingers after a
# child exits early (the timer notices on its next poll). Overridable only so the
# regression tests do not pay 5s per step; unset in production, so 5 seconds.
TIMER_POLL_SECONDS="${TIMER_POLL_SECONDS:-5}"

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
DEADLINE_FLAG="$BLUEX_LOG_DIR/.deadline-fired.$$"

# zsh does not run an EXIT trap on a signal death, so trapping EXIT alone left the
# lock and the flag file behind on `launchctl bootout` or a plain kill. A leftover
# lock makes the NEXT night's run skip silently until the 18h reclaim window passes
# — the exact pattern this branch exists to remove.
#
# Every step is idempotent (kill on a dead pid, rm -f, rmdir on a missing dir all
# fail harmlessly), which matters because a signal trap that exits also re-triggers
# the EXIT trap, so this runs twice on a signal death. The explicit 128+signo exits
# keep the status meaningful instead of falling through and continuing the run.
bluex_cleanup() {
  kill "$CAFFEINATE_PID" 2>/dev/null
  rm -f "$DEADLINE_FLAG"
  rmdir "$BLUEX_LOCK" 2>/dev/null
  return 0
}
trap bluex_cleanup EXIT
trap 'bluex_cleanup; exit 130' INT
trap 'bluex_cleanup; exit 143' TERM
trap 'bluex_cleanup; exit 129' HUP

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
RUN_BOUNDED_SKIPPED=0

# Run a CLI with a wall-clock stop of its own ($1 = absolute epoch, 0 = unbounded).
# At the stop the child gets SIGINT, never SIGKILL: installSIGINTHandler in both
# CLIs stops at the next post/page boundary and everything already done is
# persisted, whereas a KILL would drop in-flight work. The signal goes to the
# CHILD's pid — not to this script and not to the process group — so the heartbeat
# write below always stays reachable.
#
# Returns the child's exit status. Sets STOPPED_AT_DEADLINE if the stop fired, and
# RUN_BOUNDED_SKIPPED if there was no budget left to even start the child.
run_bounded() {
  local stop_at="$1"; shift
  RUN_BOUNDED_SKIPPED=0

  local budget=0
  if [ "$stop_at" -gt 0 ]; then
    budget=$(( stop_at - $(date +%s) ))
    if [ "$budget" -le 0 ]; then
      STOPPED_AT_DEADLINE=1
      RUN_BOUNDED_SKIPPED=1
      echo "⏰ no budget left before ${DEADLINE_TIME} — skipping: $*"
      return 0
    fi
  fi

  rm -f "$DEADLINE_FLAG"

  "$@" &
  local child=$!
  local timer=0
  if [ "$budget" -gt 0 ]; then
    # Polls instead of a single long `sleep` so the timer notices the child
    # finishing and exits on its own. A `sleep $budget` had to be killed by the
    # parent, which orphaned the sleep itself (two per run, up to ~3.5 h), and
    # killing the sleep instead would let the subshell fall through to the
    # kill -INT and interrupt a child that had already finished cleanly.
    #
    # The flag file is touched only if the INT was actually delivered. A "is the
    # timer still alive?" check cannot substitute: an exited-but-unreaped timer is
    # a zombie and still answers `kill -0`.
    (
      while [ "$(date +%s)" -lt "$stop_at" ]; do
        kill -0 "$child" 2>/dev/null || exit 0
        sleep "$TIMER_POLL_SECONDS"
      done
      kill -INT "$child" 2>/dev/null && : >"$DEADLINE_FLAG"
    ) &
    timer=$!
  fi

  wait "$child"
  local rc=$?

  # No kill needed: with the child reaped, the timer's next poll fails kill -0 and
  # it exits within one poll interval. wait reaps it.
  [ "$timer" -ne 0 ] && wait "$timer" 2>/dev/null

  if [ -f "$DEADLINE_FLAG" ]; then
    STOPPED_AT_DEADLINE=1
    echo "⏰ stopped at the ${DEADLINE_TIME} deadline — work up to the last post/page boundary is saved."
  fi
  rm -f "$DEADLINE_FLAG"
  return $rc
}

scrape_rc=0
annotate_rc=0
SENTIMENT_SKIPPED=0

# The scrape stops early enough to leave the sentiment pass its reserved slice.
SCRAPE_DEADLINE=$DEADLINE_EPOCH
if [ "$DEADLINE_EPOCH" -gt 0 ]; then
  SCRAPE_DEADLINE=$(( DEADLINE_EPOCH - SENTIMENT_RESERVE_SECONDS ))
fi

# A brace group, not a subshell — the exit codes below must survive into the
# heartbeat written afterwards.
{
  echo "=== nightly $(date) ==="
  if [ "$DEADLINE_EPOCH" -gt 0 ]; then
    echo "deadline: $(date -r "$DEADLINE_EPOCH")  (scrape stops $(date -r "$SCRAPE_DEADLINE"))"
  else
    echo "deadline: none"
  fi
  echo "--- scrape (gentle, max-window-days $MAX_WINDOW_DAYS) ---"
  run_bounded "$SCRAPE_DEADLINE" "$SCRAPE" --pace gentle --max-window-days "$MAX_WINDOW_DAYS"
  scrape_rc=$?
  [ "$scrape_rc" -ne 0 ] && echo "✗ scrape failed (exit $scrape_rc)."

  echo "--- Apple NLTagger sentiment ---"
  run_bounded "$DEADLINE_EPOCH" "$ANNOTATE" --pass nltagger
  annotate_rc=$?
  SENTIMENT_SKIPPED=$RUN_BOUNDED_SKIPPED
  [ "$annotate_rc" -ne 0 ] && echo "✗ sentiment failed (exit $annotate_rc)."
  [ "$SENTIMENT_SKIPPED" -eq 1 ] && echo "⚠ sentiment did not run at all this night — no budget left."

  echo "=== done $(date) (stoppedAtDeadline=$STOPPED_AT_DEADLINE sentimentSkipped=$SENTIMENT_SKIPPED) ==="
} >>"$LOG" 2>&1

# Heartbeat. Lets the watchdog tell "ran but found nothing new" from "never ran".
#
# stoppedAtDeadline records that the run was cut short, and sentimentSkipped that
# annotation never got to run. NEITHER excuses a nonzero exit: a deadline SIGINT by
# itself always yields exit 0 (the scrape breaks on cancel without flagging a
# failure; the nltagger pass returns normally), so a nonzero exit always means a
# genuine failure. These two flags may only qualify the "ran short" reading —
# never suppress a failure. An earlier version of this script suppressed the
# failure notification on any deadline night, which hid every failure for the whole
# length of a multi-day backfill: precisely the silent-failure class this branch
# exists to remove.
deadline_json=false
[ "$STOPPED_AT_DEADLINE" -eq 1 ] && deadline_json=true
sentiment_skipped_json=false
[ "$SENTIMENT_SKIPPED" -eq 1 ] && sentiment_skipped_json=true
cat >"$BLUEX_HEARTBEAT" <<JSON
{
  "finishedAt": "$(date -u "+%Y-%m-%dT%H:%M:%SZ")",
  "scrapeExit": $scrape_rc,
  "sentimentExit": $annotate_rc,
  "stoppedAtDeadline": $deadline_json,
  "sentimentSkipped": $sentiment_skipped_json,
  "log": "$LOG"
}
JSON

if [ "$scrape_rc" -ne 0 ] || [ "$annotate_rc" -ne 0 ]; then
  suffix=""
  [ "$STOPPED_AT_DEADLINE" -eq 1 ] && suffix=" (also hit the $DEADLINE_TIME deadline)"
  echo "$(date): FAILED — scrape=$scrape_rc sentiment=$annotate_rc$suffix" >>"$LOG"
  bluex_notify "BlueX nightly failed" "scrape=$scrape_rc sentiment=$annotate_rc$suffix — see $LOG"
  exit 1
fi

if [ "$SENTIMENT_SKIPPED" -eq 1 ]; then
  echo "$(date): both steps ok, but sentiment never ran (no budget before $DEADLINE_TIME)." >>"$LOG"
elif [ "$STOPPED_AT_DEADLINE" -eq 1 ]; then
  echo "$(date): stopped at the $DEADLINE_TIME deadline, both steps exited 0 — ran short, not failed." >>"$LOG"
fi
exit 0
