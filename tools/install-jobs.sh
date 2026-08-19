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

# BlueX.xcodeproj is generated from project.yml, so building without regenerating
# can compile a .pbxproj that predates the current source list — a new shared file
# or a changed target would be silently missing and the installer would still
# report success. Fail loudly rather than install a stale binary.
echo "==> regenerating BlueX.xcodeproj from project.yml"
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "✗ xcodegen not found on PATH. Install it (brew install xcodegen) and re-run." >&2
  exit 1
fi
( cd "$REPO_ROOT" && xcodegen generate )

echo "==> building CLIs"
"$REPO_ROOT/tools/install-cli.sh"

echo "==> installing job scripts to $JOBS_DEST"
mkdir -p "$JOBS_DEST" "$AGENTS_DIR" "$HOME/Library/Logs/BlueX"
install -m 644 "$JOBS_SRC/lib-bluex-job.sh"     "$JOBS_DEST/"
install -m 755 "$JOBS_SRC/bluex-nightly.sh"     "$JOBS_DEST/"
install -m 755 "$JOBS_SRC/bluex-continuous.sh"  "$JOBS_DEST/"
install -m 755 "$JOBS_SRC/bluex-watchdog.sh"    "$JOBS_DEST/"

# net.pulsschlag.bluex.continuous (KeepAlive, RunAtLoad) REPLACES the 03:31 nightly
# agent — "make sure the scraper is always running" means an always-on agent, not a
# once-a-night StartCalendarInterval. bluex-nightly.sh stays in the repo (and its
# tests keep covering it) but is no longer installed as a LaunchAgent.
echo "==> retiring the superseded scrape/annotate/nightly agents"
for old in net.pulsschlag.bluex.scrape net.pulsschlag.bluex.annotate net.pulsschlag.bluex.nightly; do
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

write_continuous_agent() {   # label script
  local label="$1" script="$2"
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
    <key>KeepAlive</key>
    <true/>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/BlueX/launchd.$label.out.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/BlueX/launchd.$label.err.log</string>
</dict>
</plist>
PLIST
  launchctl bootout "gui/$UID_NUM/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$UID_NUM" "$AGENTS_DIR/$label.plist"
  echo "  ✓ $label (KeepAlive, RunAtLoad)"
}

echo "==> installing user agents"
write_continuous_agent net.pulsschlag.bluex.continuous bluex-continuous.sh
write_agent net.pulsschlag.bluex.watchdog bluex-watchdog.sh 6 56

echo
echo "Installed. Verify with:"
echo "  launchctl print gui/$UID_NUM/net.pulsschlag.bluex.continuous | head -20"
echo "  tail -f \"$HOME/Library/Logs/BlueX/continuous.log\""
echo
echo "NOTE: if /Volumes/Eregion writes fail with 'operation not permitted', grant"
echo "Full Disk Access to /bin/zsh in System Settings > Privacy & Security. Until"
echo "then bluex-continuous.sh treats that as a normal retry state (see its"
echo "header) — no reinstall is needed once the grant lands."
echo
echo "NOTE: pmset is deliberately untouched. The mini never idle-sleeps"
echo "(pmset -g custom | grep '^ sleep'), which is what lets the KeepAlive"
echo "continuous agent and the watchdog's calendar trigger both fire reliably."
