#!/bin/zsh
# tools/jobs/bluex-watchdog.sh — staleness check. User LaunchAgent, 06:56.
#
# Rides the existing 06:55 wakepoweron. Notification only: arming the nightly wake
# belongs to the root daemon, which runs off that same wakepoweron rather than off
# the previous night's job, so there is no chain a failed run can break.
#
# Exists because the 2026-06-04 outage failed silently for 61 days. Checking BOTH
# the heartbeat and the store mtime distinguishes "ran but wrote nothing" from
# "never ran at all" — the outage was the second kind.
set -u

JOBS_DIR="${0:A:h}"
source "$JOBS_DIR/lib-bluex-job.sh"

STALE_AFTER=$(( 48 * 3600 ))
LOG="$BLUEX_LOG_DIR/watchdog.log"

heartbeat_age=$(bluex_age_seconds "$BLUEX_HEARTBEAT")
store_age=$(bluex_age_seconds "$BLUEX_STORE")

echo "$(date): heartbeat=${heartbeat_age}s store=${store_age}s threshold=${STALE_AFTER}s" >>"$LOG"

if [ "$heartbeat_age" -gt "$STALE_AFTER" ] || [ "$store_age" -gt "$STALE_AFTER" ]; then
  days=$(( store_age / 86400 ))
  bluex_notify "BlueX is stale" "No successful run in ${days}d — check $BLUEX_LOG_DIR"
  echo "$(date): STALE — notified (${days}d)." >>"$LOG"
  exit 1
fi

echo "$(date): fresh." >>"$LOG"
exit 0
