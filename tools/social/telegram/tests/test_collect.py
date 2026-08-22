import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

from tools.social.telegram.preview import NoPreviewError
from tools.social.telegram.single_instance import single_instance

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[4]


def page_html(channel, ids):
    """Minimal t.me/s-shaped HTML the parser accepts."""
    msgs = "".join(
        f'<div class="tgme_widget_message" data-post="{channel}/{i}">'
        f'<div class="tgme_widget_message_text">msg {i}</div>'
        f'<span class="tgme_widget_message_views">5</span>'
        f'<a class="tgme_widget_message_date" href="https://t.me/{channel}/{i}">'
        f'<time datetime="2026-08-01T10:00:{i % 60:02d}+00:00"></time></a></div>'
        for i in ids)
    return f'<html><body class="tgme_widget_message_wrap">{msgs}</body></html>'


def make_fake_fetch(channel, all_ids, calls=None):
    """Serves pages of 5 ids, newest first, honouring ?before like t.me/s."""
    def fetch(username, before):
        if calls is not None:
            calls.append(before)
        older = sorted(i for i in all_ids if before is None or i < before)
        page = older[-5:]
        return page_html(channel, page)
    return fetch


class TestCollect(unittest.TestCase):
    def setUp(self):
        from tools.social.telegram.store import open_db
        self.conn = open_db(":memory:")
        self.conn.execute("INSERT INTO channels(username, status) "
                          "VALUES ('chan', 'seed_approved')")
        self.conn.commit()

    def test_backfill_walks_to_start_and_clears_cursor(self):
        from tools.social.telegram.collect import collect_channel
        from tools.social.telegram.store import get_cursor
        fetch = make_fake_fetch("chan", list(range(1, 14)))
        r = collect_channel(self.conn, "chan", fetch, mode="backfill")
        self.assertEqual(r["status"], "complete")
        self.assertEqual(r["new_messages"], 13)
        self.assertIsNone(get_cursor(self.conn, "chan"))

    def test_backfill_resumes_from_cursor(self):
        from tools.social.telegram.collect import collect_channel
        from tools.social.telegram.store import set_cursor
        calls = []
        fetch = make_fake_fetch("chan", list(range(1, 14)), calls)
        set_cursor(self.conn, "chan", 6)   # simulate a crash mid-history
        collect_channel(self.conn, "chan", fetch, mode="backfill")
        self.assertEqual(calls[0], 6)      # resumed, not restarted

    def test_no_preview_is_recorded_failure_not_crash(self):
        from tools.social.telegram.collect import collect_channel
        def fetch(username, before):
            raise NoPreviewError("chan: no public web preview")
        r = collect_channel(self.conn, "chan", fetch, mode="backfill")
        self.assertEqual(r["status"], "failed")
        self.assertIn("no public web preview", r["failure_reason"])

    def test_run_ok_requires_every_channel_accounted_for(self):
        from tools.social.telegram.collect import run
        self.conn.execute("INSERT INTO channels(username, status) "
                          "VALUES ('dead', 'seed_approved')")
        good = make_fake_fetch("chan", [1, 2, 3])
        def fetch(username, before):
            if username == "dead":
                raise NoPreviewError("dead: no public web preview")
            return good(username, before)
        report = run(self.conn, fetch, mode="backfill")
        self.assertTrue(report["ok"])      # failed-with-reason counts as accounted
        statuses = {c["channel"]: c["status"] for c in report["channels"]}
        self.assertEqual(statuses, {"chan": "complete", "dead": "failed"})

    def test_unapproved_channels_never_collected(self):
        from tools.social.telegram.collect import run
        self.conn.execute("INSERT INTO channels(username, status) "
                          "VALUES ('pendingchan', 'seed_pending')")
        fetch = make_fake_fetch("chan", [1, 2])
        report = run(self.conn, fetch, mode="backfill")
        self.assertNotIn("pendingchan", [c["channel"] for c in report["channels"]])

    def test_backfill_stagnation_is_recorded_failure_not_infinite_loop(self):
        from tools.social.telegram.collect import collect_channel

        def fetch(username, before):
            # Always the same page regardless of `before` — e.g. a CDN glitch
            # or an ignored ?before param. oldest stays > 1 forever.
            return page_html("chan", [5, 6, 7, 8, 9])

        r = collect_channel(self.conn, "chan", fetch, mode="backfill")
        self.assertEqual(r["status"], "failed")
        self.assertIn("no progress", r["failure_reason"])

    def test_budget_exhausted_still_records_coverage(self):
        from tools.social.telegram.collect import collect_channel
        fetch = make_fake_fetch("chan", list(range(1, 14)))
        r = collect_channel(self.conn, "chan", fetch, mode="backfill",
                            max_pages=1)
        self.assertEqual(r["status"], "failed")
        rows = self.conn.execute(
            "SELECT COUNT(*) FROM coverage WHERE channel='chan'").fetchone()
        self.assertGreater(rows[0], 0)

    def test_vpn_not_active_error_from_fetch_is_recorded_not_crash(self):
        # F2: fetch_page itself may raise VPNNotActiveError at the network
        # boundary (e.g. VPN dropped between the per-page check and the
        # actual HTTP call). collect_channel must record this as a failure,
        # not let it propagate as a crash.
        from tools.social.telegram.collect import collect_channel
        from tools.social.telegram.vpn_gate import VPNNotActiveError

        def fetch(username, before):
            raise VPNNotActiveError("ProtonVPN not active — refusing to "
                                    "contact Telegram")

        # record_coverage() is still called (never let a coverage error mask
        # the real failure reason) -- it simply has nothing to record since
        # no page ever succeeded, same as the NoPreviewError path above.
        r = collect_channel(self.conn, "chan", fetch, mode="backfill")
        self.assertEqual(r["status"], "failed")
        self.assertEqual(r["failure_reason"], "aborted: ProtonVPN not active")
        self.assertEqual(r["new_messages"], 0)

    def test_vpn_check_none_behaves_exactly_as_before(self):
        from tools.social.telegram.collect import run
        fetch = make_fake_fetch("chan", [1, 2, 3])
        report = run(self.conn, fetch, mode="backfill", vpn_check=None)
        self.assertTrue(report["ok"])
        statuses = {c["channel"]: c["status"] for c in report["channels"]}
        self.assertEqual(statuses, {"chan": "complete"})

    def test_per_page_vpn_check_stops_mid_walk_no_further_fetch(self):
        # F1: a mid-channel VPN drop must be caught within a single
        # channel's page loop, not only between channels.
        from tools.social.telegram.collect import collect_channel
        from tools.social.telegram.store import get_cursor

        fetch_calls = []

        def fetch(username, before):
            fetch_calls.append(before)
            return make_fake_fetch("chan", list(range(1, 14)))(username, before)

        vpn_states = [True, True, False]

        def vpn_check():
            return vpn_states.pop(0)

        r = collect_channel(self.conn, "chan", fetch, mode="backfill",
                            vpn_check=vpn_check)

        self.assertEqual(r["status"], "failed")
        self.assertEqual(r["failure_reason"], "aborted: ProtonVPN not active")
        # Only 2 pages were fetched before the abort on page 3's check.
        self.assertEqual(len(fetch_calls), 2)
        # Messages from the two completed pages were retained.
        self.assertEqual(r["new_messages"], 10)
        rows = self.conn.execute(
            "SELECT COUNT(*) FROM messages WHERE channel='chan'").fetchone()
        self.assertEqual(rows[0], 10)
        # Coverage was recorded for the aborted channel, same as other
        # failure paths.
        cov = self.conn.execute(
            "SELECT COUNT(*) FROM coverage WHERE channel='chan'").fetchone()
        self.assertGreater(cov[0], 0)
        # A cursor was NOT cleared (the walk is incomplete, must resume).
        self.assertIsNotNone(get_cursor(self.conn, "chan"))

    def test_vpn_check_aborts_remaining_channels_when_it_goes_false(self):
        from tools.social.telegram.collect import run
        self.conn.execute("INSERT INTO channels(username, status) "
                          "VALUES ('chan2', 'seed_approved')")
        self.conn.commit()

        fetch_calls = []

        def fetch(username, before):
            fetch_calls.append(username)
            return make_fake_fetch(username, [1, 2, 3])(username, before)

        vpn_states = [True, False]

        def vpn_check():
            return vpn_states.pop(0)

        report = run(self.conn, fetch, mode="backfill", vpn_check=vpn_check)
        statuses = {c["channel"]: c["status"] for c in report["channels"]}
        reasons = {c["channel"]: c["failure_reason"]
                   for c in report["channels"]}
        self.assertEqual(statuses, {"chan": "complete", "chan2": "failed"})
        self.assertEqual(reasons["chan2"],
                          "aborted: ProtonVPN not active")
        # chan2's fetch must never have been invoked once VPN dropped.
        self.assertNotIn("chan2", fetch_calls)
        self.assertIn("chan", fetch_calls)
        self.assertTrue(report["ok"])  # failed-with-reason = accounted


class TestBackfillCompletionSkip(unittest.TestCase):
    """A backfill run must not re-walk a channel that a previous backfill
    already completed -- the completion marker is the signal, not the
    absence of a cursor."""

    def setUp(self):
        from tools.social.telegram.store import open_db
        self.conn = open_db(":memory:")
        self.conn.execute("INSERT INTO channels(username, status) "
                          "VALUES ('chan', 'seed_approved')")
        self.conn.commit()

    def test_completed_channel_with_no_cursor_is_skipped_no_fetch(self):
        from tools.social.telegram.collect import collect_channel
        from tools.social.telegram.store import mark_backfill_complete

        mark_backfill_complete(self.conn, "chan")

        calls = []
        def fetch(username, before):
            calls.append((username, before))
            raise AssertionError("fetch must never be called for a "
                                  "completed channel with no cursor")

        r = collect_channel(self.conn, "chan", fetch, mode="backfill")

        self.assertEqual(calls, [])
        self.assertEqual(r["status"], "complete")
        self.assertEqual(r["new_messages"], 0)
        self.assertIsNone(r["failure_reason"])
        self.assertEqual(r["skipped"], "already-backfilled")

    def test_interrupted_channel_still_resumes_despite_stale_marker(self):
        # A channel that was already marked complete once, then got a
        # cursor from a later (interrupted) re-walk, must still resume --
        # the presence of a cursor means the walk is not finished.
        from tools.social.telegram.collect import collect_channel
        from tools.social.telegram.store import (mark_backfill_complete,
                                                  set_cursor, get_cursor)

        mark_backfill_complete(self.conn, "chan")
        set_cursor(self.conn, "chan", 6)

        calls = []
        fetch = make_fake_fetch("chan", list(range(1, 14)), calls)
        r = collect_channel(self.conn, "chan", fetch, mode="backfill")

        self.assertGreater(len(calls), 0)
        self.assertEqual(calls[0], 6)
        self.assertNotIn("skipped", r)
        self.assertEqual(r["status"], "complete")
        self.assertIsNone(get_cursor(self.conn, "chan"))

    def test_never_backfilled_channel_is_not_skipped(self):
        from tools.social.telegram.collect import collect_channel
        fetch = make_fake_fetch("chan", [1, 2, 3])
        r = collect_channel(self.conn, "chan", fetch, mode="backfill")
        self.assertNotIn("skipped", r)
        self.assertEqual(r["status"], "complete")

    def test_completing_a_backfill_writes_the_marker(self):
        from tools.social.telegram.collect import collect_channel
        from tools.social.telegram.store import backfill_completed_at
        fetch = make_fake_fetch("chan", [1, 2, 3])
        collect_channel(self.conn, "chan", fetch, mode="backfill")
        self.assertIsNotNone(backfill_completed_at(self.conn, "chan"))

    def test_force_backfill_rewalks_a_completed_channel(self):
        from tools.social.telegram.collect import collect_channel
        from tools.social.telegram.store import mark_backfill_complete

        mark_backfill_complete(self.conn, "chan")
        calls = []
        fetch = make_fake_fetch("chan", list(range(1, 14)), calls)

        r = collect_channel(self.conn, "chan", fetch, mode="backfill",
                            force=True)

        self.assertGreater(len(calls), 0)
        self.assertNotIn("skipped", r)
        self.assertEqual(r["status"], "complete")
        self.assertEqual(r["new_messages"], 13)

    def test_run_reconciliation_ok_unaffected_by_skip(self):
        from tools.social.telegram.collect import run
        from tools.social.telegram.store import mark_backfill_complete

        mark_backfill_complete(self.conn, "chan")
        fetch = make_fake_fetch("chan", [1, 2, 3])
        report = run(self.conn, fetch, mode="backfill")
        self.assertTrue(report["ok"])
        statuses = {c["channel"]: c["status"] for c in report["channels"]}
        self.assertEqual(statuses, {"chan": "complete"})
        self.assertEqual(report["channels"][0]["skipped"], "already-backfilled")

    def test_run_force_flag_rewalks_completed_channels(self):
        from tools.social.telegram.collect import run
        from tools.social.telegram.store import mark_backfill_complete

        mark_backfill_complete(self.conn, "chan")
        calls = []
        fetch = make_fake_fetch("chan", [1, 2, 3], calls)
        report = run(self.conn, fetch, mode="backfill", force=True)
        self.assertGreater(len(calls), 0)
        self.assertNotIn("skipped", report["channels"][0])


class TestIncrementalModeUnaffectedByMarker(unittest.TestCase):
    def setUp(self):
        from tools.social.telegram.store import open_db, upsert_messages
        self.conn = open_db(":memory:")
        self.conn.execute("INSERT INTO channels(username, status) "
                          "VALUES ('chan', 'seed_approved')")
        self.conn.commit()
        # Incremental now requires existing history (finding I1's fix,
        # requirement 2) -- pre-seed msg_id 1 so these marker-focused tests
        # aren't about the no-history precondition at all.
        upsert_messages(self.conn, [make_msg(1)])

    def test_incremental_never_reads_or_writes_the_marker(self):
        from tools.social.telegram.collect import collect_channel
        from tools.social.telegram.store import backfill_completed_at

        self.assertIsNone(backfill_completed_at(self.conn, "chan"))
        fetch = make_fake_fetch("chan", [1, 2, 3])
        r = collect_channel(self.conn, "chan", fetch, mode="incremental")
        self.assertEqual(r["status"], "complete")
        self.assertNotIn("skipped", r)
        # incremental never writes the marker even on a clean completion
        self.assertIsNone(backfill_completed_at(self.conn, "chan"))

    def test_incremental_still_fetches_even_when_marker_already_set(self):
        from tools.social.telegram.collect import collect_channel
        from tools.social.telegram.store import mark_backfill_complete

        mark_backfill_complete(self.conn, "chan")
        calls = []
        fetch = make_fake_fetch("chan", [1, 2, 3], calls)
        r = collect_channel(self.conn, "chan", fetch, mode="incremental")
        self.assertGreater(len(calls), 0)
        self.assertNotIn("skipped", r)


def make_msg(msg_id, channel="chan"):
    from tools.social.telegram.preview import Message
    return Message(channel=channel, msg_id=msg_id,
                   date="2026-08-01T10:00:00+00:00", text=f"m{msg_id}",
                   views=1, fwd_from_channel=None, fwd_from_msg_id=None,
                   reply_to_msg_id=None, media_type=None, media_ref=None)


class TestIncrementalOverlapWalk(unittest.TestCase):
    """I1: an interrupted incremental run can leave a permanent hole. A
    later incremental run must walk back past a page that inserts zero new
    rows -- stopping there was the defect -- and only stop once it
    genuinely overlaps known contiguous history."""

    def setUp(self):
        from tools.social.telegram.store import open_db
        self.conn = open_db(":memory:")
        self.conn.execute("INSERT INTO channels(username, status) "
                          "VALUES ('chan', 'seed_approved')")
        self.conn.commit()

    def test_channel_with_no_history_fails_without_any_fetch(self):
        from tools.social.telegram.collect import collect_channel

        calls = []
        def fetch(username, before):
            calls.append((username, before))
            raise AssertionError("fetch must never be called for a "
                                  "channel with no stored history")

        r = collect_channel(self.conn, "chan", fetch, mode="incremental")

        self.assertEqual(calls, [])
        self.assertEqual(r["status"], "failed")
        self.assertEqual(r["new_messages"], 0)
        self.assertEqual(r["failure_reason"], "no history: run backfill first")

    def test_interrupted_run_hole_is_recovered_by_the_next_incremental_run(self):
        from tools.social.telegram.collect import collect_channel
        from tools.social.telegram.store import upsert_messages

        # Day 1: 1..100 fully collected. A later incremental run saved the
        # newest page (156..160) then died (429/crash/kill) before walking
        # back far enough -- leaving 101..155 as a permanent hole under the
        # old "stop on zero inserts" rule.
        upsert_messages(self.conn, [make_msg(i) for i in range(1, 101)])
        upsert_messages(self.conn, [make_msg(i) for i in range(156, 161)])

        calls = []
        fetch = make_fake_fetch("chan", list(range(1, 166)), calls)

        r = collect_channel(self.conn, "chan", fetch, mode="incremental")

        self.assertEqual(r["status"], "complete")
        got = {row[0] for row in self.conn.execute(
            "SELECT msg_id FROM messages WHERE channel='chan'")}
        # The hole is fully recovered.
        self.assertTrue(set(range(101, 156)).issubset(got))
        self.assertEqual(r["new_messages"], 60)
        # Bounded overlap walk, not a backfill: it must NOT have kept
        # walking all the way down to msg 1 (that range needs 33 pages of
        # 5; the overlap walk needs exactly 14 -- 2 pages re-covering the
        # 156-165 zone, 11 pages of genuinely new 101-155 content, and the
        # final page (96-100) where it overlaps known history and stops).
        self.assertEqual(len(calls), 14)
        self.assertEqual(calls[-1], 101)  # the boundary-overlap page


class TestMarkChannelCompleteMaintenance(unittest.TestCase):
    """Idempotent maintenance helper for a channel that is genuinely
    complete in the live DB but carries a stale cursor and no marker
    (e.g. AllesAusserMainstream)."""

    def setUp(self):
        from tools.social.telegram.store import open_db
        self.conn = open_db(":memory:")
        self.conn.execute("INSERT INTO channels(username, status) "
                          "VALUES ('chan', 'seed_approved')")
        self.conn.commit()

    def test_marks_complete_and_clears_stale_cursor(self):
        from tools.social.telegram.collect import mark_channel_complete
        from tools.social.telegram.store import (set_cursor, get_cursor,
                                                  backfill_completed_at)

        set_cursor(self.conn, "chan", 6206)
        mark_channel_complete(self.conn, "chan")

        self.assertIsNone(get_cursor(self.conn, "chan"))
        self.assertIsNotNone(backfill_completed_at(self.conn, "chan"))

    def test_idempotent_when_run_twice(self):
        from tools.social.telegram.collect import mark_channel_complete
        from tools.social.telegram.store import get_cursor

        mark_channel_complete(self.conn, "chan")
        mark_channel_complete(self.conn, "chan")
        self.assertIsNone(get_cursor(self.conn, "chan"))

    def test_subsequent_backfill_run_skips_it(self):
        from tools.social.telegram.collect import (mark_channel_complete,
                                                    collect_channel)

        set_cursor_before = None
        mark_channel_complete(self.conn, "chan")

        calls = []
        def fetch(username, before):
            calls.append(before)
            raise AssertionError("must not fetch after maintenance mark")

        r = collect_channel(self.conn, "chan", fetch, mode="backfill")
        self.assertEqual(calls, [])
        self.assertEqual(r["skipped"], "already-backfilled")


class TestForceBackfillCliFlag(unittest.TestCase):
    """The --force-backfill flag must exist, default to False, and not be
    required for the --mark-complete maintenance path."""

    def test_flag_defaults_false_and_mode_optional_with_mark_complete(self):
        from tools.social.telegram.collect import _build_arg_parser

        ap = _build_arg_parser()
        args = ap.parse_args(["--db", "x.db", "--mode", "backfill"])
        self.assertFalse(args.force_backfill)

        args2 = ap.parse_args(["--db", "x.db", "--force-backfill",
                               "--mode", "backfill"])
        self.assertTrue(args2.force_backfill)

        # --mark-complete does not require --mode.
        args3 = ap.parse_args(["--db", "x.db", "--mark-complete", "chan"])
        self.assertEqual(args3.mark_complete, "chan")
        self.assertIsNone(args3.mode)


class TestCollectSingleInstanceLock(unittest.TestCase):
    """Exercises collect.py's __main__ wiring of the single-instance lock via
    a real subprocess -- the lock file is pre-held by THIS process (a second,
    independent fd, same as a genuinely racing collector process would be),
    so the child must refuse to even start collecting.

    Uses a nonexistent sqlite path in a temp dir and never touches the
    network or the live DB: exit 3 must fire before open_db() or
    requests.Session() are ever reached, so a bogus --db path is safe here.
    """

    def setUp(self):
        self._tmpdir = tempfile.TemporaryDirectory()
        self.db_path = str(pathlib.Path(self._tmpdir.name) / "telegram.db")
        self.lock_path = self.db_path + ".collector.lock"

    def tearDown(self):
        self._tmpdir.cleanup()

    def _run_collect(self, *extra_args):
        return subprocess.run(
            [sys.executable, "-m", "tools.social.telegram.collect",
             "--db", self.db_path, "--mode", "incremental", *extra_args],
            cwd=str(_REPO_ROOT), capture_output=True, text=True, timeout=30)

    def test_second_collector_exits_3_with_json_and_does_not_collect(self):
        with single_instance(self.lock_path):
            result = self._run_collect()
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report, {"ok": False,
                                   "error": "another collector is already "
                                            "running",
                                   "mode": "incremental"})
        # No DB file must have been created -- proof open_db() was never
        # reached, i.e. no work happened before the lock check gave up.
        self.assertFalse(pathlib.Path(self.db_path).exists())


if __name__ == "__main__":
    unittest.main()
