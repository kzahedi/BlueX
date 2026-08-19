#!/bin/zsh
# tools/jobs/bluex-watchdog.sh — staleness check. User LaunchAgent, 06:56.
#
# Rides the existing 06:55 wakepoweron. Notification only — it arms nothing and
# nothing arms it. There is no privileged component anywhere in this design (see
# lib-bluex-job.sh): the mini never idle-sleeps, so the nightly agent fires on a
# plain StartCalendarInterval and this watchdog fires on its own. Neither depends on
# the previous night's run, so there is no chain a failed run can break.
#
# Exists because the 2026-06-04 outage failed silently for 61 days. Three signals,
# because each alone has a blind spot:
#   heartbeat mtime — distinguishes "never ran" from "ran and found nothing"
#   store mtime     — distinguishes "ran" from "ran and actually wrote data"
#   heartbeat exits — a job that fails identically every night keeps its own
#                     heartbeat fresh, so mtime alone would call it healthy. That
#                     is precisely how 61 days passed.
set -u

JOBS_DIR="${0:A:h}"
source "$JOBS_DIR/lib-bluex-job.sh"

# The continuous agent (net.pulsschlag.bluex.continuous) refreshes the heartbeat
# every pass — every CONTINUOUS_INTERVAL_SECONDS (20 min in production), not once a
# night — so a healthy agent's heartbeat age is measured in minutes, not hours. The
# threshold stays conservative anyway: a long backfill pass (many hours against a
# large window) legitimately holds the heartbeat still for the whole pass, and that
# must not false-alarm. 6h is generous for a single pass while still catching an
# agent that has actually stopped running.
STALE_AFTER=$(( 6 * 3600 ))
# The watchdog's OWN log stays on the internal disk with the rest of the control
# plane: it has to be writable precisely when the volume is missing.
LOG="$BLUEX_LOG_DIR/watchdog.log"
# Where the per-run logs actually are — the store volume when mounted, the internal
# directory otherwise. Notifications must not send the reader to a path that is gone.
LOG_HINT="$(bluex_log_hint)"

heartbeat_age=$(bluex_age_seconds "$BLUEX_HEARTBEAT")
store_age=$(bluex_age_seconds "$BLUEX_STORE")


# ---- exit codes from the most recent heartbeat -------------------------------
# bluex-nightly.sh writes these for us and, until this branch, nobody read them.
#
# Judged UNCONDITIONALLY. A deadline stop used to exempt them, on the theory that a
# multi-day backfill hits 07:00 every night and that is not a failure. True, but the
# exemption also hid every real failure for the length of the backfill — a scrape
# that failed at 04:00 and was then SIGINTed at 07:00 read as healthy. And it bought
# nothing: a deadline SIGINT on its own always yields exit 0 from both CLIs, so a
# nonzero exit always means a genuine failure, deadline or not.
scrape_exit=$(bluex_json_field "$BLUEX_HEARTBEAT" scrapeExit)
sentiment_exit=$(bluex_json_field "$BLUEX_HEARTBEAT" sentimentExit)
# Not a failure — annotation losing its slot to a long scrape is expected during a
# backfill — but it must not be invisible either.
sentiment_skipped=$(bluex_json_field "$BLUEX_HEARTBEAT" sentimentSkipped)
# "continuous" (net.pulsschlag.bluex.continuous) vs absent (an older, retired
# nightly-format heartbeat still on disk). Only the continuous agent ever sets
# permissionBlocked, so mode gates that check below too.
mode=$(bluex_json_field "$BLUEX_HEARTBEAT" mode)
# Set by bluex-continuous.sh while the store is unwritable — the launchd TCC/EPERM
# state described in bluex-continuous.sh's header. This is deliberately checked
# BEFORE the staleness logic: the continuous agent keeps rewriting the heartbeat
# every retry, so a blocked agent looks perfectly "fresh" by mtime alone, and would
# otherwise report as healthy for as long as Full Disk Access is missing.
permission_blocked=$(bluex_json_field "$BLUEX_HEARTBEAT" permissionBlocked)

echo "$(date): heartbeat=${heartbeat_age}s store=${store_age}s threshold=${STALE_AFTER}s mode=${mode:-?} scrapeExit=${scrape_exit:-?} sentimentExit=${sentiment_exit:-?} sentimentSkipped=${sentiment_skipped:-?} permissionBlocked=${permission_blocked:-?}" >>"$LOG"

if [ "$permission_blocked" = "true" ]; then
  message="permission still missing — grant Full Disk Access to /bin/zsh — see $LOG_HINT"
  bluex_notify "BlueX permission blocked" "$message"
  echo "$(date): PERMISSION BLOCKED — notified (${message})." >>"$LOG"
  exit 1
fi

# An absent field means an older heartbeat format, not a success — but the staleness
# checks already cover a heartbeat that is not being rewritten, so only a PRESENT
# nonzero value alarms here.
failures=()
[ -n "$scrape_exit" ] && [ "$scrape_exit" != "0" ] && failures+=("scrape (exit $scrape_exit)")
[ -n "$sentiment_exit" ] && [ "$sentiment_exit" != "0" ] && failures+=("sentiment (exit $sentiment_exit)")

heartbeat_stale=0
store_stale=0
[ "$heartbeat_age" -gt "$STALE_AFTER" ] && heartbeat_stale=1
[ "$store_age" -gt "$STALE_AFTER" ] && store_stale=1

# A failing-but-punctual job is its own alarm, independent of freshness.
if [ "${#failures[@]}" -gt 0 ]; then
  also_stale=""
  { [ "$heartbeat_stale" -eq 1 ] || [ "$store_stale" -eq 1 ] } && also_stale=" and data is stale"
  message="Last run failed: ${(j:, :)failures}${also_stale} — check $LOG_HINT"
  bluex_notify "BlueX nightly failing" "$message"
  echo "$(date): FAILED RUN — notified (${message})." >>"$LOG"
  exit 1
fi

if [ "$heartbeat_stale" -eq 1 ] || [ "$store_stale" -eq 1 ]; then
  # A day count only means something when derived from the signal that is
  # actually stale. Deriving "days" from store_age while the heartbeat is the
  # one that's stale/missing produced "No successful run in 0d" for the exact
  # scenario this watchdog exists to catch — a scrape-only run that never
  # finishes the nightly job. Name the tripped signal instead of guessing.
  if [ "$store_stale" -eq 1 ]; then
    days=$(( store_age / 86400 ))
    if [ "$heartbeat_stale" -eq 1 ]; then
      message="No successful run and no new data in ${days}d — check $LOG_HINT"
    else
      message="Store hasn't updated in ${days}d — check $LOG_HINT"
    fi
  else
    message="Nightly job hasn't completed a run recently — check $LOG_HINT"
  fi
  bluex_notify "BlueX is stale" "$message"
  echo "$(date): STALE — notified (${message})." >>"$LOG"
  exit 1
fi

# Not stale and nothing failed — but the sentiment pass may still have been starved
# of its slot by a long scrape. Expected during a backfill, so this is a heads-up at
# exit 0, not an alarm: annotation silently not running for weeks while both exits
# stayed 0 is the kind of gap this watchdog exists to surface.
#
# Skipped for mode=continuous: that agent sets sentimentSkipped=true on EVERY
# heartbeat by design (it never runs annotation at all — see bluex-continuous.sh),
# so without this guard every pass would fire this notification, forever.
if [ "$mode" != "continuous" ] && [ "$sentiment_skipped" = "true" ]; then
  bluex_notify "BlueX sentiment skipped" "Last run scraped but never annotated (no budget left) — check $LOG_HINT"
  echo "$(date): fresh, but sentiment was skipped on the last run — notified." >>"$LOG"
  exit 0
fi

echo "$(date): fresh." >>"$LOG"
exit 0
