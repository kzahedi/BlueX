#!/bin/zsh
# tools/jobs/bluex-telegram-daily.sh — daily incremental Telegram collection.
# One-shot (StartCalendarInterval), not KeepAlive: a failed day is retried
# tomorrow via the next scheduled fire; the heartbeat records the outcome so a
# failure is visible without tailing logs.
#
# Ops rule: new channels must be backfilled (collect.py --mode backfill)
# before they rely on this incremental job — incremental has no resume
# checkpoints.
set -u

DATA=/Volumes/Eregion/bluex-data/social
LOGDIR=/Volumes/Eregion/bluex-data/logs
REPO=/Volumes/Eregion/projects/bluex-v2
TS=$(date +%Y-%m-%d_%H%M%S)
LOG="$LOGDIR/telegram_${TS}.log"
JSONOUT="$LOGDIR/telegram_${TS}.json"
HEARTBEAT="$DATA/telegram-heartbeat.json"

mkdir -p "$DATA" "$LOGDIR" 2>/dev/null

# Store writability probe (TCC/EPERM = transient, not a crash). Same reasoning
# as bluex-continuous.sh's bluex_probe_store_writable: launchd-spawned zsh can
# be denied write access to /Volumes/Eregion even when it is mounted, and the
# only reliable way to detect that is an actual write attempt. This job's own
# status line goes to the internal-disk control-plane log
# ($HOME/Library/Logs/BlueX), never to the (possibly unwritable) store, for
# the same reason lib-bluex-job.sh keeps its control plane off the external
# volume.
if ! touch "$DATA/.probe" 2>/dev/null; then
  echo "$(date): store not writable (EPERM/TCC?) — skipping run" >> "$HOME/Library/Logs/BlueX/telegram.log"
  exit 0
fi
rm -f "$DATA/.probe"

cd "$REPO" || exit 1

# launchd's PATH is minimal and does not include conda, so python3 resolved
# via bare PATH here would be /usr/bin/python3 — which lacks this collector's
# third-party deps (requests, beautifulsoup4). Per this machine's convention
# (CLAUDE.md: "Use conda environment particula for Python development"), the
# `particula` conda env has them; fall back to plain PATH python3 so the
# script still runs (and fails loudly rather than silently) somewhere without
# that env.
PYTHON=/opt/miniconda3/envs/particula/bin/python3
[ -x "$PYTHON" ] || PYTHON=python3

# collect.py prints exactly one JSON object to stdout (its report) — keep that
# on its own stream/file so the heartbeat parser never has to pick a JSON
# object out of merged stdout+stderr noise. stderr (tracebacks, warnings)
# still lands in $LOG for human debugging.
"$PYTHON" tools/social/telegram/collect.py --db "$DATA/telegram.db" \
  --mode incremental >"$JSONOUT" 2>"$LOG"
EXIT=$?

"$PYTHON" - "$JSONOUT" "$HEARTBEAT" "$EXIT" <<'EOF'
import json, sys, datetime
jsonout, hb, code = sys.argv[1], sys.argv[2], int(sys.argv[3])
ok = failed = 0
try:
    report = json.load(open(jsonout))
    ok = sum(1 for c in report["channels"] if c["status"] == "complete")
    failed = sum(1 for c in report["channels"] if c["status"] == "failed")
except Exception:
    pass
json.dump({"ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
           "mode": "telegram-incremental", "exit": code,
           "ok_channels": ok, "failed_channels": failed}, open(hb, "w"))
EOF

echo "$(date): telegram incremental exit=$EXIT — see $LOG" >> "$HOME/Library/Logs/BlueX/telegram.log"
exit $EXIT
