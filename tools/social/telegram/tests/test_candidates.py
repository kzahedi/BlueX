import unittest

from tools.social.telegram.preview import Message


def fwd_msg(channel, msg_id, fwd):
    return Message(channel=channel, msg_id=msg_id,
                   date="2026-08-01T10:00:00+00:00", text="x", views=None,
                   fwd_from_channel=fwd, fwd_from_msg_id=1,
                   reply_to_msg_id=None, media_type=None, media_ref=None)


class TestSnowball(unittest.TestCase):
    def setUp(self):
        from tools.social.telegram.store import open_db, upsert_messages
        self.conn = open_db(":memory:")
        self.upsert = upsert_messages

    def test_threshold_three_distinct_forwarders(self):
        from tools.social.telegram.candidates import update_candidates, proposal_ready
        self.upsert(self.conn, [fwd_msg("a", 1, "newchan"),
                                fwd_msg("b", 1, "newchan")])
        update_candidates(self.conn)
        self.assertEqual(proposal_ready(self.conn), [])   # 2 distinct: below
        self.upsert(self.conn, [fwd_msg("c", 1, "newchan")])
        update_candidates(self.conn)
        ready = proposal_ready(self.conn)
        self.assertEqual(len(ready), 1)
        self.assertEqual(ready[0][0], "newchan")

    def test_threshold_twenty_total_forwards(self):
        from tools.social.telegram.candidates import update_candidates, proposal_ready
        self.upsert(self.conn, [fwd_msg("a", i, "loudchan") for i in range(1, 21)])
        update_candidates(self.conn)
        self.assertEqual([r[0] for r in proposal_ready(self.conn)], ["loudchan"])

    def test_tracked_channels_never_become_candidates(self):
        from tools.social.telegram.candidates import update_candidates
        self.conn.execute("INSERT INTO channels(username, status) "
                          "VALUES ('a', 'seed_approved')")
        self.upsert(self.conn, [fwd_msg("b", i, "a") for i in range(1, 30)])
        update_candidates(self.conn)
        n, = self.conn.execute("SELECT COUNT(*) FROM candidates").fetchone()
        self.assertEqual(n, 0)

    def test_approve_creates_snowball_channel(self):
        from tools.social.telegram.candidates import (update_candidates,
                                                      approve_candidate)
        self.upsert(self.conn, [fwd_msg(c, 1, "newchan") for c in "abc"])
        update_candidates(self.conn)
        approve_candidate(self.conn, "newchan")
        status, src = self.conn.execute(
            "SELECT status, source_list FROM channels "
            "WHERE username='newchan'").fetchone()
        self.assertEqual((status, src), ("snowball_approved", "snowball"))
        decided, = self.conn.execute(
            "SELECT decided_at FROM candidates WHERE username='newchan'").fetchone()
        self.assertIsNotNone(decided)

    def test_reject_candidate_happy_path(self):
        from tools.social.telegram.candidates import (update_candidates,
                                                      reject_candidate)
        self.upsert(self.conn, [fwd_msg(c, 1, "newchan") for c in "abc"])
        update_candidates(self.conn)
        reject_candidate(self.conn, "newchan")
        status, decided = self.conn.execute(
            "SELECT status, decided_at FROM candidates "
            "WHERE username='newchan'").fetchone()
        self.assertEqual(status, "rejected")
        self.assertIsNotNone(decided)
        # After update_candidates, rejected should stay rejected
        self.upsert(self.conn, [fwd_msg("d", 2, "newchan")])
        update_candidates(self.conn)
        status, = self.conn.execute(
            "SELECT status FROM candidates WHERE username='newchan'").fetchone()
        self.assertEqual(status, "rejected")

    def test_reject_candidate_unknown_username(self):
        from tools.social.telegram.candidates import reject_candidate
        with self.assertRaises(SystemExit) as cm:
            reject_candidate(self.conn, "unknown")
        self.assertIn("not a candidate", str(cm.exception))

    def test_approve_candidate_double_approve(self):
        from tools.social.telegram.candidates import (update_candidates,
                                                      approve_candidate)
        self.upsert(self.conn, [fwd_msg(c, 1, "newchan") for c in "abc"])
        update_candidates(self.conn)
        approve_candidate(self.conn, "newchan")
        # Second approve should raise SystemExit
        with self.assertRaises(SystemExit) as cm:
            approve_candidate(self.conn, "newchan")
        self.assertIn("already decided", str(cm.exception))

    def test_approve_candidate_already_tracked(self):
        from tools.social.telegram.candidates import (update_candidates,
                                                      approve_candidate)
        # Create a candidate and a separate channels row for the same username
        self.upsert(self.conn, [fwd_msg(c, 1, "newchan") for c in "abc"])
        update_candidates(self.conn)
        # Manually add newchan to channels (simulating independent seeding)
        self.conn.execute("INSERT INTO channels(username, status) "
                          "VALUES ('newchan', 'seed_approved')")
        self.conn.commit()
        # Trying to approve the candidate should fail
        with self.assertRaises(SystemExit) as cm:
            approve_candidate(self.conn, "newchan")
        self.assertIn("channel already tracked", str(cm.exception))


if __name__ == "__main__":
    unittest.main()
