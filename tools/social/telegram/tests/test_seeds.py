import csv
import io
import pathlib
import unittest


SEED_CSV = pathlib.Path("tools/social/telegram/seed_channels.csv")


# The seed list is deliberately NOT in this repository (it lives in a private
# Gitea repo; the working copy is git-ignored). These tests validate it when
# present and skip cleanly on checkouts without it.
@unittest.skipUnless(SEED_CSV.exists(), "seed_channels.csv not present "
                     "(kept out of the public repo; fetch from private Gitea)")
class TestSeedCsv(unittest.TestCase):
    def test_csv_well_formed_with_provenance(self):
        p = SEED_CSV
        rows = list(csv.DictReader(p.open(encoding="utf-8")))
        self.assertGreaterEqual(len(rows), 30)
        for r in rows:
            self.assertRegex(r["username"], r"^[A-Za-z0-9_]{4,}$")
            self.assertTrue(r["source_list"].strip())
            self.assertTrue(r["inclusion_criterion"].strip())
            # A comma-bearing field that was left unquoted shifts the raw
            # record's field count: csv.reader honours proper quoting, so a
            # correctly-quoted comma never trips this, but a stray literal
            # comma in an unquoted field pushes an extra field into the
            # DictReader restkey (None) below.
            self.assertIsNone(
                r.get(None),
                f"row for {r['username']!r} has extra unparsed fields "
                f"(unquoted comma shifted columns): {r.get(None)!r}")
            # A shifted field also tends to end mid-word right where the
            # displaced text used to continue after a quoted title/name —
            # i.e. it ends on a dangling single quote from a truncated
            # 'Name, Name' style fragment.
            self.assertFalse(
                r["source_list"].rstrip().endswith("'") and
                r["source_list"].count("'") % 2 == 1,
                f"row for {r['username']!r} has a truncated source_list "
                f"(dangling unmatched quote): {r['source_list']!r}")
            self.assertFalse(
                r["inclusion_criterion"].rstrip().endswith("'") and
                r["inclusion_criterion"].count("'") % 2 == 1,
                f"row for {r['username']!r} has a truncated "
                f"inclusion_criterion (dangling unmatched quote): "
                f"{r['inclusion_criterion']!r}")

    def test_raw_records_have_exactly_four_fields(self):
        # csv.reader (not DictReader) applied to the raw file: every record
        # must resolve to exactly 4 fields. Correctly RFC-4180-quoted commas
        # are consumed inside their field by csv.reader and do not add
        # fields, so this only fails on genuine unquoted-comma corruption.
        p = SEED_CSV
        with p.open(encoding="utf-8", newline="") as fp:
            records = list(csv.reader(fp))
        header, data_rows = records[0], records[1:]
        self.assertEqual(header, ["username", "title", "source_list",
                                   "inclusion_criterion"])
        for i, rec in enumerate(data_rows, start=2):
            self.assertEqual(
                len(rec), 4,
                f"CSV line {i} has {len(rec)} fields, expected 4 "
                f"(unquoted comma likely shifted columns): {rec!r}")


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
