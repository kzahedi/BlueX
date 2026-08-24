import json
import unittest

from tools.social.telegram.preview import Message


def make_msg(msg_id, date="2026-08-01T10:00:00+00:00", fwd=None):
    return Message(channel="testchan", msg_id=msg_id, date=date, text=f"m{msg_id}",
                   views=10, fwd_from_channel=fwd, fwd_from_msg_id=None,
                   reply_to_msg_id=None, media_type=None, media_ref=None)


class TestStore(unittest.TestCase):
    def setUp(self):
        from tools.social.telegram.store import open_db
        self.conn = open_db(":memory:")

    def test_upsert_is_idempotent(self):
        from tools.social.telegram.store import upsert_messages
        msgs = [make_msg(1), make_msg(2)]
        self.assertEqual(upsert_messages(self.conn, msgs), 2)
        self.assertEqual(upsert_messages(self.conn, msgs), 0)
        n, = self.conn.execute("SELECT COUNT(*) FROM messages").fetchone()
        self.assertEqual(n, 2)

    def test_cursor_roundtrip_and_clear(self):
        from tools.social.telegram.store import set_cursor, get_cursor
        self.assertIsNone(get_cursor(self.conn, "testchan"))
        set_cursor(self.conn, "testchan", 500)
        self.assertEqual(get_cursor(self.conn, "testchan"), 500)
        set_cursor(self.conn, "testchan", None)
        self.assertIsNone(get_cursor(self.conn, "testchan"))

    def test_coverage_records_gaps_not_silence(self):
        from tools.social.telegram.store import upsert_messages, record_coverage
        # ids 1,2,5 on one day: 3 and 4 are a gap that MUST be recorded
        upsert_messages(self.conn, [make_msg(1), make_msg(2), make_msg(5)])
        record_coverage(self.conn, "testchan")
        row = self.conn.execute(
            "SELECT message_count, min_msg_id, max_msg_id, gap_ids_json "
            "FROM coverage WHERE channel='testchan' AND day='2026-08-01'").fetchone()
        self.assertEqual(row[0], 3)
        self.assertEqual((row[1], row[2]), (1, 5))
        self.assertEqual(json.loads(row[3]), [3, 4])


class TestBackfillCompletionMarker(unittest.TestCase):
    """Explicit completion marker on `channels` so backfill can tell a
    finished channel from one that has never been walked."""

    def setUp(self):
        from tools.social.telegram.store import open_db
        self.conn = open_db(":memory:")
        self.conn.execute("INSERT INTO channels(username, status) "
                          "VALUES ('testchan', 'seed_approved')")
        self.conn.commit()

    def test_backfill_completed_at_is_none_before_marking(self):
        from tools.social.telegram.store import backfill_completed_at
        self.assertIsNone(backfill_completed_at(self.conn, "testchan"))

    def test_mark_backfill_complete_sets_timestamp(self):
        from tools.social.telegram.store import (mark_backfill_complete,
                                                  backfill_completed_at)
        mark_backfill_complete(self.conn, "testchan")
        stamp = backfill_completed_at(self.conn, "testchan")
        self.assertIsNotNone(stamp)
        self.assertIsInstance(stamp, str)

    def test_unknown_channel_returns_none(self):
        from tools.social.telegram.store import backfill_completed_at
        self.assertIsNone(backfill_completed_at(self.conn, "nope"))


class TestChannelsSchemaMigration(unittest.TestCase):
    """open_db must add backfill_complete_at to an EXISTING channels table
    (production databases predate this column) without touching existing
    rows' data."""

    def test_migration_adds_column_and_preserves_existing_rows(self):
        import tempfile
        import os
        import sqlite3
        from tools.social.telegram.store import open_db

        fd, path = tempfile.mkstemp(suffix=".db")
        os.close(fd)
        try:
            # Build the OLD schema by hand: no backfill_complete_at column.
            old_conn = sqlite3.connect(path)
            old_conn.executescript("""
                CREATE TABLE channels(
                  username TEXT PRIMARY KEY, title TEXT, source_list TEXT,
                  inclusion_criterion TEXT, status TEXT NOT NULL,
                  added_at TEXT DEFAULT (datetime('now')),
                  decided_by_user_at TEXT);
            """)
            old_conn.execute(
                "INSERT INTO channels(username, title, status) "
                "VALUES ('oldchan', 'Old Channel', 'seed_approved')")
            old_conn.commit()
            old_conn.close()

            cols_before = {r[1] for r in sqlite3.connect(path).execute(
                "PRAGMA table_info(channels)")}
            self.assertNotIn("backfill_complete_at", cols_before)

            conn = open_db(path)
            cols_after = {r[1] for r in conn.execute(
                "PRAGMA table_info(channels)")}
            self.assertIn("backfill_complete_at", cols_after)

            row = conn.execute(
                "SELECT username, title, status, backfill_complete_at "
                "FROM channels WHERE username='oldchan'").fetchone()
            self.assertEqual(row, ("oldchan", "Old Channel",
                                   "seed_approved", None))
            conn.close()

            # Idempotent: opening it again must not error or duplicate.
            conn2 = open_db(path)
            n, = conn2.execute(
                "SELECT COUNT(*) FROM channels").fetchone()
            self.assertEqual(n, 1)
            conn2.close()
        finally:
            os.remove(path)


class TestMaxMsgId(unittest.TestCase):
    """max_msg_id() must report the top of the CONTIGUOUS block starting at
    the channel's oldest message, not the table's raw MAX(msg_id) -- an
    interrupted incremental run can leave a disjoint island of newer ids
    above a real gap, and a later overlap-walk must not mistake that
    island for genuine coverage (finding I1)."""

    def setUp(self):
        from tools.social.telegram.store import open_db
        self.conn = open_db(":memory:")

    def test_none_when_no_messages(self):
        from tools.social.telegram.store import max_msg_id
        self.assertIsNone(max_msg_id(self.conn, "testchan"))

    def test_returns_the_max_when_contiguous(self):
        from tools.social.telegram.store import upsert_messages, max_msg_id
        upsert_messages(self.conn, [make_msg(1), make_msg(2), make_msg(3)])
        self.assertEqual(max_msg_id(self.conn, "testchan"), 3)

    def test_stops_at_first_gap_ignoring_a_disjoint_island_above(self):
        from tools.social.telegram.store import upsert_messages, max_msg_id
        upsert_messages(self.conn, [make_msg(i) for i in range(1, 101)])
        # A disjoint island left by an interrupted incremental run -- the
        # table's raw MAX(msg_id) would be 160, but that must NOT be what
        # this helper reports.
        upsert_messages(self.conn, [make_msg(i) for i in range(156, 161)])
        self.assertEqual(max_msg_id(self.conn, "testchan"), 100)

    def test_unknown_channel_returns_none(self):
        from tools.social.telegram.store import upsert_messages, max_msg_id
        upsert_messages(self.conn, [make_msg(1)])
        self.assertIsNone(max_msg_id(self.conn, "nope"))


class TestNewestMsgId(unittest.TestCase):
    """newest_msg_id() is the raw MAX(msg_id) -- deliberately NOT the
    contiguous-prefix top that max_msg_id() reports. A channel storing
    1..100 plus a disjoint island 156..160 must give newest_msg_id==160
    (raw max, includes the island) and max_msg_id==100 (contiguous prefix,
    stops at the gap) -- documenting the difference by example, since
    conflating the two is exactly the bug that made the daily incremental
    job walk an entire 87k-message channel for zero new rows (measured
    2026-08-22, EvaHermanOffiziell)."""

    def setUp(self):
        from tools.social.telegram.store import open_db
        self.conn = open_db(":memory:")

    def test_none_when_no_messages(self):
        from tools.social.telegram.store import newest_msg_id
        self.assertIsNone(newest_msg_id(self.conn, "testchan"))

    def test_raw_max_vs_contiguous_top_on_the_same_island(self):
        from tools.social.telegram.store import (upsert_messages, max_msg_id,
                                                  newest_msg_id)
        upsert_messages(self.conn, [make_msg(i) for i in range(1, 101)])
        upsert_messages(self.conn, [make_msg(i) for i in range(156, 161)])
        self.assertEqual(newest_msg_id(self.conn, "testchan"), 160)
        self.assertEqual(max_msg_id(self.conn, "testchan"), 100)

    def test_unknown_channel_returns_none(self):
        from tools.social.telegram.store import upsert_messages, newest_msg_id
        upsert_messages(self.conn, [make_msg(1)])
        self.assertIsNone(newest_msg_id(self.conn, "nope"))


if __name__ == "__main__":
    unittest.main()


class TestBusyTimeout(unittest.TestCase):
    """A concurrent writer must cause a wait, not an immediate abort: the
    collector and the daily job can legitimately overlap."""

    def test_open_db_sets_busy_timeout(self):
        from tools.social.telegram.store import open_db, BUSY_TIMEOUT_SECONDS
        conn = open_db(":memory:")
        got, = conn.execute("PRAGMA busy_timeout").fetchone()
        self.assertEqual(got, int(BUSY_TIMEOUT_SECONDS * 1000))
        self.assertGreaterEqual(got, 5000)


class TestMigrateCanonicalNames(unittest.TestCase):
    """The one-shot migration that reconciles the production bug: Telegram
    returns its own casing in data-post, which can differ from the approved
    spelling in channels.username. This lowercases the identity column in
    all five tables that key on a channel name, merging any collision a
    lowercase pass creates rather than silently dropping a row."""

    def setUp(self):
        from tools.social.telegram.store import open_db
        self.conn = open_db(":memory:")

    def test_renames_all_five_tables_keys(self):
        from tools.social.telegram.store import migrate_canonical_names
        c = self.conn
        c.execute("INSERT INTO channels(username, status) "
                 "VALUES ('FrankKraemer', 'seed_approved')")
        c.execute("INSERT INTO messages(channel, msg_id, date) "
                 "VALUES ('frankkraemer', 1, '2026-08-01T00:00:00+00:00')")
        c.execute("INSERT INTO candidates(username) VALUES ('SomeCandidate')")
        c.execute("INSERT INTO cursors(channel, before) VALUES ('FrankKraemer', 5)")
        c.execute("INSERT INTO coverage(channel, day, message_count, "
                 "min_msg_id, max_msg_id, gap_ids_json) "
                 "VALUES ('FrankKraemer', '2026-08-01', 1, 1, 1, '[]')")
        c.commit()

        report = migrate_canonical_names(self.conn)

        self.assertEqual(self.conn.execute(
            "SELECT username FROM channels").fetchone()[0], "frankkraemer")
        self.assertEqual(self.conn.execute(
            "SELECT channel FROM messages").fetchone()[0], "frankkraemer")
        self.assertEqual(self.conn.execute(
            "SELECT username FROM candidates").fetchone()[0], "somecandidate")
        self.assertEqual(self.conn.execute(
            "SELECT channel FROM cursors").fetchone()[0], "frankkraemer")
        self.assertEqual(self.conn.execute(
            "SELECT channel FROM coverage").fetchone()[0], "frankkraemer")
        self.assertTrue(report["renames"])

    def test_idempotent_second_run_changes_nothing(self):
        from tools.social.telegram.store import migrate_canonical_names
        c = self.conn
        c.execute("INSERT INTO channels(username, status) "
                 "VALUES ('FrankKraemer', 'seed_approved')")
        c.execute("INSERT INTO messages(channel, msg_id, date) "
                 "VALUES ('frankkraemer', 1, '2026-08-01T00:00:00+00:00')")
        c.commit()

        migrate_canonical_names(self.conn)
        before = self.conn.execute(
            "SELECT username FROM channels").fetchall()
        report2 = migrate_canonical_names(self.conn)
        after = self.conn.execute(
            "SELECT username FROM channels").fetchall()

        self.assertEqual(before, after)
        self.assertEqual(report2["merges"], [])
        self.assertEqual(report2["renames"], [])

    def test_merges_a_messages_collision_keeping_one_row(self):
        from tools.social.telegram.store import migrate_canonical_names
        c = self.conn
        # Same msg_id under two different casings -- the actual production
        # bug: t.me returning a different casing than what was requested.
        c.execute("INSERT INTO messages(channel, msg_id, date, text) "
                 "VALUES ('Foo', 42, '2026-08-01T00:00:00+00:00', 'v1')")
        c.execute("INSERT INTO messages(channel, msg_id, date, text) "
                 "VALUES ('foo', 42, '2026-08-01T00:00:01+00:00', 'v2')")
        c.commit()

        report = migrate_canonical_names(self.conn)

        rows = self.conn.execute(
            "SELECT channel, msg_id FROM messages").fetchall()
        self.assertEqual(rows, [("foo", 42)])
        merge_counts = {m["table"]: m["count"] for m in report["merges"]}
        self.assertEqual(merge_counts.get("messages"), 1)
        self.assertTrue(any("42" in line for line in report["merge_lines"]))

    def test_merges_a_cursors_collision_keeping_furthest_back_cursor(self):
        from tools.social.telegram.store import migrate_canonical_names
        c = self.conn
        # 'Foo' walked further back (smaller before) than 'foo'.
        c.execute("INSERT INTO cursors(channel, before) VALUES ('Foo', 100)")
        c.execute("INSERT INTO cursors(channel, before) VALUES ('foo', 500)")
        c.commit()

        report = migrate_canonical_names(self.conn)

        row = self.conn.execute(
            "SELECT channel, before FROM cursors").fetchone()
        self.assertEqual(row, ("foo", 100))
        merge_counts = {m["table"]: m["count"] for m in report["merges"]}
        self.assertEqual(merge_counts.get("cursors"), 1)

    def test_before_after_row_counts_reported(self):
        from tools.social.telegram.store import migrate_canonical_names
        c = self.conn
        c.execute("INSERT INTO messages(channel, msg_id, date) "
                 "VALUES ('Foo', 1, '2026-08-01T00:00:00+00:00')")
        c.execute("INSERT INTO messages(channel, msg_id, date) "
                 "VALUES ('foo', 1, '2026-08-01T00:00:01+00:00')")
        c.execute("INSERT INTO messages(channel, msg_id, date) "
                 "VALUES ('Foo', 2, '2026-08-01T00:00:02+00:00')")
        c.commit()

        report = migrate_canonical_names(self.conn)

        self.assertEqual(report["before_counts"]["messages"], 3)
        self.assertEqual(report["after_counts"]["messages"], 2)

    def test_refuses_when_lock_is_held(self):
        import tempfile
        import os
        from tools.social.telegram.store import open_db
        from tools.common.single_instance import single_instance, \
            AlreadyRunningError
        from tools.social.telegram.collect import run_migration

        fd, path = tempfile.mkstemp(suffix=".db")
        os.close(fd)
        try:
            lock_path = f"{path}.collector.lock"
            with single_instance(lock_path):
                with self.assertRaises(AlreadyRunningError):
                    run_migration(path)
        finally:
            os.remove(path)
