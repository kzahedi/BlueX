import csv
import io
import pathlib
import unittest


class TestSeedCsv(unittest.TestCase):
    def test_csv_well_formed_with_provenance(self):
        p = pathlib.Path("tools/social/telegram/seed_channels.csv")
        rows = list(csv.DictReader(p.open(encoding="utf-8")))
        self.assertGreaterEqual(len(rows), 30)
        for r in rows:
            self.assertRegex(r["username"], r"^[A-Za-z0-9_]{4,}$")
            self.assertTrue(r["source_list"].strip())
            self.assertTrue(r["inclusion_criterion"].strip())


class TestImportAndApprove(unittest.TestCase):
    def test_import_pending_then_approve(self):
        from tools.social.telegram.store import open_db
        from tools.social.telegram.seeds import import_csv
        from tools.social.telegram.channels import decide
        conn = open_db(":memory:")
        csv_text = ("username,title,source_list,inclusion_criterion\n"
                    "somechan,Some Chan,Report X 2022,category Y\n")
        n = import_csv(conn, io.StringIO(csv_text))
        self.assertEqual(n, 1)
        row = conn.execute("SELECT status FROM channels WHERE username='somechan'").fetchone()
        self.assertEqual(row[0], "seed_pending")
        decide(conn, "somechan", "approve")
        status, decided = conn.execute(
            "SELECT status, decided_by_user_at FROM channels "
            "WHERE username='somechan'").fetchone()
        self.assertEqual(status, "seed_approved")
        self.assertIsNotNone(decided)
        # re-import must not clobber the decision
        import_csv(conn, io.StringIO(csv_text))
        self.assertEqual(conn.execute(
            "SELECT status FROM channels WHERE username='somechan'"
        ).fetchone()[0], "seed_approved")


if __name__ == "__main__":
    unittest.main()
