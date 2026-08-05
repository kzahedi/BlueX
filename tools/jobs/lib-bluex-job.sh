# tools/jobs/lib-bluex-job.sh — shared helpers for the BlueX launchd jobs.
# Sourced, never executed.
#
# These scripts are installed to the internal disk on purpose. launchd fires them
# during DarkWake, when /Volumes/Eregion is not mounted — that is what caused the
# 61-day outage beginning 2026-06-04. Nothing here may reference /Volumes.

# CONTROL PLANE — internal disk, deliberately. These are small and fixed-size, and
# they must stay writable when the external volume is DETACHED: a missing volume is
# itself the failure that has to be recorded (heartbeat) and reported (watchdog.log).
# Putting the failure log on the volume whose absence is the failure is a trap.
BLUEX_LOG_DIR="$HOME/Library/Logs/BlueX"
BLUEX_HEARTBEAT="$BLUEX_LOG_DIR/last-run.json"
BLUEX_LOCK="$BLUEX_LOG_DIR/bluex-store.lock"
BLUEX_BIN="$HOME/.local/bin"

# The DATA lives on the external volume. Exported so the Swift CLIs resolve the same
# path this script checked.
export BLUEX_STORE_DIR="${BLUEX_STORE_DIR:-/Volumes/Eregion/bluex-data}"
BLUEX_STORE="$BLUEX_STORE_DIR/default.store"

# GROWING DATA — external volume. Everything that grows without bound during a run
# belongs next to the store, not on the internal disk. The 2026-08-04 run died when
# the internal disk filled while the store volume still had ~626 GB free.
#
#   run logs — ~100–600 KB per run, one file per run, never pruned. They describe work
#              that needs the volume anyway, so the volume being gone is the one case
#              where they are not wanted there (see bluex_log_path's fallback).
#   TMPDIR   — SQLite journal/rollback/temp files for the store itself. CoreData put
#              them under /var/folders (internal) even though the store is external.
#
# Both overridable so the regression tests can redirect them.
BLUEX_RUN_LOG_DIR="${BLUEX_RUN_LOG_DIR:-$BLUEX_STORE_DIR/logs}"
BLUEX_TMPDIR="${BLUEX_TMPDIR:-$BLUEX_STORE_DIR/tmp}"

mkdir -p "$BLUEX_LOG_DIR"

# Mirrors BlueXStore.isAvailable in Swift: the store directory's PARENT must exist,
# which is what "the volume is mounted" means. A full wake mounts external volumes
# asynchronously and the 03:31 job can win the race, so wait rather than fail.
# Timeout 0 = check once and return immediately.
#
# Also the case launchd's replay hits: if idle-sleep is ever re-enabled (see
# caffeinate note in bluex-nightly.sh), a missed 03:31 StartCalendarInterval
# fires on the next wake, which may be a DarkWake with /Volumes/Eregion still
# unmounted — that's what the bounded wait plus exit 75 is for.
bluex_wait_for_store() {
  local timeout="${1:-180}" waited=0
  local parent="${BLUEX_STORE_DIR:h}"
  while [ ! -d "$parent" ]; do
    if [ "$waited" -ge "$timeout" ]; then
      return 1
    fi
    sleep 5
    waited=$(( waited + 5 ))
  done
  return 0
}

# Desktop notification. Requires the user's Aqua session, so this works from a
# LaunchAgent and NOT from a root LaunchDaemon (there is none in this design).
#
# Escape BACKSLASH FIRST, then double quote — the other order would re-escape the
# backslashes this function itself inserted. A stray backslash in a log path or an
# error message used to produce an AppleScript syntax error, and a failed
# notification in the alerting path is the one thing that must never be silent, so
# a failure is recorded on disk rather than swallowed.
bluex_notify() {
  local title="$1" message="$2"
  title="${title//\\/\\\\}"; title="${title//\"/\\\"}"
  message="${message//\\/\\\\}"; message="${message//\"/\\\"}"
  if ! osascript -e "display notification \"$message\" with title \"$title\"" >/dev/null 2>&1; then
    echo "$(date): notification FAILED — $1: $2" >>"$BLUEX_LOG_DIR/notify-failures.log"
  fi
  return 0
}

# Read one scalar field out of the heartbeat JSON. Echoes the raw token (unquoted
# number or bare word such as `true`) and returns 1 if the file or key is absent.
# Deliberately grep+sed rather than a JSON parser: these scripts must run under
# launchd with no dependencies beyond the base system.
bluex_json_field() {
  local file="$1" key="$2" raw
  [ -e "$file" ] || return 1
  raw=$(grep -Eo "\"$key\"[[:space:]]*:[[:space:]]*[^,}[:space:]]+" "$file" 2>/dev/null | tail -1)
  [ -n "$raw" ] || return 1
  # Strip up to the FIRST colon only — the key never contains one, but values
  # (timestamps, paths) can.
  echo "${raw#*:}" | tr -d ' "'
}

# True when the store volume is mounted AND the growing-data directories can be
# created there. Everything volume-hosted goes through this, so an unmounted (or
# read-only) volume degrades to the internal disk instead of failing.
bluex_store_volume_ready() {
  bluex_wait_for_store 0 || return 1
  return 0
}

# Where this run's log goes: the store volume when it is there, the internal control
# plane directory when it is not. The fallback is not a nicety — the mount-wait
# failure is logged through this same function, and a log path on the missing volume
# would turn "volume absent → exit 75 → notify" into a confusing secondary failure.
bluex_log_path() {
  local dir="$BLUEX_LOG_DIR"
  if bluex_store_volume_ready && mkdir -p "$BLUEX_RUN_LOG_DIR" 2>/dev/null; then
    dir="$BLUEX_RUN_LOG_DIR"
  fi
  echo "$dir/$1_$(date "+%Y-%m-%d_%H%M%S").log"
}

# Where a human should look for run logs. Same present/absent split as bluex_log_path,
# so the watchdog's notifications keep pointing somewhere that exists.
bluex_log_hint() {
  if bluex_store_volume_ready && [ -d "$BLUEX_RUN_LOG_DIR" ]; then
    echo "$BLUEX_RUN_LOG_DIR"
  else
    echo "$BLUEX_LOG_DIR"
  fi
}

# TMPDIR for the store's SQLite scratch files. Set at source time so every child
# process (both CLIs) inherits it.
#
# ONLY when the volume is actually mounted. With the drive detached we must not create
# directories under it, and must not point TMPDIR at a path that does not exist —
# leaving TMPDIR untouched keeps the job able to write its own diagnostics and exit 75
# cleanly.
if bluex_store_volume_ready && mkdir -p "$BLUEX_TMPDIR" 2>/dev/null; then
  export TMPDIR="$BLUEX_TMPDIR"
fi

# Age of a file in seconds. Missing files report a huge age so callers can treat
# "absent" and "ancient" identically — the outage produced both.
bluex_age_seconds() {
  local f="$1"
  if [ ! -e "$f" ]; then
    echo 999999999
    return
  fi
  echo $(( $(date +%s) - $(stat -f %m "$f") ))
}
