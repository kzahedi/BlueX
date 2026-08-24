import unittest


class TestDecideCanonicalLookup(unittest.TestCase):
    """A human typing either the approved casing or a different casing must
    resolve to the same channel row -- decide() looks the name up by its
    canonical identity, not by exact string match."""

    def setUp(self):
        from tools.social.telegram.store import open_db
        self.conn = open_db(":memory:")
        self.conn.execute("INSERT INTO channels(username, status) "
                          "VALUES ('frankkraemer', 'seed_pending')")
        self.conn.commit()

    def test_decide_finds_channel_by_different_casing(self):
        from tools.social.telegram.channels import decide
        new_status = decide(self.conn, "FrankKraemer", "approve")
        self.assertEqual(new_status, "seed_approved")
        row = self.conn.execute(
            "SELECT status FROM channels WHERE username='frankkraemer'"
        ).fetchone()
        self.assertEqual(row[0], "seed_approved")

    def test_decide_still_works_with_exact_casing(self):
        from tools.social.telegram.channels import decide
        new_status = decide(self.conn, "frankkraemer", "approve")
        self.assertEqual(new_status, "seed_approved")

    def test_decide_unknown_channel_raises(self):
        from tools.social.telegram.channels import decide
        with self.assertRaises(SystemExit):
            decide(self.conn, "NoSuchChannel", "approve")


if __name__ == "__main__":
    unittest.main()
