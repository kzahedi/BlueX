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
