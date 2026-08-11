"""Cool-down pacing for multi-hour corpus passes — spares the hardware.

WHY THIS EXISTS
----------------
`score_corpus.py` runs the local GPU (MPS) flat-out for hours at a time.
`BlueX/Data/LLMPace.swift` already solved this exact problem for the Swift
LLM-annotation pass: "Longer pauses between posts let the Apple Silicon SoC
cool, drop fan noise, and avoid thermal throttling on multi-hour runs." This
module follows that precedent rather than inventing a new scheme, adapted to
Python's batch-oriented scoring loop instead of Swift's per-post loop.

TWO INDEPENDENT LAYERS
------------------------
  1. **Unconditional duty cycle.** After every `work_seconds` of elapsed
     scoring time, sleep `cool_seconds` regardless of what any sensor says.
     This guarantees periodic cooling even on a machine whose thermal state
     never reports anything interesting (measured here: `nominal`
     throughout a 2026-08-11 run). Defaults: 60s work / 5s cool (~8%
     throughput cost).
  2. **Thermal-aware escalation.** `LLMPace.swift`'s `ThermalBackoff` maps
     `ProcessInfo.ThermalState` to an extra delay:

         nominal, fair -> 0s
         serious       -> 3s
         critical      -> 10s

     `THERMAL_BACKOFF_SECONDS` below mirrors that table exactly. Polled
     roughly every `thermal_poll_seconds` (default 30s) via a *compiled*
     Swift helper (see `ensure_thermal_helper`) — never `swift <file>`
     interpreted per poll, which costs ~0.9s each time; the compiled binary
     answers in ~0.4s and is built once and cached.

FAILURE MODE — READ BEFORE CHANGING
--------------------------------------
A thermal read failure (helper missing, `swiftc` unavailable, compile
error, timeout, unexpected stdout) must NEVER abort a multi-hour scoring
run, and must NEVER silently disable the unconditional duty cycle too — the
two layers are independent on purpose. `Pacer` degrades to duty-cycle-only
pacing in that case and logs the fallback exactly once, not on every poll.

`--cool-seconds 0` is the one thing that disables ALL pacing (duty cycle
and thermal escalation both), for anyone who wants to run flat-out anyway.
"""
import os
import subprocess
import time

# Mirrors BlueX/Data/LLMPace.swift's ThermalBackoff table exactly. Do not
# retune independently of that file — they describe the same hardware.
THERMAL_BACKOFF_SECONDS = {
    "nominal": 0.0,
    "fair": 0.0,
    "serious": 3.0,
    "critical": 10.0,
    "unknown": 0.0,
    None: 0.0,
}

VALID_THERMAL_STATES = ("nominal", "fair", "serious", "critical", "unknown")

DEFAULT_WORK_SECONDS = 60.0
DEFAULT_COOL_SECONDS = 5.0
DEFAULT_THERMAL_POLL_SECONDS = 30.0
DEFAULT_HELPER_TIMEOUT_SECONDS = 2.0
DEFAULT_COMPILE_TIMEOUT_SECONDS = 60.0

THERMAL_HELPER_SOURCE = """\
import Foundation
let s = ProcessInfo.processInfo.thermalState
switch s {
case .nominal: print("nominal")
case .fair: print("fair")
case .serious: print("serious")
case .critical: print("critical")
@unknown default: print("unknown")
}
"""

DEFAULT_HELPER_CACHE_DIR = os.environ.get(
    "BLUEX_THERMAL_HELPER_DIR", os.path.expanduser("~/.cache/bluex-incivility")
)
DEFAULT_HELPER_PATH = os.path.join(DEFAULT_HELPER_CACHE_DIR, "thermal_state")


def ensure_thermal_helper(cache_dir=DEFAULT_HELPER_CACHE_DIR,
                           binary_path=None,
                           compile_timeout=DEFAULT_COMPILE_TIMEOUT_SECONDS):
    """Compile the Swift thermal-state helper once and cache the binary.

    Returns the path to a working compiled binary, or None if `swiftc` is
    unavailable, compilation fails, or any step errors. Never raises — a
    missing compiler is an expected, reportable outcome (e.g. Linux CI),
    not a bug.
    """
    binary_path = binary_path or DEFAULT_HELPER_PATH
    if os.path.exists(binary_path):
        return binary_path

    try:
        os.makedirs(cache_dir, exist_ok=True)
        src_path = os.path.join(cache_dir, "thermal_state.swift")
        with open(src_path, "w", encoding="utf-8") as handle:
            handle.write(THERMAL_HELPER_SOURCE)
        result = subprocess.run(
            ["swiftc", "-O", src_path, "-o", binary_path],
            capture_output=True, timeout=compile_timeout,
        )
        if result.returncode != 0 or not os.path.exists(binary_path):
            return None
    except Exception:  # noqa: BLE001 - a failed compile degrades pacing, not the run
        return None
    return binary_path


def read_thermal_state(helper_path, timeout=DEFAULT_HELPER_TIMEOUT_SECONDS):
    """Run the compiled helper once; return one of VALID_THERMAL_STATES, or
    None on any failure (missing binary, timeout, nonzero exit, bad output).
    Never raises.
    """
    if not helper_path:
        return None
    try:
        result = subprocess.run(
            [helper_path], capture_output=True, timeout=timeout, text=True,
        )
        if result.returncode != 0:
            return None
        state = result.stdout.strip()
        if state not in VALID_THERMAL_STATES:
            return None
        return state
    except Exception:  # noqa: BLE001 - a bad read degrades pacing, not the run
        return None


class Pacer:
    """Applies duty-cycle and thermal-escalation cool-downs to a scoring loop.

    Call `maybe_pace()` once per batch (success or failure — cooling the
    hardware doesn't care which). It never touches progress/resume state;
    callers must mark progress before calling this, so a sleep here can
    never corrupt or double-count it.
    """

    def __init__(self, work_seconds=DEFAULT_WORK_SECONDS, cool_seconds=DEFAULT_COOL_SECONDS,
                 thermal_poll_seconds=DEFAULT_THERMAL_POLL_SECONDS,
                 helper_path=None, thermal_reader=read_thermal_state,
                 clock=time.monotonic, sleep_fn=time.sleep, log=print,
                 resolve_helper=True):
        self.work_seconds = work_seconds
        self.cool_seconds = cool_seconds
        self.thermal_poll_seconds = thermal_poll_seconds
        self.thermal_reader = thermal_reader
        self.clock = clock
        self.sleep_fn = sleep_fn
        self.log = log

        self.total_cool_seconds = 0.0
        self.duty_cycle_triggers = 0
        self.thermal_escalations = {"serious": 0, "critical": 0}

        self._current_thermal_state = None
        self._helper_fallback_logged = False

        self._work_start = clock()
        self._last_thermal_poll = clock()

        self.enabled = cool_seconds > 0
        self.helper_path = helper_path
        if self.enabled and self.helper_path is None and resolve_helper:
            try:
                self.helper_path = ensure_thermal_helper()
            except Exception:  # noqa: BLE001 - see module docstring
                self.helper_path = None
        if self.enabled and self.helper_path is None:
            self._log_helper_fallback()

    def _log_helper_fallback(self):
        if not self._helper_fallback_logged:
            self.log(
                "[pacing] thermal state unavailable (helper missing/failed) — "
                "falling back to duty-cycle-only pacing"
            )
            self._helper_fallback_logged = True

    def _poll_thermal_state_if_due(self, now):
        if not self.helper_path:
            return
        if (now - self._last_thermal_poll) < self.thermal_poll_seconds:
            return
        self._last_thermal_poll = now
        state = self.thermal_reader(self.helper_path)
        if state is None:
            self._log_helper_fallback()
            return
        self._current_thermal_state = state

    def maybe_pace(self):
        """Call once per batch. Sleeps as needed; updates counters. No-op
        entirely if cool_seconds <= 0 (--cool-seconds 0 disables all
        pacing, duty cycle and thermal escalation alike)."""
        if not self.enabled:
            return

        now = self.clock()
        self._poll_thermal_state_if_due(now)

        extra = THERMAL_BACKOFF_SECONDS.get(self._current_thermal_state, 0.0)
        elevated = extra > 0
        if elevated:
            self.log(
                "[pacing] thermal state=%s -> +%.0fs cool-down"
                % (self._current_thermal_state, extra)
            )
            self.thermal_escalations[self._current_thermal_state] = (
                self.thermal_escalations.get(self._current_thermal_state, 0) + 1
            )

        duty_due = (now - self._work_start) >= self.work_seconds
        if duty_due:
            total_sleep = self.cool_seconds + extra
            self.sleep_fn(total_sleep)
            self.total_cool_seconds += total_sleep
            self.duty_cycle_triggers += 1
            self._work_start = self.clock()
        elif elevated:
            # Thermal escalation is additive and independent of the duty
            # cycle's own schedule — a hot machine gets relief immediately,
            # not only when the duty cycle happens to fire.
            self.sleep_fn(extra)
            self.total_cool_seconds += extra

    def summary(self):
        return {
            "pacing_enabled": self.enabled,
            "work_seconds": self.work_seconds,
            "cool_seconds": self.cool_seconds,
            "thermal_helper_available": bool(self.helper_path),
            "cooling_total_seconds": self.total_cool_seconds,
            "duty_cycle_triggers": self.duty_cycle_triggers,
            "thermal_escalations": dict(self.thermal_escalations),
        }
