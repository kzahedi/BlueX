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

# ---- Telegram daily job (net.pulsschlag.bluex.telegram.daily) ---------------
# Closes a gap deliberately deferred when that job was implemented: it writes
# its own heartbeat (ts/mode/exit/ok_channels/failed_channels[/skipped]) but
# until now nobody read it. Same "each signal covers a blind spot" reasoning
# as the Bluesky checks above, but this job is a StartCalendarInterval
# ONE-SHOT (06:17 daily), not a KeepAlive loop, so "stale" here means "hasn't
# completed a run recently", not "process died".
#
# Computed and reported UNCONDITIONALLY, before any of the Bluesky exit
# points below: a Telegram-side problem must never be masked by (or mask) a
# Bluesky-side one, so both are always checked and both are always notified.
TELEGRAM_HEARTBEAT="$BLUEX_STORE_DIR/social/telegram-heartbeat.json"
# Small state file next to the heartbeat, not in the internal control plane —
# unlike watchdog.log/heartbeat/lock, this exists only to remember what the
# single-slot telegram heartbeat cannot: the last few runs' skip/ok outcomes.
# It belongs with the data it describes. One line per DISTINCT run, deduped by
# ts, so a watchdog invoked more than once between telegram runs never
# double-counts a skip.
TELEGRAM_SKIP_STATE="$BLUEX_STORE_DIR/social/telegram-skip-streak.log"
# File presence stands in for "installed" — the same convention test_jobs.py
# already uses for the other agents' plists (WATCHDOG_PLIST/CONTINUOUS_PLIST):
# checking actual launchd load state would mean shelling out to launchctl,
# which the tests must never do, and would tell us nothing more useful than
# "the plist is on disk" for a LaunchAgent only this Mac ever installs for
# itself.
TELEGRAM_PLIST="$HOME/Library/LaunchAgents/net.pulsschlag.bluex.telegram.daily.plist"
# The job runs once a day at 06:17. 36h tolerates one missed day (the Mac
# asleep through its StartCalendarInterval, say) plus clock skew, without
# waiting so long that two missed days in a row go unnoticed.
TELEGRAM_STALE_AFTER=$(( 36 * 3600 ))
# A permanently-off VPN produces an unbroken run of "skipped: no-vpn"
# heartbeats that are each individually correct and individually
# non-alarming under the project's hard VPN rule — this is the count of
# consecutive such runs that earns an explicit callout, because a VPN that
# never comes back means the corpus silently stops growing.
TELEGRAM_SKIP_STREAK_THRESHOLD=3

telegram_alarm=0
telegram_installed=0
[ -f "$TELEGRAM_PLIST" ] && telegram_installed=1

if [ ! -e "$TELEGRAM_HEARTBEAT" ]; then
  if [ "$telegram_installed" -eq 1 ]; then
    telegram_alarm=1
    bluex_notify "BlueX Telegram is stale" "Telegram daily job has never reported in (no heartbeat found) — check $LOG_HINT"
    echo "$(date): telegram: STALE — no heartbeat and $TELEGRAM_PLIST is installed — notified." >>"$LOG"
  else
    # Not installed is not a fault — nothing should be running, so nothing
    # having ever written a heartbeat is exactly correct.
    echo "$(date): telegram: not installed — no heartbeat expected." >>"$LOG"
  fi
else
  telegram_age=$(bluex_age_seconds "$TELEGRAM_HEARTBEAT")
  telegram_ts=$(bluex_json_field "$TELEGRAM_HEARTBEAT" ts)
  telegram_skipped=$(bluex_json_field "$TELEGRAM_HEARTBEAT" skipped)
  telegram_failed=$(bluex_json_field "$TELEGRAM_HEARTBEAT" failed_channels)

  last_ts=""
  [ -f "$TELEGRAM_SKIP_STATE" ] && last_ts=$(tail -1 "$TELEGRAM_SKIP_STATE" 2>/dev/null | cut -d' ' -f1)
  if [ -n "$telegram_ts" ] && [ "$telegram_ts" != "$last_ts" ]; then
    skip_flag=0
    [ "$telegram_skipped" = "no-vpn" ] && skip_flag=1
    echo "$telegram_ts $skip_flag" >>"$TELEGRAM_SKIP_STATE"
  fi

  # Count the trailing run of skip_flag=1 lines — i.e. the CURRENT streak,
  # read from the most recent line backwards. `tail -r` is BSD tail (macOS);
  # this whole design already targets a single specific Mac, same as the
  # rest of this file.
  skip_streak=0
  if [ -f "$TELEGRAM_SKIP_STATE" ]; then
    while IFS=' ' read -r _ flag; do
      if [ "$flag" = "1" ]; then
        skip_streak=$(( skip_streak + 1 ))
      else
        skip_streak=0
        break
      fi
    done < <(tail -r "$TELEGRAM_SKIP_STATE" 2>/dev/null)
  fi

  if [ "$telegram_age" -gt "$TELEGRAM_STALE_AFTER" ]; then
    telegram_alarm=1
    telegram_days=$(( telegram_age / 86400 ))
    bluex_notify "BlueX Telegram is stale" "Telegram daily job hasn't completed a run in ${telegram_days}d — check $LOG_HINT"
    echo "$(date): telegram: STALE — no run in ${telegram_days}d — notified." >>"$LOG"
  elif [ "$telegram_skipped" = "no-vpn" ]; then
    # Correct, expected behaviour under the hard VPN rule — never an alarm —
    # but it must stay visible, and a long streak deserves to say so plainly.
    if [ "$skip_streak" -ge "$TELEGRAM_SKIP_STREAK_THRESHOLD" ]; then
      bluex_notify "BlueX Telegram skipped (no VPN)" "Last ${skip_streak} consecutive daily runs were all skipped for no-vpn — corpus has stopped growing"
      echo "$(date): telegram: skipped (no-vpn), ${skip_streak} in a row — notified." >>"$LOG"
    else
      bluex_notify "BlueX Telegram skipped (no VPN)" "Last run was skipped: no-vpn — expected under the hard VPN rule, not a failure"
      echo "$(date): telegram: skipped (no-vpn) — notified." >>"$LOG"
    fi
  else
    echo "$(date): telegram: fresh." >>"$LOG"
  fi

  if [ -n "$telegram_failed" ] && [ "$telegram_failed" != "0" ]; then
    telegram_alarm=1
    bluex_notify "BlueX Telegram failed channels" "${telegram_failed} channel(s) failed on the last run — check $LOG_HINT"
    echo "$(date): telegram: FAILED-CHANNELS (${telegram_failed}) — notified." >>"$LOG"
  fi
fi


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
  # An otherwise-healthy Bluesky exit must still surface a Telegram-side
  # alarm — see the "computed unconditionally" note above.
  [ "$telegram_alarm" -eq 1 ] && exit 1
  exit 0
fi

echo "$(date): fresh." >>"$LOG"
[ "$telegram_alarm" -eq 1 ] && exit 1
exit 0
