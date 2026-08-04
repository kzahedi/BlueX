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
# LaunchAgent and NOT from the root arm-wake daemon.
bluex_notify() {
  local title="$1" message="$2"
  osascript -e "display notification \"${message//\"/\\\"}\" with title \"${title//\"/\\\"}\"" \
    >/dev/null 2>&1 || true
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
