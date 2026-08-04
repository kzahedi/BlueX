#!/usr/bin/env bash
# tools/install-jobs.sh — install the BlueX nightly jobs on this machine.
#
# Runtime artefacts must NOT live on /Volumes/Eregion: launchd fires these jobs
# during DarkWake, when that external volume is unmounted. That is exactly what
# broke scraping for 61 days from 2026-06-04. Everything the jobs need is copied
# to the internal disk here. Only the STORE DATA lives on Eregion.
#
# No privileged component: the mini is set to never idle-sleep (`sleep 0`), so
# launchd fires the 03:31 agent while it is awake and no pmset wake — and therefore
# no root daemon — is needed. This script must never call sudo; a test enforces that.
#
# Idempotent — safe to re-run after every rebuild.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOBS_SRC="$REPO_ROOT/tools/jobs"
JOBS_DEST="$HOME/Library/Application Support/BlueX/jobs"
AGENTS_DIR="$HOME/Library/LaunchAgents"
UID_NUM="$(id -u)"

echo "==> building CLIs"
"$REPO_ROOT/tools/install-cli.sh"

echo "==> installing job scripts to $JOBS_DEST"
mkdir -p "$JOBS_DEST" "$AGENTS_DIR" "$HOME/Library/Logs/BlueX"
install -m 644 "$JOBS_SRC/lib-bluex-job.sh"  "$JOBS_DEST/"
install -m 755 "$JOBS_SRC/bluex-nightly.sh"  "$JOBS_DEST/"
install -m 755 "$JOBS_SRC/bluex-watchdog.sh" "$JOBS_DEST/"

echo "==> retiring the superseded scrape/annotate agents"
for old in net.pulsschlag.bluex.scrape net.pulsschlag.bluex.annotate; do
  launchctl bootout "gui/$UID_NUM/$old" 2>/dev/null || true
  rm -f "$AGENTS_DIR/$old.plist"
  echo "  ✓ removed $old"
done

write_agent() {   # label script hour minute
  local label="$1" script="$2" hour="$3" minute="$4"
  cat >"$AGENTS_DIR/$label.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/zsh</string>
        <string>$JOBS_DEST/$script</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key><integer>$hour</integer>
        <key>Minute</key><integer>$minute</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/BlueX/launchd.$label.out.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/BlueX/launchd.$label.err.log</string>
    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
PLIST
  launchctl bootout "gui/$UID_NUM/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$UID_NUM" "$AGENTS_DIR/$label.plist"
  echo "  ✓ $label"
}

echo "==> installing user agents"
write_agent net.pulsschlag.bluex.nightly  bluex-nightly.sh  3 31
write_agent net.pulsschlag.bluex.watchdog bluex-watchdog.sh 6 56

echo
echo "Installed. Verify with:"
echo "  \"$JOBS_DEST/bluex-nightly.sh\" --preflight"
echo "  launchctl print gui/$UID_NUM/net.pulsschlag.bluex.nightly | head -20"
echo
echo "NOTE: pmset is deliberately untouched. This relies on the mini never"
echo "idle-sleeping (pmset -g custom | grep '^ sleep'). If sleep is re-enabled,"
echo "launchd replays a missed 03:31 event on the next wake."
