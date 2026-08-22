"""Guards against the fault that caused the 2026-06-04 outage.

launchd was told to run the job scripts from /Volumes/Eregion — an external
volume that is not mounted during DarkWake — so every run died with
"can't open input file" and exit 127, silently, for 61 days.

The store data was later moved onto that same volume deliberately, so the rule is
not "no /Volumes anywhere". It is: the DATA may live there, the CODE may not.

The second half of this file guards the SAFETY LOGIC added while fixing that outage:
exit-code propagation, the rule that a deadline stop may never mask a failure, the
heartbeat contract between bluex-nightly.sh (writer) and bluex-watchdog.sh (reader),
the watchdog's decision table, and bluex_wait_for_store. All of that had been verified
once by hand and then thrown away, which is how the original bug survived 61 days:
nothing executable disagreed with it.

Those tests drive the REAL scripts in a subprocess with the whole environment
redirected into a pytest tmp_path (see _sandbox). They must never touch the real
~/Library/Logs/BlueX or the real store on /Volumes/Eregion: a stray real heartbeat
would make the watchdog report healthy while nothing runs, and a stray real lock
would make the next genuine nightly run skip silently. Both are worse than the
outage this branch exists to remove.
"""

import json
import os
import plistlib
import re
import stat
import subprocess
import time
from pathlib import Path

import pytest

JOBS_SRC = Path(__file__).parent
RUNTIME_SCRIPTS = [
    "lib-bluex-job.sh",
    "bluex-nightly.sh",
    "bluex-watchdog.sh",
    "bluex-continuous.sh",
]
AGENTS_DIR = Path.home() / "Library/LaunchAgents"
NIGHTLY_PLIST = AGENTS_DIR / "net.pulsschlag.bluex.nightly.plist"
WATCHDOG_PLIST = AGENTS_DIR / "net.pulsschlag.bluex.watchdog.plist"
CONTINUOUS_PLIST = AGENTS_DIR / "net.pulsschlag.bluex.continuous.plist"


@pytest.mark.parametrize("name", RUNTIME_SCRIPTS)
def test_volumes_is_used_only_for_the_store_data_path(name):
    """Data on Eregion is fine. CODE on Eregion is what broke.

    launchd execs these scripts and can fire during DarkWake, when the volume is
    unmounted. A /Volumes path may therefore only ever be the store DATA directory,
    whose availability bluex_wait_for_store checks explicitly — never a script,
    source target or exec target.
    """
    offenders = []
    for line in (JOBS_SRC / name).read_text().splitlines():
        if "/Volumes" not in line or line.lstrip().startswith("#"):
            continue
        if "BLUEX_STORE_DIR" not in line:
            offenders.append(line)
    assert not offenders, (
        f"{name}: /Volumes used for something other than the store directory: {offenders}"
    )


@pytest.mark.parametrize("name", RUNTIME_SCRIPTS)
def test_nothing_is_sourced_or_executed_from_an_external_volume(name):
    for line in (JOBS_SRC / name).read_text().splitlines():
        stripped = line.lstrip()
        if stripped.startswith("#") or "/Volumes" not in stripped:
            continue
        if "source " in stripped or stripped.startswith(". "):
            pytest.fail(f"{name} sources from an external volume: {line}")


@pytest.mark.parametrize("name", RUNTIME_SCRIPTS)
def test_runtime_script_parses(name):
    result = subprocess.run(
        ["zsh", "-n", str(JOBS_SRC / name)], capture_output=True, text=True
    )
    assert result.returncode == 0, result.stderr


def test_installer_needs_no_privilege_escalation():
    """The design deliberately has no privileged component.

    The mini never idle-sleeps, so no pmset wake is needed, so nothing requires root.
    A sudo call reappearing here means someone reintroduced the daemon.
    """
    text = (JOBS_SRC.parent / "install-jobs.sh").read_text()
    offenders = [
        line
        for line in text.splitlines()
        if "sudo" in line and not line.lstrip().startswith("#")
    ]
    assert not offenders, f"install-jobs.sh must not require sudo: {offenders}"


@pytest.mark.parametrize("plist_path", [WATCHDOG_PLIST, CONTINUOUS_PLIST])
def test_installed_agent_points_at_an_existing_internal_script(plist_path):
    if not plist_path.exists():
        pytest.skip(f"{plist_path.name} not installed — run tools/install-jobs.sh")
    with plist_path.open("rb") as handle:
        data = plistlib.load(handle)
    script = data["ProgramArguments"][-1]
    assert "/Volumes" not in script, f"points at an external volume: {script}"
    assert os.path.exists(script), f"points at a missing script: {script}"


def test_superseded_agents_are_removed():
    if not CONTINUOUS_PLIST.exists():
        pytest.skip("new agents not installed yet — run tools/install-jobs.sh")
    for old in ("net.pulsschlag.bluex.scrape", "net.pulsschlag.bluex.annotate"):
        assert not (
            AGENTS_DIR / f"{old}.plist"
        ).exists(), f"{old}.plist should have been removed by install-jobs.sh"


def test_nightly_agent_is_retired_by_install_in_favour_of_continuous():
    """The 03:31 nightly agent is superseded, not kept alongside the continuous one.

    Mirrors test_superseded_agents_are_removed: real, machine-state check that only
    runs once install-jobs.sh has actually been run on this box (it is deliberately
    NOT run as part of this change — see the static check below for the always-on
    guarantee).
    """
    if not CONTINUOUS_PLIST.exists():
        pytest.skip("new agents not installed yet — run tools/install-jobs.sh")
    assert not NIGHTLY_PLIST.exists(), (
        "net.pulsschlag.bluex.nightly.plist should have been removed by "
        "install-jobs.sh once the continuous agent replaces it"
    )
    with CONTINUOUS_PLIST.open("rb") as handle:
        data = plistlib.load(handle)
    assert data.get("KeepAlive") is True
    assert data.get("RunAtLoad") is True


def test_installer_source_retires_nightly_and_installs_continuous_with_keepalive():
    """Static check, independent of whether install-jobs.sh has actually been run.

    Running the real installer is out of scope here (it regenerates the Xcode
    project and rebuilds the CLIs via install-cli.sh) — a manual catch-up scrape is
    running from the installed binary right now, and this change must not touch or
    reinstall it. So verify the SOURCE does the right thing: retires
    net.pulsschlag.bluex.nightly the same way it already retires scrape/annotate,
    and installs the continuous agent with KeepAlive+RunAtLoad.
    """
    text = (JOBS_SRC.parent / "install-jobs.sh").read_text()
    retire_block = re.search(r"for old in ([^\n]*)\n", text)
    assert retire_block, "no 'for old in ...' retirement loop found"
    assert "net.pulsschlag.bluex.nightly" in retire_block.group(1), (
        "install-jobs.sh does not retire net.pulsschlag.bluex.nightly: "
        f"{retire_block.group(1)!r}"
    )
    assert "write_continuous_agent net.pulsschlag.bluex.continuous bluex-continuous.sh" in text
    assert "<key>KeepAlive</key>" in text and "<key>RunAtLoad</key>" in text


# ---------------------------------------------------------------------------
# Sandbox: run the real scripts with every filesystem effect inside tmp_path.
# ---------------------------------------------------------------------------
# lib-bluex-job.sh derives BLUEX_LOG_DIR, BLUEX_HEARTBEAT, BLUEX_LOCK and BLUEX_BIN
# from $HOME, and BLUEX_STORE_DIR is already overridable. Overriding just those two
# variables therefore redirects *everything* — logs, heartbeat, lock, and the location
# the scrape/annotate binaries are looked up in — with no production change at all.
#
# osascript and caffeinate are shadowed by stubs on PATH rather than suppressed: a
# notification that silently fails to fire is the one thing this whole design cannot
# tolerate, so the tests must be able to assert the notification actually happened.

NIGHTLY = JOBS_SRC / "bluex-nightly.sh"
WATCHDOG = JOBS_SRC / "bluex-watchdog.sh"
CONTINUOUS = JOBS_SRC / "bluex-continuous.sh"
LIB = JOBS_SRC / "lib-bluex-job.sh"

_STUB_OSASCRIPT = """#!/bin/sh
# Records the notification instead of displaying it. Exit 0 so bluex_notify does not
# take its "notification FAILED" branch.
printf '%s\\n' "$*" >>"$BLUEX_TEST_NOTIFY_LOG"
exit 0
"""

# Real caffeinate would take a power assertion for the length of the test run. The
# nightly script's cleanup kills this pid, and killing an already-dead pid is
# explicitly harmless there.
_STUB_CAFFEINATE = "#!/bin/sh\nexit 0\n"

# Exits with a chosen code. --check-credentials must succeed or preflight aborts
# before the code under test is ever reached.
_STUB_CLI = """#!/bin/sh
if [ "$1" = "--check-credentials" ]; then exit 0; fi
echo "stub {name}: $*"
exit {code}
"""

# Long-running variant that mirrors the real CLIs under the deadline SIGINT: it stops
# at the next "boundary" and reports SUCCESS, because a deadline stop is not a failure.
#
# Python rather than sh, and this is not a stylistic choice. run_bounded starts the CLI
# with `"$@" &`, and a non-interactive zsh sets SIGINT to SIG_IGN in background
# children; POSIX then forbids a shell script from trapping a signal that was already
# ignored on entry, so an `sh` stub silently cannot react to the deadline at all and
# runs to completion. The real Swift CLIs are unaffected because installSIGINTHandler
# installs its own disposition after exec — and so does this stub.
_STUB_CLI_INTERRUPTIBLE = """#!/usr/bin/env python3
import signal, sys, time
if "--check-credentials" in sys.argv:
    raise SystemExit(0)
print("stub {name}:", *sys.argv[1:], flush=True)
signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
time.sleep(120)
raise SystemExit(0)
"""


def _write_exec(path: Path, text: str) -> None:
    path.write_text(text)
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class _Sandbox:
    def __init__(self, tmp_path: Path, scrape_exit=0, sentiment_exit=0, slow_scrape=False):
        self.root = tmp_path
        self.home = tmp_path / "home"
        self.bin = self.home / ".local/bin"
        self.stubs = tmp_path / "stubs"
        # A stand-in for the external volume: the store dir's PARENT existing is what
        # "the volume is mounted" means (see bluex_wait_for_store).
        self.volume = tmp_path / "volume"
        self.store_dir = self.volume / "bluex-data"
        self.store = self.store_dir / "default.store"
        self.log_dir = self.home / "Library/Logs/BlueX"
        self.heartbeat = self.log_dir / "last-run.json"
        self.lock = self.log_dir / "bluex-store.lock"
        # What GROWS during a run lives next to the store on the volume; the control
        # plane above stays internal. Defaults derived from BLUEX_STORE_DIR in
        # lib-bluex-job.sh, so redirecting the store dir redirects these too.
        self.run_log_dir = self.store_dir / "logs"
        self.job_tmpdir = self.store_dir / "tmp"
        self.notify_log = tmp_path / "notifications.log"
        # Telegram daily job (net.pulsschlag.bluex.telegram.daily) — heartbeat lives
        # next to the rest of the social data on the store volume, same as
        # bluex-telegram-daily.sh writes it for real. The skip-streak state file sits
        # right beside it (see bluex-watchdog.sh) since it exists only to remember
        # what that single-slot heartbeat cannot: the last few runs' outcomes.
        self.telegram_heartbeat = self.store_dir / "social/telegram-heartbeat.json"
        self.telegram_skip_state = self.store_dir / "social/telegram-skip-streak.log"
        # LaunchAgents live under $HOME, which this sandbox already redirects.
        self.telegram_plist = (
            self.home / "Library/LaunchAgents/net.pulsschlag.bluex.telegram.daily.plist"
        )

        for d in (self.bin, self.stubs, self.store_dir, self.log_dir):
            d.mkdir(parents=True, exist_ok=True)
        self.store.write_text("stub store\n")
        self.notify_log.write_text("")

        _write_exec(self.stubs / "osascript", _STUB_OSASCRIPT)
        _write_exec(self.stubs / "caffeinate", _STUB_CAFFEINATE)
        template = _STUB_CLI_INTERRUPTIBLE if slow_scrape else _STUB_CLI
        _write_exec(
            self.bin / "blueX-scrape",
            template.format(name="scrape", code=scrape_exit),
        )
        _write_exec(
            self.bin / "blueX-annotate",
            _STUB_CLI.format(name="annotate", code=sentiment_exit),
        )

        env = {k: v for k, v in os.environ.items() if not k.startswith("BLUEX_")}
        for leaked in ("DEADLINE_TIME", "SENTIMENT_RESERVE_SECONDS", "TIMER_POLL_SECONDS"):
            env.pop(leaked, None)
        # The deadline timer polls every 5s in production, which costs ~10s of pure
        # waiting per nightly run here. 1s keeps the suite in seconds; the production
        # default is asserted separately by test_the_testability_knobs_keep_their_
        # production_defaults, since launchd passes no environment at all.
        env["TIMER_POLL_SECONDS"] = "1"
        env["HOME"] = str(self.home)
        env["BLUEX_STORE_DIR"] = str(self.store_dir)
        env["BLUEX_TEST_NOTIFY_LOG"] = str(self.notify_log)
        env["PATH"] = f"{self.stubs}:{env.get('PATH', '/usr/bin:/bin')}"
        self.env = env

    def run(self, script: Path, *args, extra_env=None, timeout=120):
        env = dict(self.env)
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            ["zsh", str(script), *args],
            capture_output=True,
            text=True,
            env=env,
            cwd=str(self.root),
            timeout=timeout,
        )

    @property
    def notifications(self) -> str:
        return self.notify_log.read_text()

    def nightly_log(self) -> str:
        """Every run log, wherever it landed — volume when mounted, internal when not."""
        logs = sorted(self.run_log_dir.glob("nightly_*.log")) + sorted(
            self.log_dir.glob("nightly_*.log")
        )
        return "\n".join(p.read_text() for p in logs)

    def watchdog_log(self) -> str:
        p = self.log_dir / "watchdog.log"
        return p.read_text() if p.exists() else ""

    def write_heartbeat(self, age_seconds=0, **fields):
        self.heartbeat.write_text(json.dumps(fields, indent=2) + "\n")
        self._age(self.heartbeat, age_seconds)

    def age_store(self, age_seconds):
        self._age(self.store, age_seconds)

    def write_healthy_bluesky_heartbeat(self, age_seconds=60):
        """A baseline 'nothing wrong on the Bluesky side' heartbeat + store.

        Used by the telegram-focused tests below so they exercise only the new
        telegram behaviour, without also tripping the pre-existing staleness/
        failure checks this watchdog already had (those have their own decision
        table above).
        """
        self.write_heartbeat(
            age_seconds=age_seconds,
            finishedAt="2026-08-20T02:11:00Z",
            scrapeExit=0,
            sentimentExit=0,
            stoppedAtDeadline=False,
            sentimentSkipped=False,
            log=str(self.log_dir / "nightly_x.log"),
        )
        self.age_store(age_seconds)

    def write_telegram_heartbeat(self, age_seconds=0, **fields):
        self.telegram_heartbeat.parent.mkdir(parents=True, exist_ok=True)
        self.telegram_heartbeat.write_text(json.dumps(fields))
        self._age(self.telegram_heartbeat, age_seconds)

    def install_telegram_plist(self):
        self.telegram_plist.parent.mkdir(parents=True, exist_ok=True)
        self.telegram_plist.write_text("<plist/>")

    def seed_telegram_skip_history(self, *entries):
        """Pre-existing state-file lines, oldest first: (ts, skipped_bool)."""
        self.telegram_skip_state.parent.mkdir(parents=True, exist_ok=True)
        lines = [f"{ts} {1 if skipped else 0}" for ts, skipped in entries]
        self.telegram_skip_state.write_text("\n".join(lines) + "\n")

    @staticmethod
    def _age(path: Path, age_seconds):
        when = time.time() - age_seconds
        os.utime(path, (when, when))


@pytest.fixture
def sandbox(tmp_path):
    """Default sandbox: both stub CLIs succeed immediately."""
    return _Sandbox(tmp_path)


def _near_deadline(offset_minutes=5, budget_seconds=8):
    """A DEADLINE_TIME a few minutes out, plus the reserve that leaves `budget_seconds`.

    The scrape's stop is DEADLINE_EPOCH - SENTIMENT_RESERVE_SECONDS, so sizing the
    reserve is the only way to give the scrape a budget of seconds rather than hours.

    Two pieces of BSD `date` behaviour make the arithmetic exact:

    * `date -j -f "%Y-%m-%d %H:%M"` leaves the SECONDS field unspecified, and BSD date
      fills it from the current clock rather than zeroing it. The script's deadline
      epoch is therefore (its own now) with HH:MM replaced — i.e. exactly
      offset_minutes ahead of the moment we sampled the clock here, not truncated to
      the minute. So the reserve is simply offset*60 - budget, with no correction, and
      the small delay before the script reads its own clock cancels out.
    * A time already past is rolled forward a day by the script, which is what makes
      this correct across midnight: at 23:58 "+5M" yields "00:03", which the script
      reads as today-00:03 (past), adds 86400 to, and lands ~5 minutes ahead.

    The one thing that would break it is the minute rolling over between our sample and
    the script's, which would shift the deadline by a whole minute and could make the
    budget negative (silently turning the deadline test into the no-budget shortcut).
    Hence the wait out of the last few seconds of a minute.
    """
    while time.localtime().tm_sec > 50:
        time.sleep(0.5)
    hhmm = subprocess.run(
        ["date", f"-v+{offset_minutes}M", "+%H:%M"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    return hhmm, offset_minutes * 60 - budget_seconds


# ---------------------------------------------------------------------------
# 1. Exit-code propagation — the bug this whole branch exists to eliminate.
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "scrape_exit,sentiment_exit,expect_in_message",
    [
        (2, 0, "scrape=2 sentiment=0"),
        (0, 3, "scrape=0 sentiment=3"),
        (2, 3, "scrape=2 sentiment=3"),
    ],
)
def test_a_failing_step_is_notified_and_exits_nonzero(
    tmp_path, scrape_exit, sentiment_exit, expect_in_message
):
    """A nonzero step must ALWAYS produce a notification and a nonzero script exit.

    The 2026-06-04 outage was exactly this going missing: the jobs failed every night
    for 61 days while nothing reported it. Whole-script run, because the thing being
    tested is the wiring between run_bounded's return value, the heartbeat and the
    final exit — not any single function.
    """
    sb = _Sandbox(tmp_path, scrape_exit=scrape_exit, sentiment_exit=sentiment_exit)
    result = sb.run(NIGHTLY)

    assert result.returncode != 0, (
        f"a failing step exited 0 — silent failure reintroduced.\n{result.stdout}\n{result.stderr}"
    )
    assert "BlueX nightly failed" in sb.notifications, (
        f"no failure notification was sent. notifications={sb.notifications!r}"
    )
    assert expect_in_message in sb.notifications
    heartbeat = json.loads(sb.heartbeat.read_text())
    assert heartbeat["scrapeExit"] == scrape_exit
    assert heartbeat["sentimentExit"] == sentiment_exit


def test_a_clean_run_exits_zero_and_sends_no_failure_notification(sandbox):
    result = sandbox.run(NIGHTLY)
    assert result.returncode == 0, f"{result.stdout}\n{result.stderr}"
    assert "failed" not in sandbox.notifications.lower(), sandbox.notifications
    heartbeat = json.loads(sandbox.heartbeat.read_text())
    assert heartbeat["scrapeExit"] == 0 and heartbeat["sentimentExit"] == 0
    assert heartbeat["stoppedAtDeadline"] is False
    assert heartbeat["sentimentSkipped"] is False


# ---------------------------------------------------------------------------
# 2. A deadline stop must never mask a failure.
# ---------------------------------------------------------------------------


def test_a_deadline_stop_does_not_mask_a_failure(tmp_path):
    """Hitting the deadline AND failing must still report the failure.

    A fix wave once suppressed the failure notification on any deadline night, which
    hid every real failure for the whole length of a multi-day backfill — the same
    silent-failure class as the original outage, reintroduced by a fix for it. Only a
    human-directed reviewer caught it, which is why this test exists.

    Whole-script run, and deliberately through the REAL timer/SIGINT path rather than
    the cheaper "no budget left" shortcut: the deadline flag file written by the timer
    subshell is the mechanism a future edit is most likely to break. The scrape stub is
    interruptible and reports exit 0 on SIGINT, mirroring the real CLIs — so the
    failure here comes solely from the sentiment step, and the deadline is the only
    thing that could excuse it.
    """
    deadline, reserve = _near_deadline()
    sb = _Sandbox(tmp_path, sentiment_exit=4, slow_scrape=True)
    result = sb.run(
        NIGHTLY,
        extra_env={
            "DEADLINE_TIME": deadline,
            "SENTIMENT_RESERVE_SECONDS": str(reserve),
        },
    )

    log = sb.nightly_log()
    heartbeat = json.loads(sb.heartbeat.read_text())
    assert heartbeat["stoppedAtDeadline"] is True, (
        f"the deadline never fired, so this test proved nothing.\nlog:\n{log}"
    )
    assert "stopped at the" in log, (
        f"expected the timer/SIGINT branch, not the no-budget shortcut.\nlog:\n{log}"
    )
    assert result.returncode != 0, (
        f"deadline night masked a failing step — regression.\nlog:\n{log}"
    )
    assert "BlueX nightly failed" in sb.notifications, sb.notifications
    assert "sentiment=4" in sb.notifications
    assert "deadline" in sb.notifications, (
        "the notification should say the deadline was also hit"
    )


def test_a_deadline_stop_on_its_own_is_not_a_failure(tmp_path):
    """The converse guard: a deadline stop with both exits 0 is "ran short", not failed.

    Without this, someone fixing the test above could make every backfill night alarm.
    Uses the "no budget left before the deadline" path — the deadline is inside the
    sentiment reserve, so the scrape never starts — which needs no waiting at all.
    """
    deadline, _ = _near_deadline()
    sb = _Sandbox(tmp_path)
    result = sb.run(NIGHTLY, extra_env={"DEADLINE_TIME": deadline})

    log = sb.nightly_log()
    heartbeat = json.loads(sb.heartbeat.read_text())
    assert heartbeat["stoppedAtDeadline"] is True, f"log:\n{log}"
    assert heartbeat["scrapeExit"] == 0 and heartbeat["sentimentExit"] == 0
    assert result.returncode == 0, f"a mere deadline stop alarmed.\nlog:\n{log}"
    assert "BlueX nightly failed" not in sb.notifications, sb.notifications
    assert "ran short, not failed" in log


# ---------------------------------------------------------------------------
# 3. Heartbeat contract between the writer and the reader.
# ---------------------------------------------------------------------------

HEARTBEAT_FIELDS = [
    "finishedAt",
    "scrapeExit",
    "sentimentExit",
    "stoppedAtDeadline",
    "sentimentSkipped",
    "log",
]


def test_heartbeat_written_by_nightly_is_valid_json_with_every_contract_field(sandbox):
    """The heartbeat is hand-assembled with a here-doc, so nothing else validates it.

    An unescaped value or a stray comma would produce a file the watchdog silently
    reads as "no fields present" — which its own design reads as *not a failure*. So a
    malformed heartbeat is indistinguishable from a healthy one. Parse it strictly.
    """
    assert sandbox.run(NIGHTLY).returncode == 0
    data = json.loads(sandbox.heartbeat.read_text())
    assert sorted(data) == sorted(HEARTBEAT_FIELDS), f"contract drifted: {sorted(data)}"
    # The heartbeat must point at wherever the log ACTUALLY went — with the volume
    # mounted that is the run-log dir on the volume, not the internal control plane.
    assert data["log"].startswith(str(sandbox.run_log_dir)), data["log"]


def test_the_watchdogs_reader_can_read_every_field_the_writer_writes(sandbox):
    """Writer and reader must agree — they share no code, only a format.

    bluex_json_field is grep+sed by design (no dependencies under launchd), so it is the
    pair most likely to drift apart silently, and a field the reader cannot see reads as
    "absent", which the watchdog treats as *not a failure*.

    Mixed approach on purpose: the heartbeat is produced by the real writer (one whole
    nightly run) and then read back through the real reader function sourced in a
    zsh subprocess, because bluex_json_field's output cannot be observed any other way.
    One nightly run for all fields — each one costs wall-clock time.
    """
    assert sandbox.run(NIGHTLY).returncode == 0
    written = json.loads(sandbox.heartbeat.read_text())
    for field in HEARTBEAT_FIELDS:
        expected = written[field]
        result = subprocess.run(
            [
                "zsh",
                "-c",
                f'source "{LIB}"; bluex_json_field "$1" "$2"',
                "_",
                str(sandbox.heartbeat),
                field,
            ],
            capture_output=True,
            text=True,
            env=sandbox.env,
        )
        assert result.returncode == 0, f"reader could not find {field}: {result.stderr}"
        raw = result.stdout.strip()
        assert raw, f"reader returned nothing for {field}"
        if isinstance(expected, bool):
            assert raw == ("true" if expected else "false"), field
        elif isinstance(expected, int):
            assert int(raw) == expected, field
        else:
            # Paths and timestamps contain colons; the reader must split on the FIRST
            # colon only, or a log path comes back truncated to "/Users/…/Library/Logs".
            assert raw == str(expected).replace(" ", ""), field


def test_watchdog_tolerates_an_older_heartbeat_without_the_boolean_fields(sandbox):
    """An older heartbeat predates stoppedAtDeadline/sentimentSkipped.

    An absent field must read as "unknown", never as a failure and never as a crash
    under `set -u`. The staleness checks already cover a heartbeat that has stopped
    being rewritten, so a fresh old-format heartbeat with zero exits is healthy.
    """
    sandbox.write_heartbeat(
        finishedAt="2026-08-03T02:11:00Z",
        scrapeExit=0,
        sentimentExit=0,
        log=str(sandbox.log_dir / "nightly_old.log"),
    )
    result = sandbox.run(WATCHDOG)
    assert result.returncode == 0, f"{result.stdout}\n{result.stderr}"
    assert result.stderr == "", f"unset-variable crash: {result.stderr}"
    assert sandbox.notifications == "", sandbox.notifications
    assert "fresh." in sandbox.watchdog_log()


# ---------------------------------------------------------------------------
# 4. Watchdog decision table.
# ---------------------------------------------------------------------------

_FRESH = 60
_STALE = 72 * 3600  # > the 48h threshold


@pytest.mark.parametrize(
    "case,hb_age,store_age,hb_fields,rc,expect,forbid",
    [
        (
            # No notification at all is the correct output here — hence the empty
            # expectation and the log assertion at the end of the test body.
            "fresh and clean",
            _FRESH,
            _FRESH,
            dict(scrapeExit=0, sentimentExit=0, sentimentSkipped=False),
            0,
            [],
            ["BlueX"],
        ),
        (
            "punctual but scrape failed",
            _FRESH,
            _FRESH,
            dict(scrapeExit=2, sentimentExit=0, sentimentSkipped=False),
            1,
            ["BlueX nightly failing", "scrape (exit 2)"],
            ["sentiment (exit", "and data is stale"],
        ),
        (
            "punctual but sentiment failed",
            _FRESH,
            _FRESH,
            dict(scrapeExit=0, sentimentExit=9, sentimentSkipped=False),
            1,
            ["BlueX nightly failing", "sentiment (exit 9)"],
            ["scrape (exit"],
        ),
        (
            "failed and stale",
            _STALE,
            _STALE,
            dict(scrapeExit=2, sentimentExit=0, sentimentSkipped=False),
            1,
            ["BlueX nightly failing", "scrape (exit 2)", "and data is stale"],
            [],
        ),
        (
            "store stale only",
            _FRESH,
            _STALE,
            dict(scrapeExit=0, sentimentExit=0, sentimentSkipped=False),
            1,
            ["BlueX is stale", "Store hasn't updated in 3d"],
            ["No successful run"],
        ),
        (
            "both stale",
            _STALE,
            _STALE,
            dict(scrapeExit=0, sentimentExit=0, sentimentSkipped=False),
            1,
            ["BlueX is stale", "No successful run and no new data in 3d"],
            [],
        ),
        (
            "fresh but sentiment skipped",
            _FRESH,
            _FRESH,
            dict(scrapeExit=0, sentimentExit=0, sentimentSkipped=True),
            0,
            ["BlueX sentiment skipped"],
            ["BlueX is stale", "BlueX nightly failing"],
        ),
    ],
)
def test_watchdog_decision_table(
    sandbox, case, hb_age, store_age, hb_fields, rc, expect, forbid
):
    """Each of the watchdog's three signals has a blind spot the others cover.

    A "simplification" that collapses two branches would silently restore one of those
    blind spots — a failing-but-punctual job reading as healthy is how 61 days passed.
    The forbidden strings matter as much as the expected ones: a message must name the
    signal that actually tripped and nothing else.
    """
    sandbox.write_heartbeat(
        age_seconds=hb_age,
        finishedAt="2026-08-03T02:11:00Z",
        log=str(sandbox.log_dir / "nightly_x.log"),
        stoppedAtDeadline=False,
        **hb_fields,
    )
    sandbox.age_store(store_age)

    result = sandbox.run(WATCHDOG)
    notifications = sandbox.notifications
    assert result.returncode == rc, (
        f"{case}: exit {result.returncode} != {rc}\n{result.stdout}\n{result.stderr}"
    )
    for needle in expect:
        assert needle in notifications, f"{case}: missing {needle!r} in {notifications!r}"
    for needle in forbid:
        assert needle not in notifications, f"{case}: unexpected {needle!r} in {notifications!r}"
    if not expect:
        assert "fresh." in sandbox.watchdog_log(), (
            f"{case}: silence must still be recorded in the log"
        )


@pytest.mark.parametrize("missing_heartbeat", [True, False])
def test_a_stale_heartbeat_is_never_reported_as_a_day_count_from_the_store(
    sandbox, missing_heartbeat
):
    """The "No successful run in 0d" bug: a day count from the wrong signal.

    When the heartbeat is the stale/absent signal and the store is fresh (a scrape-only
    run that never completes the nightly job — exactly what this watchdog exists to
    catch), any "Nd" figure derived from store_age reads 0d and looks like nothing is
    wrong. The message must name the tripped signal instead of guessing a number.
    """
    if missing_heartbeat:
        assert not sandbox.heartbeat.exists()
    else:
        sandbox.write_heartbeat(
            age_seconds=_STALE,
            finishedAt="2026-07-30T02:11:00Z",
            scrapeExit=0,
            sentimentExit=0,
            stoppedAtDeadline=False,
            sentimentSkipped=False,
            log="x",
        )
    sandbox.age_store(_FRESH)

    result = sandbox.run(WATCHDOG)
    assert result.returncode == 1, f"{result.stdout}\n{result.stderr}"
    assert "Nightly job hasn't completed a run recently" in sandbox.notifications
    assert "0d" not in sandbox.notifications, (
        f"day count derived from the wrong signal: {sandbox.notifications!r}"
    )


# ---------------------------------------------------------------------------
# 5. bluex_wait_for_store — must mirror Swift's BlueXStore.isAvailable.
# ---------------------------------------------------------------------------


def _wait_for_store(sandbox, store_dir, timeout):
    """Sourced-function approach: a whole-script run cannot isolate the timeout=0 path."""
    started = time.monotonic()
    result = subprocess.run(
        ["zsh", "-c", f'source "{LIB}"; bluex_wait_for_store "$1"', "_", str(timeout)],
        capture_output=True,
        text=True,
        env={**sandbox.env, "BLUEX_STORE_DIR": str(store_dir)},
    )
    return result.returncode, time.monotonic() - started


def test_wait_for_store_checks_the_parent_not_the_store_directory(sandbox, tmp_path):
    """"Available" means the VOLUME is mounted, which is the PARENT existing.

    BlueXStore.isAvailable in Swift checks the parent for the same reason: on a first
    run the store directory itself does not exist yet, and checking it would make the
    nightly job exit 75 forever on a perfectly mounted drive.
    """
    mounted_but_empty = tmp_path / "volume/not-created-yet"
    assert not mounted_but_empty.exists()
    rc, _ = _wait_for_store(sandbox, mounted_but_empty, 0)
    assert rc == 0, "reported unavailable although the parent (the volume) exists"

    unmounted = tmp_path / "no-such-volume/bluex-data"
    rc, _ = _wait_for_store(sandbox, unmounted, 0)
    assert rc == 1, "reported available although the parent does not exist"


def test_wait_for_store_with_timeout_zero_returns_immediately(sandbox, tmp_path):
    """Timeout 0 must check once and return — preflight calls it in the foreground.

    The loop sleeps BEFORE re-checking the timeout, so an off-by-one here turns
    `bluex_wait_for_store 0` into a 5-second stall on every preflight, and any larger
    regression into a 180-second one.
    """
    rc, elapsed = _wait_for_store(sandbox, tmp_path / "no-such-volume/bluex-data", 0)
    assert rc == 1
    assert elapsed < 2, f"timeout 0 slept for {elapsed:.1f}s"


@pytest.mark.parametrize(
    "default",
    [
        'DEADLINE_TIME="${DEADLINE_TIME:-07:00}"',
        'SENTIMENT_RESERVE_SECONDS="${SENTIMENT_RESERVE_SECONDS:-$(( 20 * 60 ))}"',
        'TIMER_POLL_SECONDS="${TIMER_POLL_SECONDS:-5}"',
    ],
)
def test_the_testability_knobs_keep_their_production_defaults(default):
    """The three env overrides exist only for these tests and must change nothing live.

    launchd starts these agents with no environment, so the default is what production
    always gets — which also means an accidentally changed default would never show up
    in any test that sets the variable. Pin the literals instead.
    """
    assert default in NIGHTLY.read_text(), f"production default changed: {default}"


# ---------------------------------------------------------------------------
# 6. The lock must never outlive the run.
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("scrape_exit", [0, 2])
def test_the_store_lock_is_released_even_when_the_run_fails(tmp_path, scrape_exit):
    """A leftover lock makes the NEXT night skip silently for 18h — the outage pattern."""
    sb = _Sandbox(tmp_path, scrape_exit=scrape_exit)
    sb.run(NIGHTLY)
    assert not sb.lock.exists(), f"{sb.lock} survived the run"
    assert not list(sb.log_dir.glob(".deadline-fired.*")), "deadline flag left behind"


def test_a_second_concurrent_run_skips_instead_of_touching_the_store(sandbox):
    """Nightly-vs-nightly exclusion: a launchd replay must not open a second writer."""
    sandbox.lock.mkdir()
    result = sandbox.run(NIGHTLY)
    assert result.returncode == 0
    assert not sandbox.heartbeat.exists(), (
        "a skipped run wrote a heartbeat — the watchdog would read it as a real run"
    )
    assert "store busy" in sandbox.nightly_log()


# ---------------------------------------------------------------------------
# 7. Disk locality: what GROWS goes on the volume, the control plane stays internal.
# ---------------------------------------------------------------------------
# The 2026-08-04 run died with an uncaught NSException when the INTERNAL disk filled
# while the store volume still had ~626 GB free: the URLSession response cache, the
# SQLite temp files (TMPDIR under /var/folders) and one unbounded run log per run were
# all internal. The split below is the fix, and it is not symmetrical on purpose:
#
#   volume   — run logs (unbounded growth; describe work that needs the volume anyway)
#              and TMPDIR (SQLite scratch for a store that lives there)
#   internal — heartbeat, store lock, watchdog.log; small, fixed-size, and they must
#              stay writable when the volume is DETACHED, because a missing volume is
#              itself the failure that has to be recorded and reported.
#
# Collapsing either direction reintroduces one of the two outages: everything internal
# fills the boot disk, everything external means a detached drive cannot be diagnosed.


def _lib_eval(sandbox, snippet, extra_env=None):
    """Evaluate a snippet with lib-bluex-job.sh sourced, in a subprocess."""
    env = dict(sandbox.env)
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        ["zsh", "-c", f'source "{LIB}"; {snippet}'],
        capture_output=True,
        text=True,
        env=env,
    )


def test_run_logs_land_on_the_store_volume_when_it_is_mounted(sandbox):
    """One ~100–600 KB log per run, never pruned — the growth that must leave / ."""
    assert sandbox.run(NIGHTLY).returncode == 0
    on_volume = list(sandbox.run_log_dir.glob("nightly_*.log"))
    assert len(on_volume) == 1, f"expected one run log on the volume, got {on_volume}"
    assert not list(sandbox.log_dir.glob("nightly_*.log")), (
        "a run log was written to the internal control-plane directory as well"
    )
    assert "=== nightly" in on_volume[0].read_text()


def test_the_control_plane_stays_internal_while_the_volume_is_mounted(sandbox):
    """Heartbeat, lock and watchdog.log must not migrate to the volume.

    They are the only things that still work when the drive is gone, so "the volume is
    mounted" must not be what decides where they live.
    """
    assert sandbox.run(NIGHTLY).returncode == 0
    assert sandbox.run(WATCHDOG).returncode == 0

    assert sandbox.heartbeat.exists(), "heartbeat left the internal disk"
    assert (sandbox.log_dir / "watchdog.log").exists(), "watchdog.log left the internal disk"
    for stray in ("last-run.json", "watchdog.log", "bluex-store.lock"):
        assert not (sandbox.store_dir / stray).exists(), (
            f"{stray} was written to the store volume — unreadable when it detaches"
        )
    # The lock's own path is derived internally, not just absent because it was cleaned.
    assert str(sandbox.lock).startswith(str(sandbox.home))


def test_tmpdir_is_redirected_onto_the_store_volume_when_it_is_mounted(sandbox):
    """SQLite journal/temp for an external store must not land on /var/folders.

    This was internal even though the store was external, which is half of what filled
    the boot disk.
    """
    result = _lib_eval(sandbox, 'echo "$TMPDIR"')
    assert result.stdout.strip() == str(sandbox.job_tmpdir), result.stdout
    assert sandbox.job_tmpdir.is_dir(), "TMPDIR exported but never created"


def test_tmpdir_is_left_alone_when_the_volume_is_missing(sandbox, tmp_path):
    """A detached drive must not get directories created on it, or a dead TMPDIR.

    Pointing TMPDIR at a path under an unmounted volume would turn the clean
    "volume missing → exit 75 → notify" path into a confusing secondary failure in
    which the job cannot even write its own diagnostics.
    """
    missing = tmp_path / "no-such-volume/bluex-data"
    result = _lib_eval(
        sandbox,
        'echo "$TMPDIR"',
        extra_env={"BLUEX_STORE_DIR": str(missing), "TMPDIR": "/tmp/inherited"},
    )
    assert result.stdout.strip() == "/tmp/inherited", (
        f"TMPDIR was overridden although the volume is absent: {result.stdout!r}"
    )
    assert not missing.parent.exists(), "created a directory under an unmounted volume"


def test_log_path_falls_back_to_the_internal_directory_when_the_volume_is_missing(
    sandbox, tmp_path
):
    """The mount-wait failure is logged through this very function.

    So a run-log path on the volume whose absence IS the failure cannot be logged at
    all — the fallback is what keeps exit 75 diagnosable.
    """
    missing = tmp_path / "no-such-volume/bluex-data"
    result = _lib_eval(
        sandbox, "bluex_log_path nightly", extra_env={"BLUEX_STORE_DIR": str(missing)}
    )
    path = result.stdout.strip()
    assert path.startswith(str(sandbox.log_dir)), path
    assert not missing.parent.exists(), "created a directory under an unmounted volume"

    # …and with the volume present it goes to the volume instead.
    present = _lib_eval(sandbox, "bluex_log_path nightly").stdout.strip()
    assert present.startswith(str(sandbox.run_log_dir)), present


def test_watchdog_points_at_the_run_logs_that_exist(sandbox, tmp_path):
    """A notification naming a path on a missing volume is a dead end for the reader."""
    sandbox.run(NIGHTLY)          # creates the run-log dir on the volume
    sandbox.write_heartbeat(
        age_seconds=0,
        finishedAt="2026-08-05T02:11:00Z",
        scrapeExit=2,
        sentimentExit=0,
        stoppedAtDeadline=False,
        sentimentSkipped=False,
        log=str(sandbox.run_log_dir / "nightly_x.log"),
    )
    assert sandbox.run(WATCHDOG).returncode == 1
    assert str(sandbox.run_log_dir) in sandbox.notifications, sandbox.notifications

    missing = tmp_path / "no-such-volume/bluex-data"
    sandbox.notify_log.write_text("")
    result = sandbox.run(WATCHDOG, extra_env={"BLUEX_STORE_DIR": str(missing)})
    assert result.returncode == 1
    assert str(sandbox.log_dir) in sandbox.notifications, sandbox.notifications


# ---------------------------------------------------------------------------
# 8. bluex-continuous.sh — the always-running agent.
# ---------------------------------------------------------------------------
# These drive the real script as a long-lived background process (it has no exit
# condition of its own besides a signal) rather than through sandbox.run(), which
# waits for the process to finish. Every test terminates the process itself in a
# finally block — leaking a live subprocess across tests would make the whole file
# flaky and, worse, could leave a real lock or heartbeat behind.

CONTINUOUS_FAST_ENV = {
    "CONTINUOUS_INTERVAL_SECONDS": "1",
    "PERMISSION_RETRY_SECONDS": "1",
}


def _start_continuous(sandbox, extra_env=None):
    env = dict(sandbox.env)
    env.update(CONTINUOUS_FAST_ENV)
    if extra_env:
        env.update(extra_env)
    return subprocess.Popen(
        ["zsh", str(CONTINUOUS)],
        cwd=str(sandbox.root),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )


def _stop_continuous(proc, timeout=10):
    if proc.poll() is None:
        proc.terminate()
    try:
        proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=timeout)
    return proc.returncode


def _wait_until(predicate, deadline_seconds=10, interval=0.2):
    deadline = time.time() + deadline_seconds
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return False


def _supervisory_log(sandbox) -> str:
    p = sandbox.log_dir / "continuous.log"
    return p.read_text() if p.exists() else ""


def _wait_for_heartbeat_json(sandbox, deadline_seconds=10):
    """Poll for a heartbeat that both exists AND parses.

    The heredoc write in bluex-continuous.sh is not guaranteed atomic from a
    reader's point of view (open-then-write), so a bare .exists() check can catch
    the file mid-write. Retrying the parse rather than just the existence check
    avoids that race.
    """
    deadline = time.time() + deadline_seconds
    while time.time() < deadline:
        if sandbox.heartbeat.exists():
            try:
                return json.loads(sandbox.heartbeat.read_text())
            except json.JSONDecodeError:
                pass
        time.sleep(0.2)
    return None


def test_continuous_script_never_uses_sudo():
    offenders = [
        line
        for line in CONTINUOUS.read_text().splitlines()
        if "sudo" in line and not line.lstrip().startswith("#")
    ]
    assert not offenders, f"bluex-continuous.sh must not require sudo: {offenders}"


def test_eperm_probe_sleeps_and_retries_instead_of_exiting(tmp_path):
    """The launchd TCC/EPERM state (see the script's header) must never be an exit.

    An exit here hits launchd's KeepAlive throttle — the tight crash loop the whole
    design exists to avoid. Simulated with a real permission-denied directory (the
    store dir made unwritable), not a mocked function, so the assertion is against
    the same mkdir/write failure the real TCC block produces, not a stand-in for it.
    """
    sb = _Sandbox(tmp_path)
    os.chmod(sb.store_dir, 0o500)  # mounted (parent exists), but unwritable
    proc = _start_continuous(sb)
    try:
        blocked_seen = {"v": False}

        def _check():
            data = None
            if sb.heartbeat.exists():
                try:
                    data = json.loads(sb.heartbeat.read_text())
                except json.JSONDecodeError:
                    return False
            if data and data.get("permissionBlocked") is True:
                blocked_seen["v"] = True
                return True
            return False

        saw_blocked = _wait_until(_check, deadline_seconds=10)
        assert saw_blocked, (
            f"heartbeat never reported permissionBlocked=true. "
            f"log={_supervisory_log(sb)!r}"
        )
        # Give it a couple of retry cycles' worth of extra time, then confirm it is
        # STILL running rather than having exited after the first probe failure.
        time.sleep(2.5)
        assert proc.poll() is None, (
            "script exited on the EPERM/unwritable probe instead of "
            f"sleeping and retrying — this is the KeepAlive crash-loop bug. "
            f"log={_supervisory_log(sb)!r}"
        )
        log_text = _supervisory_log(sb)
        assert "unwritable" in log_text, log_text
        assert "retrying in" in log_text, log_text
    finally:
        os.chmod(sb.store_dir, 0o700)
        rc = _stop_continuous(proc)
    assert rc == 0, f"did not shut down cleanly on SIGTERM (rc={rc})"


def test_one_bad_pass_does_not_kill_the_continuous_agent(tmp_path):
    """A pass that fails is logged and heartbeat-recorded, and the loop continues.

    Runs the scrape stub with a permanent nonzero exit and confirms at least two
    failing passes complete while the process stays alive throughout — one bad pass
    (or several) must never end the agent.
    """
    sb = _Sandbox(tmp_path, scrape_exit=2)
    proc = _start_continuous(sb)
    try:
        saw_two_passes = _wait_until(
            lambda: _supervisory_log(sb).count("pass FAILED (exit 2)") >= 2,
            deadline_seconds=15,
        )
        assert saw_two_passes, (
            f"fewer than two passes completed — agent may have died after the "
            f"first failure. log={_supervisory_log(sb)!r}"
        )
        assert proc.poll() is None, (
            f"agent exited after a failing pass. log={_supervisory_log(sb)!r}"
        )
        log_text = _supervisory_log(sb)
        assert "pass FAILED (exit 2)" in log_text, log_text
        heartbeat = _wait_for_heartbeat_json(sb, deadline_seconds=5)
        assert heartbeat is not None, "heartbeat never parsed"
        assert heartbeat["scrapeExit"] == 2
        assert heartbeat["permissionBlocked"] is False
    finally:
        rc = _stop_continuous(proc)
    assert rc == 0, f"did not shut down cleanly on SIGTERM (rc={rc})"


def test_continuous_heartbeat_has_the_expected_fields(sandbox):
    """mode + permissionBlocked are new; the rest keep the existing contract shape."""
    proc = _start_continuous(sandbox)
    try:
        data = _wait_for_heartbeat_json(sandbox, deadline_seconds=10)
        assert data is not None, f"no heartbeat written. log={_supervisory_log(sandbox)!r}"
    finally:
        rc = _stop_continuous(proc)
    assert rc == 0
    assert data["mode"] == "continuous"
    assert data["scrapeExit"] == 0
    assert data["stoppedAtDeadline"] is False
    assert data["sentimentSkipped"] is True
    assert data["permissionBlocked"] is False
    assert set(data) == {
        "finishedAt",
        "mode",
        "scrapeExit",
        "stoppedAtDeadline",
        "sentimentSkipped",
        "permissionBlocked",
        "log",
    }


def test_continuous_agent_skips_a_pass_when_the_lock_is_held(sandbox):
    """A manual catch-up scrape (or an overlapping invocation) holds the same lock
    bluex-nightly.sh uses — the continuous agent must skip, not fight it, exactly
    like the nightly-vs-nightly exclusion test above."""
    sandbox.lock.mkdir()
    proc = _start_continuous(sandbox)
    try:
        saw_busy = _wait_until(
            lambda: "store busy" in _supervisory_log(sandbox), deadline_seconds=10
        )
        assert saw_busy, f"log={_supervisory_log(sandbox)!r}"
        assert not sandbox.heartbeat.exists(), (
            "a lock-skipped pass wrote a heartbeat — the watchdog would read this "
            "as a real (and successful) pass"
        )
    finally:
        sandbox.lock.rmdir()
        rc = _stop_continuous(proc)
    assert rc == 0


def test_watchdog_calls_out_the_permission_blocked_state_specifically(sandbox):
    """The whole point of the permissionBlocked field: a fresh, non-generic message.

    Without this, a heartbeat that is being rewritten every retry cycle looks
    perfectly healthy by mtime alone, and the user would get no signal at all that
    Full Disk Access is the thing actually missing.
    """
    sandbox.write_heartbeat(
        age_seconds=0,
        finishedAt="2026-08-19T02:11:00Z",
        mode="continuous",
        scrapeExit=0,
        stoppedAtDeadline=False,
        sentimentSkipped=True,
        permissionBlocked=True,
        log=str(sandbox.log_dir / "continuous.log"),
    )
    result = sandbox.run(WATCHDOG)
    assert result.returncode == 1
    assert "permission still missing" in sandbox.notifications, sandbox.notifications
    assert "Full Disk Access" in sandbox.notifications
    assert "/bin/zsh" in sandbox.notifications
    # Must NOT read as a generic stale/failure message instead.
    assert "BlueX is stale" not in sandbox.notifications
    assert "BlueX nightly failing" not in sandbox.notifications


def test_watchdog_does_not_nag_about_sentiment_in_continuous_mode(sandbox):
    """continuous heartbeats always carry sentimentSkipped=true by design (no
    annotation stage at all) — the legacy "sentiment skipped" heads-up must not
    fire on every single pass because of it."""
    sandbox.write_heartbeat(
        age_seconds=0,
        finishedAt="2026-08-19T02:11:00Z",
        mode="continuous",
        scrapeExit=0,
        stoppedAtDeadline=False,
        sentimentSkipped=True,
        permissionBlocked=False,
        log=str(sandbox.log_dir / "continuous.log"),
    )
    result = sandbox.run(WATCHDOG)
    assert result.returncode == 0
    assert "sentiment skipped" not in sandbox.notifications.lower(), sandbox.notifications


def test_watchdogs_stale_threshold_is_conservative_for_a_long_pass(sandbox):
    """A pass that legitimately runs for hours (a large backfill window) must not
    false-alarm — the threshold was loosened from 48h-tuned-for-once-a-night down to
    something still generous for a single long pass, not tightened to the ~1h a
    healthy continuous heartbeat normally refreshes at."""
    sandbox.write_heartbeat(
        age_seconds=3 * 3600,  # a long single pass, well under the 6h threshold
        finishedAt="2026-08-19T02:11:00Z",
        mode="continuous",
        scrapeExit=0,
        stoppedAtDeadline=False,
        sentimentSkipped=True,
        permissionBlocked=False,
        log=str(sandbox.log_dir / "continuous.log"),
    )
    result = sandbox.run(WATCHDOG)
    assert result.returncode == 0, sandbox.notifications
    assert sandbox.notifications == ""


# ---------------------------------------------------------------------------
# 9. bluex-watchdog.sh — Telegram daily job coverage.
# ---------------------------------------------------------------------------
# net.pulsschlag.bluex.telegram.daily runs once a day (06:17, one-shot, not
# KeepAlive) and writes its own heartbeat with a different, smaller contract
# (ts/mode/exit/ok_channels/failed_channels[/skipped]) — this deliberately
# closes the watchdog gap left open when that job was implemented. Every test
# here starts from a healthy Bluesky heartbeat/store so only the new telegram
# behaviour is under test; the decision table above already covers the
# Bluesky side on its own.

_TELEGRAM_FRESH = 60
_TELEGRAM_STALE = 40 * 3600  # > the 36h threshold


def test_telegram_fresh_heartbeat_is_healthy_and_silent(sandbox):
    sandbox.write_healthy_bluesky_heartbeat()
    sandbox.write_telegram_heartbeat(
        age_seconds=_TELEGRAM_FRESH,
        ts="2026-08-21T06:17:03+00:00",
        mode="telegram-incremental",
        exit=0,
        ok_channels=5,
        failed_channels=0,
    )
    result = sandbox.run(WATCHDOG)
    assert result.returncode == 0, f"{result.stdout}\n{result.stderr}"
    assert sandbox.notifications == "", sandbox.notifications
    assert "telegram" in sandbox.watchdog_log().lower()


def test_telegram_heartbeat_older_than_36h_is_stale(sandbox):
    sandbox.write_healthy_bluesky_heartbeat()
    sandbox.write_telegram_heartbeat(
        age_seconds=_TELEGRAM_STALE,
        ts="2026-08-19T06:17:03+00:00",
        mode="telegram-incremental",
        exit=0,
        ok_channels=5,
        failed_channels=0,
    )
    result = sandbox.run(WATCHDOG)
    assert result.returncode == 1, f"{result.stdout}\n{result.stderr}"
    assert "Telegram" in sandbox.notifications
    assert "stale" in sandbox.notifications.lower(), sandbox.notifications
    assert "1d" in sandbox.notifications, sandbox.notifications


def test_telegram_heartbeat_missing_and_plist_installed_is_stale(sandbox):
    sandbox.write_healthy_bluesky_heartbeat()
    assert not sandbox.telegram_heartbeat.exists()
    sandbox.install_telegram_plist()
    result = sandbox.run(WATCHDOG)
    assert result.returncode == 1, f"{result.stdout}\n{result.stderr}"
    assert "Telegram" in sandbox.notifications
    assert "stale" in sandbox.notifications.lower(), sandbox.notifications


def test_telegram_heartbeat_missing_and_not_installed_is_not_alarming(sandbox):
    sandbox.write_healthy_bluesky_heartbeat()
    assert not sandbox.telegram_heartbeat.exists()
    assert not sandbox.telegram_plist.exists()
    result = sandbox.run(WATCHDOG)
    assert result.returncode == 0, f"{result.stdout}\n{result.stderr}"
    assert "Telegram" not in sandbox.notifications, sandbox.notifications
    assert "not installed" in sandbox.watchdog_log().lower()


def test_telegram_no_vpn_skip_is_visible_but_not_alarming(sandbox):
    sandbox.write_healthy_bluesky_heartbeat()
    sandbox.write_telegram_heartbeat(
        age_seconds=_TELEGRAM_FRESH,
        ts="2026-08-21T06:17:03+00:00",
        mode="telegram-incremental",
        exit=0,
        ok_channels=0,
        failed_channels=0,
        skipped="no-vpn",
    )
    result = sandbox.run(WATCHDOG)
    assert result.returncode == 0, f"{result.stdout}\n{result.stderr}"
    assert "no-vpn" in sandbox.notifications.lower() or "no vpn" in sandbox.notifications.lower(), (
        sandbox.notifications
    )
    assert "Telegram" in sandbox.notifications


def test_three_consecutive_no_vpn_skips_are_called_out_explicitly(sandbox):
    sandbox.write_healthy_bluesky_heartbeat()
    sandbox.seed_telegram_skip_history(
        ("2026-08-19T06:17:01+00:00", True),
        ("2026-08-20T06:17:02+00:00", True),
    )
    sandbox.write_telegram_heartbeat(
        age_seconds=_TELEGRAM_FRESH,
        ts="2026-08-21T06:17:03+00:00",
        mode="telegram-incremental",
        exit=0,
        ok_channels=0,
        failed_channels=0,
        skipped="no-vpn",
    )
    result = sandbox.run(WATCHDOG)
    assert result.returncode == 0, f"{result.stdout}\n{result.stderr}"
    assert "3" in sandbox.notifications
    assert "consecutive" in sandbox.notifications.lower(), sandbox.notifications


def test_telegram_locked_skip_is_visible_but_not_alarming(sandbox):
    sandbox.write_healthy_bluesky_heartbeat()
    sandbox.write_telegram_heartbeat(
        age_seconds=_TELEGRAM_FRESH,
        ts="2026-08-21T06:17:03+00:00",
        mode="telegram-incremental",
        exit=3,
        ok_channels=0,
        failed_channels=0,
        skipped="locked",
    )
    result = sandbox.run(WATCHDOG)
    assert result.returncode == 0, f"{result.stdout}\n{result.stderr}"
    assert "locked" in sandbox.notifications.lower() or "already running" in sandbox.notifications.lower(), (
        sandbox.notifications
    )
    assert "Telegram" in sandbox.notifications


def test_many_consecutive_locked_skips_do_not_trigger_the_no_vpn_streak_alarm(sandbox):
    # A long supervised backfill can legitimately make the scheduled
    # incremental run stand down for many days in a row -- that must never
    # read as the no-vpn "corpus has stopped growing" streak alarm.
    sandbox.seed_telegram_skip_history(
        ("2026-08-17T06:17:01+00:00", False),
        ("2026-08-18T06:17:02+00:00", False),
        ("2026-08-19T06:17:03+00:00", False),
        ("2026-08-20T06:17:04+00:00", False),
    )
    sandbox.write_healthy_bluesky_heartbeat()
    sandbox.write_telegram_heartbeat(
        age_seconds=_TELEGRAM_FRESH,
        ts="2026-08-21T06:17:05+00:00",
        mode="telegram-incremental",
        exit=3,
        ok_channels=0,
        failed_channels=0,
        skipped="locked",
    )
    result = sandbox.run(WATCHDOG)
    assert result.returncode == 0, f"{result.stdout}\n{result.stderr}"
    assert "consecutive" not in sandbox.notifications.lower(), sandbox.notifications
    assert "stopped growing" not in sandbox.notifications.lower(), sandbox.notifications


def test_telegram_failed_channels_warns_with_the_count(sandbox):
    sandbox.write_healthy_bluesky_heartbeat()
    sandbox.write_telegram_heartbeat(
        age_seconds=_TELEGRAM_FRESH,
        ts="2026-08-21T06:17:03+00:00",
        mode="telegram-incremental",
        exit=0,
        ok_channels=3,
        failed_channels=2,
    )
    result = sandbox.run(WATCHDOG)
    assert result.returncode == 1, f"{result.stdout}\n{result.stderr}"
    assert "2" in sandbox.notifications
    assert "failed" in sandbox.notifications.lower(), sandbox.notifications
    assert "Telegram" in sandbox.notifications


def test_a_telegram_problem_does_not_mask_a_bluesky_problem_and_vice_versa(sandbox):
    """Both signals must surface together — neither side may swallow the other."""
    sandbox.write_heartbeat(
        age_seconds=_TELEGRAM_FRESH,
        finishedAt="2026-08-21T02:11:00Z",
        scrapeExit=2,
        sentimentExit=0,
        stoppedAtDeadline=False,
        sentimentSkipped=False,
        log=str(sandbox.log_dir / "nightly_x.log"),
    )
    sandbox.age_store(_TELEGRAM_FRESH)
    sandbox.write_telegram_heartbeat(
        age_seconds=_TELEGRAM_FRESH,
        ts="2026-08-21T06:17:03+00:00",
        mode="telegram-incremental",
        exit=0,
        ok_channels=3,
        failed_channels=2,
    )
    result = sandbox.run(WATCHDOG)
    assert result.returncode == 1, f"{result.stdout}\n{result.stderr}"
    assert "BlueX nightly failing" in sandbox.notifications
    assert "scrape (exit 2)" in sandbox.notifications
    assert "Telegram" in sandbox.notifications
    assert "failed" in sandbox.notifications.lower()
