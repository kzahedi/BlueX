"""Tests for pacing.py. No real sleeping, no real swiftc invocation: the
clock, sleep_fn, and thermal reader/helper-path are all injected fakes."""
import unittest

import pacing


class FakeClock:
    """A monotonic clock you advance by hand."""

    def __init__(self, start=0.0):
        self.now = start

    def __call__(self):
        return self.now

    def advance(self, seconds):
        self.now += seconds


class RecordingSleep:
    def __init__(self):
        self.calls = []

    def __call__(self, seconds):
        self.calls.append(seconds)

    @property
    def total(self):
        return sum(self.calls)


class DutyCycleTests(unittest.TestCase):
    def test_no_sleep_before_work_seconds_elapsed(self):
        clock = FakeClock()
        sleep = RecordingSleep()
        pacer = pacing.Pacer(
            work_seconds=60, cool_seconds=5, helper_path=None,
            clock=clock, sleep_fn=sleep, resolve_helper=False, log=lambda *a: None,
        )
        clock.advance(30)
        pacer.maybe_pace()
        self.assertEqual(sleep.calls, [])
        self.assertEqual(pacer.duty_cycle_triggers, 0)

    def test_sleeps_cool_seconds_once_work_seconds_elapsed(self):
        clock = FakeClock()
        sleep = RecordingSleep()
        pacer = pacing.Pacer(
            work_seconds=60, cool_seconds=5, helper_path=None,
            clock=clock, sleep_fn=sleep, resolve_helper=False, log=lambda *a: None,
        )
        clock.advance(61)
        pacer.maybe_pace()
        self.assertEqual(sleep.calls, [5])
        self.assertEqual(pacer.duty_cycle_triggers, 1)
        self.assertEqual(pacer.total_cool_seconds, 5)

    def test_triggers_repeatedly_over_a_long_run(self):
        clock = FakeClock()
        sleep = RecordingSleep()
        pacer = pacing.Pacer(
            work_seconds=60, cool_seconds=5, helper_path=None,
            clock=clock, sleep_fn=sleep, resolve_helper=False, log=lambda *a: None,
        )
        # Simulate ~10 minutes of batches, one every 10s of wall time.
        for _ in range(60):
            clock.advance(10)
            pacer.maybe_pace()
        # ~600s of elapsed time / 60s work window => ~10 duty-cycle triggers.
        self.assertGreaterEqual(pacer.duty_cycle_triggers, 8)
        self.assertLessEqual(pacer.duty_cycle_triggers, 11)
        self.assertEqual(pacer.total_cool_seconds, pacer.duty_cycle_triggers * 5)

    def test_cool_seconds_zero_disables_all_pacing(self):
        clock = FakeClock()
        sleep = RecordingSleep()
        pacer = pacing.Pacer(
            work_seconds=60, cool_seconds=0, helper_path=None,
            clock=clock, sleep_fn=sleep, resolve_helper=False, log=lambda *a: None,
        )
        self.assertFalse(pacer.enabled)
        clock.advance(1000)
        pacer.maybe_pace()
        self.assertEqual(sleep.calls, [])
        self.assertEqual(pacer.duty_cycle_triggers, 0)
        self.assertEqual(pacer.total_cool_seconds, 0)

    def test_cool_seconds_zero_never_touches_thermal_helper(self):
        clock = FakeClock()
        sleep = RecordingSleep()
        calls = {"n": 0}

        def reader(helper_path, timeout=2.0):
            calls["n"] += 1
            return "critical"

        pacer = pacing.Pacer(
            work_seconds=60, cool_seconds=0, helper_path="/bin/true",
            clock=clock, sleep_fn=sleep, thermal_reader=reader,
            resolve_helper=False, log=lambda *a: None,
        )
        clock.advance(1000)
        pacer.maybe_pace()
        self.assertEqual(calls["n"], 0)


class ThermalEscalationTests(unittest.TestCase):
    def _pacer(self, clock, sleep, reader, thermal_poll_seconds=30):
        return pacing.Pacer(
            work_seconds=60, cool_seconds=5, helper_path="/fake/helper",
            thermal_poll_seconds=thermal_poll_seconds,
            clock=clock, sleep_fn=sleep, thermal_reader=reader,
            resolve_helper=False, log=lambda *a: None,
        )

    def test_serious_state_adds_extra_delay(self):
        clock = FakeClock()
        sleep = RecordingSleep()
        reader = lambda helper_path, timeout=2.0: "serious"
        pacer = self._pacer(clock, sleep, reader)

        clock.advance(31)  # past the 30s poll interval, under the 60s work window
        pacer.maybe_pace()

        self.assertEqual(sleep.calls, [3.0])
        self.assertEqual(pacer.thermal_escalations["serious"], 1)
        self.assertEqual(pacer.thermal_escalations["critical"], 0)

    def test_critical_state_adds_larger_extra_delay(self):
        clock = FakeClock()
        sleep = RecordingSleep()
        reader = lambda helper_path, timeout=2.0: "critical"
        pacer = self._pacer(clock, sleep, reader)

        clock.advance(31)
        pacer.maybe_pace()

        self.assertEqual(sleep.calls, [10.0])
        self.assertEqual(pacer.thermal_escalations["critical"], 1)

    def test_nominal_state_adds_nothing(self):
        clock = FakeClock()
        sleep = RecordingSleep()
        reader = lambda helper_path, timeout=2.0: "nominal"
        pacer = self._pacer(clock, sleep, reader)

        clock.advance(31)
        pacer.maybe_pace()

        self.assertEqual(sleep.calls, [])
        self.assertEqual(pacer.thermal_escalations["serious"], 0)
        self.assertEqual(pacer.thermal_escalations["critical"], 0)

    def test_thermal_extra_stacks_on_top_of_duty_cycle_sleep(self):
        clock = FakeClock()
        sleep = RecordingSleep()
        reader = lambda helper_path, timeout=2.0: "critical"
        pacer = self._pacer(clock, sleep, reader)

        clock.advance(61)  # past both the 30s poll and the 60s work window
        pacer.maybe_pace()

        # One combined sleep of cool_seconds + thermal extra, not two calls.
        self.assertEqual(sleep.calls, [5.0 + 10.0])
        self.assertEqual(pacer.duty_cycle_triggers, 1)
        self.assertEqual(pacer.thermal_escalations["critical"], 1)

    def test_poll_only_happens_at_the_configured_interval(self):
        clock = FakeClock()
        sleep = RecordingSleep()
        calls = {"n": 0}

        def reader(helper_path, timeout=2.0):
            calls["n"] += 1
            return "nominal"

        pacer = self._pacer(clock, sleep, reader, thermal_poll_seconds=30)

        # Six calls of 5s each: nothing reaches the 30s poll interval until
        # the last one, so only one real poll should have happened.
        for _ in range(6):
            clock.advance(5)
            pacer.maybe_pace()
        self.assertEqual(calls["n"], 1)

        # Crossing the next 30s boundary triggers exactly one more poll.
        clock.advance(30)
        pacer.maybe_pace()
        self.assertEqual(calls["n"], 2)


class HelperFallbackTests(unittest.TestCase):
    def test_missing_helper_falls_back_to_duty_cycle_only_without_raising(self):
        clock = FakeClock()
        sleep = RecordingSleep()
        logged = []
        pacer = pacing.Pacer(
            work_seconds=60, cool_seconds=5, helper_path=None,
            clock=clock, sleep_fn=sleep, resolve_helper=False,
            log=logged.append,
        )
        # Constructing with no helper_path and resolve_helper=False leaves
        # helper_path None -> fallback logged once at construction.
        self.assertTrue(any("duty-cycle-only" in msg for msg in logged))

        clock.advance(61)
        pacer.maybe_pace()  # must not raise
        self.assertEqual(sleep.calls, [5])  # duty cycle still works

    def test_thermal_reader_returning_none_falls_back_without_raising(self):
        clock = FakeClock()
        sleep = RecordingSleep()
        logged = []

        def failing_reader(helper_path, timeout=2.0):
            return None

        pacer = pacing.Pacer(
            work_seconds=60, cool_seconds=5, helper_path="/fake/helper",
            thermal_poll_seconds=30, clock=clock, sleep_fn=sleep,
            thermal_reader=failing_reader, resolve_helper=False,
            log=logged.append,
        )
        clock.advance(31)
        pacer.maybe_pace()  # must not raise

        self.assertTrue(any("duty-cycle-only" in msg for msg in logged))
        # Duty cycle window (60s) hasn't elapsed yet, so no sleep expected
        # from this call, but nothing crashed and no phantom escalation
        # was recorded.
        self.assertEqual(pacer.thermal_escalations, {"serious": 0, "critical": 0})

    def test_helper_fallback_logged_only_once(self):
        clock = FakeClock()
        sleep = RecordingSleep()
        logged = []

        def failing_reader(helper_path, timeout=2.0):
            return None

        pacer = pacing.Pacer(
            work_seconds=10, cool_seconds=5, helper_path="/fake/helper",
            thermal_poll_seconds=10, clock=clock, sleep_fn=sleep,
            thermal_reader=failing_reader, resolve_helper=False,
            log=logged.append,
        )
        for _ in range(5):
            clock.advance(11)
            pacer.maybe_pace()

        fallback_msgs = [m for m in logged if "duty-cycle-only" in m]
        self.assertEqual(len(fallback_msgs), 1)

    def test_ensure_thermal_helper_returns_none_on_missing_compiler(self):
        # Point at a directory and a fake swiftc-less environment by using a
        # bogus cache dir under a nonexistent binary name; the real
        # ensure_thermal_helper degrades to None rather than raising when
        # compilation fails for any reason.
        result = pacing.ensure_thermal_helper(
            cache_dir="/nonexistent/path/that/should/not/be/writable/xyz",
            binary_path="/nonexistent/path/that/should/not/be/writable/xyz/bin",
        )
        self.assertIsNone(result)

    def test_read_thermal_state_returns_none_for_missing_binary(self):
        result = pacing.read_thermal_state("/no/such/helper/binary")
        self.assertIsNone(result)

    def test_read_thermal_state_returns_none_for_bad_output(self):
        # /bin/echo prints something that isn't a valid thermal state.
        result = pacing.read_thermal_state("/bin/echo")
        self.assertIsNone(result)


class SummaryTests(unittest.TestCase):
    def test_summary_reports_zero_escalations_when_nominal_throughout(self):
        clock = FakeClock()
        sleep = RecordingSleep()
        reader = lambda helper_path, timeout=2.0: "nominal"
        pacer = pacing.Pacer(
            work_seconds=60, cool_seconds=5, helper_path="/fake/helper",
            clock=clock, sleep_fn=sleep, thermal_reader=reader,
            resolve_helper=False, log=lambda *a: None,
        )
        for _ in range(10):
            clock.advance(30)
            pacer.maybe_pace()

        summary = pacer.summary()
        self.assertEqual(summary["thermal_escalations"], {"serious": 0, "critical": 0})
        self.assertTrue(summary["thermal_helper_available"])
        self.assertGreater(summary["duty_cycle_triggers"], 0)

    def test_summary_reflects_disabled_pacing(self):
        pacer = pacing.Pacer(cool_seconds=0, resolve_helper=False, log=lambda *a: None)
        summary = pacer.summary()
        self.assertFalse(summary["pacing_enabled"])
        self.assertEqual(summary["cooling_total_seconds"], 0.0)


if __name__ == "__main__":
    unittest.main()
