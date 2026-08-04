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

heartbeat_stale=0
store_stale=0
[ "$heartbeat_age" -gt "$STALE_AFTER" ] && heartbeat_stale=1
[ "$store_age" -gt "$STALE_AFTER" ] && store_stale=1

if [ "$heartbeat_stale" -eq 1 ] || [ "$store_stale" -eq 1 ]; then
  # A day count only means something when derived from the signal that is
  # actually stale. Deriving "days" from store_age while the heartbeat is the
  # one that's stale/missing produced "No successful run in 0d" for the exact
  # scenario this watchdog exists to catch — a scrape-only run that never
  # finishes the nightly job. Name the tripped signal instead of guessing.
  if [ "$store_stale" -eq 1 ]; then
    days=$(( store_age / 86400 ))
    if [ "$heartbeat_stale" -eq 1 ]; then
      message="No successful run and no new data in ${days}d — check $BLUEX_LOG_DIR"
    else
      message="Store hasn't updated in ${days}d — check $BLUEX_LOG_DIR"
    fi
  else
    message="Nightly job hasn't completed a run recently — check $BLUEX_LOG_DIR"
  fi
  bluex_notify "BlueX is stale" "$message"
  echo "$(date): STALE — notified (${message})." >>"$LOG"
  exit 1
fi

echo "$(date): fresh." >>"$LOG"
exit 0
