#!/bin/zsh
# tools/jobs/bluex-continuous.sh — the BlueX continuous scraper. User LaunchAgent,
# KeepAlive + RunAtLoad. Replaces the 03:31 nightly agent: the requirement is
# "make sure the scraper is always running", not "run it once a night".
#
# No sentiment/annotate stage here on purpose. Apple NLTagger sentiment was measured
# useless for hate detection (fine-tune diagnostic: hate vs rude, AUC 0.508 — barely
# above chance) so this agent scrapes only; annotation is a separate, deliberate
# migration, not something to keep dragging along into every job that touches the
# store.
#
# ---- the launchd TCC blocker (measured 2026-08-04, reproduced today) --------
# launchd-spawned zsh gets EPERM writing to /Volumes/Eregion until the user grants
# Full Disk Access to /bin/zsh in System Settings. Five consecutive nightly runs
# failed with exit 78, and a kickstart reproduction today confirmed it again. Until
# the grant lands, EVERY launchd invocation of this script hits the same wall.
#
# The wrong response is to let that surface as a script exit: launchd's KeepAlive
# restarts an exited job immediately, and a script that exits every time it is
# invoked becomes a tight crash loop (spinning CPU, spamming logs, and — depending
# on launchd's own throttling — eventually getting itself backed off or disabled).
# So permission-denied/unavailable-store is treated here as a NORMAL, expected retry
# state: probe cheaply, log ONE line, sleep, and re-probe — forever, inside the
# process, never via exit. The moment the grant lands, the very next probe succeeds
# and the agent starts scraping with no reinstall and no launchctl call.
set -u

JOBS_DIR="${0:A:h}"
source "$JOBS_DIR/lib-bluex-job.sh"

SCRAPE="$BLUEX_BIN/blueX-scrape"

# Single-instance lock for the scrape invocation itself — a DIFFERENT problem than
# $BLUEX_LOCK above (that mkdir lock only ever coordinates this loop against
# bluex-nightly.sh's own pass-taking; it says nothing about a manually launched
# blueX-scrape, or any other invocation, racing this agent directly). Measured
# incident: two blueX-scrape processes ran against the same SwiftData store for
# about a minute — doubled Bluesky request rate, store write-lock contention,
# duplicated work, and nothing noticed.
#
# Deliberately NOT a PID file, for the same reason tools/common/single_instance.py
# gives for the Telegram collector: a PID file left behind by a SIGKILL is
# indistinguishable from a live holder without extra liveness checks, which is
# exactly the race this has to avoid. flock ties the lock to the kernel's
# open-file-description table instead, so it releases automatically on ANY exit of
# the holder (clean, crashed, or SIGKILLed) and a stale lock *file* on disk never
# blocks a fresh acquisition.
#
# macOS has no flock(1), so this is a small inline python3 helper — python3 is
# already a hard dependency of this script family (see the interruptible-CLI test
# stub). It acquires an exclusive, non-blocking flock and then execs the scraper
# IN THE SAME PROCESS while holding the descriptor, so the kernel keeps holding the
# lock for the scraper's entire lifetime with no separate watcher process needed to
# release it. `os.open` marks its descriptors close-on-exec by default (PEP 446);
# `os.set_inheritable` undoes that specifically so exec does not silently release
# the lock the instant the scraper starts. Exit 3 on a lock miss (never runs the
# scraper) mirrors the Telegram collector's own single-instance stand-down code.
SCRAPE_LOCK="$BLUEX_STORE_DIR/.bluex-scrape.lock"
# BEGIN bluex-scrape-lock.py — tools/jobs/test_jobs.py extracts this verbatim to
# unit-test the locking primitive directly; keep the markers and heredoc intact.
SCRAPE_LOCK_PY=$(cat <<'PYEOF'
import fcntl, os, sys

lock_path = sys.argv[1]
args = sys.argv[2:]
fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o644)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    sys.exit(3)
os.set_inheritable(fd, True)
os.execvp(args[0], args)
PYEOF
)
# END bluex-scrape-lock.py

# Inter-pass sleep after a pass completes (success OR failure) — one bad pass must
# not spin the loop hot, and it must not shorten the interval either. 20 minutes in
# production; overridable so the tests do not sleep for real.
CONTINUOUS_INTERVAL_SECONDS="${CONTINUOUS_INTERVAL_SECONDS:-$(( 20 * 60 ))}"

# Sleep while the store is unwritable (unmounted OR the EPERM state above). Shorter
# than the pass interval on purpose — this is the retry state that must notice the
# Full Disk Access grant landing promptly, not the working state, so it re-probes
# sooner. 15 minutes in production; overridable for tests.
PERMISSION_RETRY_SECONDS="${PERMISSION_RETRY_SECONDS:-$(( 15 * 60 ))}"

# The loop's own supervisory log. Internal disk, always writable, same reasoning as
# every other control-plane path in lib-bluex-job.sh: it has to work precisely when
# the store volume is the thing that is unavailable.
SUP_LOG="$BLUEX_LOG_DIR/continuous.log"

RUNNING=1
SLEEP_PID=0
CHILD_PID=0

# Signal handling: mark the loop to stop AND wake it up immediately, whether it is
# currently sleeping between passes or running a scrape. The child gets SIGINT, not
# SIGKILL — installSIGINTHandler in blueX-scrape stops at the next post/page
# boundary with everything already done persisted, mirroring bluex-nightly.sh's
# run_bounded. zsh does not run an EXIT trap on a signal death, so INT/TERM/HUP are
# all trapped explicitly, same reasoning as the nightly script.
bluex_continuous_stop() {
  RUNNING=0
  [ "$SLEEP_PID" -ne 0 ] && kill "$SLEEP_PID" 2>/dev/null
  [ "$CHILD_PID" -ne 0 ] && kill -INT "$CHILD_PID" 2>/dev/null
}
trap bluex_continuous_stop INT TERM HUP

# Interruptible sleep: a plain `sleep N` cannot be woken by a trap mid-sleep in zsh,
# so it runs backgrounded and the trap kills it directly (same pattern run_bounded
# uses in bluex-nightly.sh for its deadline timer).
bluex_sleep_interruptible() {
  local secs="$1"
  [ "$secs" -le 0 ] && return 0
  sleep "$secs" &
  SLEEP_PID=$!
  wait "$SLEEP_PID" 2>/dev/null
  SLEEP_PID=0
}

# Cheap write probe for the EPERM state. Distinct from bluex_wait_for_store /
# bluex_store_volume_ready: those only check that the volume's PARENT directory
# exists — true even when launchd-spawned zsh is denied write access by TCC. The
# only way to detect that reliably is to actually attempt a write, so this creates
# and removes a tiny marker file in the store's logs directory (the same directory
# per-pass logs land in) and reports whether that succeeded.
bluex_probe_store_writable() {
  bluex_store_volume_ready || return 1
  local probe="$BLUEX_RUN_LOG_DIR/.write-probe.$$"
  mkdir -p "$BLUEX_RUN_LOG_DIR" 2>/dev/null || return 1
  : >"$probe" 2>/dev/null || return 1
  rm -f "$probe" 2>/dev/null
  return 0
}

# Heartbeat. "mode" distinguishes this agent's heartbeat from the retired nightly
# one at a glance; "permissionBlocked" is what lets the watchdog tell the TCC-EPERM
# state apart from a generic stale/failed reading. scrapeExit is the last PASS's
# exit code — 0 while permission-blocked, since no pass has even attempted to run.
# "skipped" (4th, optional arg) mirrors the Telegram job's own heartbeat
# convention: an optional string key, present only when this tick stood down
# instead of doing real work, so the watchdog can tell "ran cleanly" apart from
# "correctly declined to run" without a new heartbeat shape for every reason.
bluex_continuous_write_heartbeat() {
  local scrape_rc="$1" blocked="$2" log="$3" skipped="${4:-}"
  local skipped_line=""
  [ -n "$skipped" ] && skipped_line="  \"skipped\": \"$skipped\","
  cat >"$BLUEX_HEARTBEAT" <<JSON
{
  "finishedAt": "$(date -u "+%Y-%m-%dT%H:%M:%SZ")",
  "mode": "continuous",
  "scrapeExit": $scrape_rc,
$skipped_line
  "stoppedAtDeadline": false,
  "sentimentSkipped": true,
  "permissionBlocked": $blocked,
  "log": "$log"
}
JSON
}

echo "$(date): continuous agent starting (pid $$)." >>"$SUP_LOG"

while [ "$RUNNING" -eq 1 ]; do
  if ! bluex_probe_store_writable; then
    echo "$(date): store unwritable (unmounted, or EPERM pending Full Disk Access for /bin/zsh) — retrying in ${PERMISSION_RETRY_SECONDS}s." >>"$SUP_LOG"
    bluex_continuous_write_heartbeat 0 true "$SUP_LOG"
    bluex_sleep_interruptible "$PERMISSION_RETRY_SECONDS"
    continue
  fi

  # Reclaim a lock left behind by a crashed/killed pass — same 18h bound as
  # bluex-nightly.sh, longer than any expected pass.
  if [ -d "$BLUEX_LOCK" ] && [ -n "$(find "$BLUEX_LOCK" -maxdepth 0 -mmin +1080 2>/dev/null)" ]; then
    echo "$(date): reclaiming stale store-lock." >>"$SUP_LOG"
    rmdir "$BLUEX_LOCK" 2>/dev/null
  fi

  # Same atomic mkdir lock as bluex-nightly.sh, so a manual catch-up scrape (or a
  # replayed/overlapping invocation of this very agent) is never overlapped —
  # just skipped for this pass, not treated as a failure.
  if ! mkdir "$BLUEX_LOCK" 2>/dev/null; then
    echo "$(date): store busy ($BLUEX_LOCK) — pass skipped." >>"$SUP_LOG"
    bluex_sleep_interruptible "$CONTINUOUS_INTERVAL_SECONDS"
    continue
  fi

  LOG="$(bluex_log_path continuous)"
  echo "=== continuous pass $(date) ===" >>"$LOG"
  python3 -c "$SCRAPE_LOCK_PY" "$SCRAPE_LOCK" "$SCRAPE" --pace steady >>"$LOG" 2>&1 &
  CHILD_PID=$!
  wait "$CHILD_PID"
  scrape_rc=$?
  CHILD_PID=0
  echo "=== pass done $(date) (exit $scrape_rc) ===" >>"$LOG"

  rmdir "$BLUEX_LOCK" 2>/dev/null

  # exit 3 from the python3 helper above means the flock was already held --
  # i.e. another blueX-scrape (this agent's own overlapping tick, a manual
  # catch-up run, or anything else observing the same lock convention) is live
  # right now. That is correct, expected behaviour, not a failure: log the
  # stand-down, mark the heartbeat "skipped": "locked" so the watchdog can
  # report it without alarming, and move straight to the next tick without
  # ever having invoked the scraper.
  if [ "$scrape_rc" -eq 3 ]; then
    echo "$(date): scrape already running ($SCRAPE_LOCK) — pass skipped." >>"$SUP_LOG"
    bluex_continuous_write_heartbeat 0 false "$SUP_LOG" locked
    bluex_sleep_interruptible "$CONTINUOUS_INTERVAL_SECONDS"
    continue
  fi

  if [ "$scrape_rc" -ne 0 ]; then
    echo "$(date): pass FAILED (exit $scrape_rc) — see $LOG" >>"$SUP_LOG"
  else
    echo "$(date): pass ok — see $LOG" >>"$SUP_LOG"
  fi

  # A bad pass is logged and heartbeat-recorded, then the loop simply continues —
  # one bad pass must never kill the agent. Only a signal (handled via the trap
  # above) stops it.
  bluex_continuous_write_heartbeat "$scrape_rc" false "$LOG"

  bluex_sleep_interruptible "$CONTINUOUS_INTERVAL_SECONDS"
done

echo "$(date): continuous agent stopping (signal received)." >>"$SUP_LOG"
exit 0
