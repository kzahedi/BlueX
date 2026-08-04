# tools/jobs/lib-bluex-job.sh — shared helpers for the BlueX launchd jobs.
# Sourced, never executed.
#
# These scripts are installed to the internal disk on purpose. launchd fires them
# during DarkWake, when /Volumes/Eregion is not mounted — that is what caused the
# 61-day outage beginning 2026-06-04. Nothing here may reference /Volumes.

BLUEX_LOG_DIR="$HOME/Library/Logs/BlueX"
BLUEX_HEARTBEAT="$BLUEX_LOG_DIR/last-run.json"
BLUEX_LOCK="$BLUEX_LOG_DIR/bluex-store.lock"
BLUEX_BIN="$HOME/.local/bin"

# The DATA lives on the external volume; logs, locks and the heartbeat stay on the
# internal disk so they remain writable even when the drive is detached. Exported so
# the Swift CLIs resolve the same path this script checked.
export BLUEX_STORE_DIR="${BLUEX_STORE_DIR:-/Volumes/Eregion/bluex-data}"
BLUEX_STORE="$BLUEX_STORE_DIR/default.store"

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

bluex_log_path() {
  echo "$BLUEX_LOG_DIR/$1_$(date "+%Y-%m-%d_%H%M%S").log"
}

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
