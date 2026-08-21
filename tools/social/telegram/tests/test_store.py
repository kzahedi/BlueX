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


if __name__ == "__main__":
    unittest.main()
