"""Guards against the fault that caused the 2026-06-04 outage.

launchd was told to run the job scripts from /Volumes/Eregion — an external
volume that is not mounted during DarkWake — so every run died with
"can't open input file" and exit 127, silently, for 61 days.

The store data was later moved onto that same volume deliberately, so the rule is
not "no /Volumes anywhere". It is: the DATA may live there, the CODE may not.
"""

import os
import plistlib
import subprocess
from pathlib import Path

import pytest

JOBS_SRC = Path(__file__).parent
RUNTIME_SCRIPTS = [
    "lib-bluex-job.sh",
    "bluex-nightly.sh",
    "bluex-watchdog.sh",
]
AGENTS_DIR = Path.home() / "Library/LaunchAgents"
NIGHTLY_PLIST = AGENTS_DIR / "net.pulsschlag.bluex.nightly.plist"
WATCHDOG_PLIST = AGENTS_DIR / "net.pulsschlag.bluex.watchdog.plist"


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


@pytest.mark.parametrize("plist_path", [NIGHTLY_PLIST, WATCHDOG_PLIST])
def test_installed_agent_points_at_an_existing_internal_script(plist_path):
    if not plist_path.exists():
        pytest.skip(f"{plist_path.name} not installed — run tools/install-jobs.sh")
    with plist_path.open("rb") as handle:
        data = plistlib.load(handle)
    script = data["ProgramArguments"][-1]
    assert "/Volumes" not in script, f"points at an external volume: {script}"
    assert os.path.exists(script), f"points at a missing script: {script}"


def test_superseded_agents_are_removed():
    if not NIGHTLY_PLIST.exists():
        pytest.skip("new agents not installed yet — run tools/install-jobs.sh")
    for old in ("net.pulsschlag.bluex.scrape", "net.pulsschlag.bluex.annotate"):
        assert not (
            AGENTS_DIR / f"{old}.plist"
        ).exists(), f"{old}.plist should have been removed by install-jobs.sh"
