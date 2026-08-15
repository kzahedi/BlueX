"""Tests for aggregate_weekly.py.

No network, no real store: a temp SQLite file built with the real ZPOST /
ZTRACKEDACCOUNT column shapes (same fixture pattern as
tools/deletions/test_extract_deleted.py), plus temp JSONL score files.
"""
import csv
import datetime as dt
import json
import os
import sqlite3
import tempfile
import unittest

import aggregate_weekly as aw

POST_DDL = """
CREATE TABLE ZPOST (
    Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER,
    ZDEPTH INTEGER, ZISROOTPOST INTEGER, ZLIKECOUNT INTEGER,
    ZNEEDSREANNOTATION INTEGER, ZQUOTECOUNT INTEGER, ZREPLYCOUNT INTEGER,
    ZREPOSTCOUNT INTEGER, ZACCOUNT INTEGER, ZCREATEDAT TIMESTAMP,
    ZREPLYTREELASTCHECKED TIMESTAMP, ZAUTHORDID VARCHAR,
    ZAUTHORHANDLE VARCHAR, ZPARENTURI VARCHAR, ZREPLYTREESTATUS VARCHAR,
    ZROOTURI VARCHAR, ZTEXT VARCHAR, ZURI VARCHAR
)
"""

ACCOUNT_DDL = """
CREATE TABLE ZTRACKEDACCOUNT (
    Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER,
    ZISACTIVE INTEGER, ZSTARTAT TIMESTAMP, ZAVATARURL VARCHAR,
    ZDID VARCHAR, ZDISPLAYNAME VARCHAR, ZHANDLE VARCHAR
)
"""


def unix_to_coredata(unix_ts):
    return unix_ts - aw.CORE_DATA_EPOCH_OFFSET


def iso(y, m, d, hh=12):
    return dt.datetime(y, m, d, hh, tzinfo=dt.timezone.utc).timestamp()


def make_store(path, accounts, roots, replies):
    """accounts: [(pk, handle), ...]
    roots: [(uri, account_pk), ...]  (created_at irrelevant for roots here)
    replies: [(uri, root_uri, unix_created_at), ...]
    """
    conn = sqlite3.connect(path)
    conn.execute(POST_DDL)
    conn.execute(ACCOUNT_DDL)
    for pk, handle in accounts:
        conn.execute("INSERT INTO ZTRACKEDACCOUNT (Z_PK, ZHANDLE) VALUES (?, ?)", (pk, handle))
    for uri, account_pk in roots:
        conn.execute(
            "INSERT INTO ZPOST (ZISROOTPOST, ZURI, ZROOTURI, ZACCOUNT, ZCREATEDAT) "
            "VALUES (1, ?, ?, ?, 0)",
            (uri, uri, account_pk),
        )
    for uri, root_uri, created in replies:
        conn.execute(
            "INSERT INTO ZPOST (ZISROOTPOST, ZURI, ZROOTURI, ZCREATEDAT) "
            "VALUES (0, ?, ?, ?)",
            (uri, root_uri, unix_to_coredata(created)),
        )
    conn.commit()
    conn.close()
    return path


def write_jsonl(path, records):
    with open(path, "w", encoding="utf-8") as handle:
        for rec in records:
            handle.write(json.dumps(rec) + "\n")


def score_record(uri, head, score, model_id="m", revision="r", scored_at="2026-08-11T00:00:00Z"):
    return {
        "uri": uri, "head": head, "score": score,
        "model_id": model_id, "model_revision": revision, "scored_at": scored_at,
    }


class IsoWeekTests(unittest.TestCase):
    def test_year_boundary_uses_iso_year_not_calendar_year(self):
        # 2024-12-30 is a Monday; its ISO week is 2025-W01, not 2024-Wxx.
        ts = iso(2024, 12, 30)
        self.assertEqual(aw.iso_week(ts), "2025-W01")

    def test_ordinary_week(self):
        ts = iso(2026, 8, 12)  # a Wednesday
        expected_year, expected_week, _ = dt.datetime(2026, 8, 12, tzinfo=dt.timezone.utc).isocalendar()
        self.assertEqual(aw.iso_week(ts), "%04d-W%02d" % (expected_year, expected_week))

    def test_coredata_conversion_roundtrip(self):
        unix_ts = iso(2026, 1, 5)
        coredata_val = unix_to_coredata(unix_ts)
        self.assertAlmostEqual(aw.coredata_to_unix(coredata_val), unix_ts)


class OutletAttributionTests(unittest.TestCase):
    def test_reply_attributed_to_root_owner(self):
        tmpdir = tempfile.mkdtemp()
        try:
            store_path = os.path.join(tmpdir, "s.store")
            t1 = iso(2026, 8, 10)
            make_store(
                store_path,
                accounts=[(1, "outlet-a.bsky.social"), (2, "outlet-b.bsky.social")],
                roots=[("at://root1", 1), ("at://root2", 2)],
                replies=[
                    ("at://r1", "at://root1", t1),
                    ("at://r2", "at://root2", t1),
                ],
            )
            replies = aw.fetch_replies(store_path)
            by_uri = {uri: outlet for uri, _, outlet in replies}
            self.assertEqual(by_uri["at://r1"], "outlet-a.bsky.social")
            self.assertEqual(by_uri["at://r2"], "outlet-b.bsky.social")
        finally:
            import shutil
            shutil.rmtree(tmpdir)


class HeadSelectionTests(unittest.TestCase):
    def test_identity_attack_lines_are_ignored(self):
        tmpdir = tempfile.mkdtemp()
        try:
            path = os.path.join(tmpdir, "scores.jsonl")
            write_jsonl(path, [
                score_record("at://p1", "toxicity", 0.9),
                score_record("at://p1", "identity_attack", 0.1),
            ])
            scores = aw.load_scores([path])
            self.assertEqual(scores, {"at://p1": 0.9})
        finally:
            import shutil
            shutil.rmtree(tmpdir)


class DuplicateLineTests(unittest.TestCase):
    def test_last_one_wins_within_and_across_files(self):
        tmpdir = tempfile.mkdtemp()
        try:
            path_old = os.path.join(tmpdir, "incivility-scores-2026-01-01T000000Z.jsonl")
            path_new = os.path.join(tmpdir, "incivility-scores-2026-02-01T000000Z.jsonl")
            write_jsonl(path_old, [
                score_record("at://p1", "toxicity", 0.1),
                score_record("at://p1", "toxicity", 0.2),  # dup within file: later wins
            ])
            write_jsonl(path_new, [
                score_record("at://p1", "toxicity", 0.9),  # dup across files: newer file wins
            ])
            scores = aw.load_scores([path_old, path_new])
            self.assertEqual(scores["at://p1"], 0.9)
        finally:
            import shutil
            shutil.rmtree(tmpdir)

    def test_find_score_files_sorts_oldest_first(self):
        tmpdir = tempfile.mkdtemp()
        try:
            for name in [
                "incivility-scores-2026-03-01T000000Z.jsonl",
                "incivility-scores-2026-01-01T000000Z.jsonl",
                "incivility-scores-2026-02-01T000000Z.jsonl",
            ]:
                open(os.path.join(tmpdir, name), "w").close()
            found = aw.find_score_files(tmpdir)
            self.assertEqual(
                [os.path.basename(p) for p in found],
                [
                    "incivility-scores-2026-01-01T000000Z.jsonl",
                    "incivility-scores-2026-02-01T000000Z.jsonl",
                    "incivility-scores-2026-03-01T000000Z.jsonl",
                ],
            )
        finally:
            import shutil
            shutil.rmtree(tmpdir)


class UnscoredExclusionTests(unittest.TestCase):
    """The heart of the honesty requirement: unscored replies must never be
    treated as score 0."""

    def _fixture(self):
        # One (outlet, week) bucket: 3 replies, only 2 scored.
        replies = [
            ("at://r1", iso(2026, 8, 10), "outlet-a"),
            ("at://r2", iso(2026, 8, 11), "outlet-a"),
            ("at://r3", iso(2026, 8, 12), "outlet-a"),
        ]
        scores = {"at://r1": 0.8, "at://r2": 0.4}  # at://r3 never scored
        return replies, scores

    def test_coverage_and_mean_exclude_unscored(self):
        replies, scores = self._fixture()
        agg = aw.aggregate(replies, scores)
        week = aw.iso_week(iso(2026, 8, 10))
        stats = agg[("outlet-a", week)]
        self.assertEqual(stats["n_scored"], 2)
        self.assertEqual(stats["n_replies_total"], 3)
        self.assertAlmostEqual(stats["coverage"], 2 / 3)
        # Mean over the two SCORED values only: (0.8 + 0.4) / 2 = 0.6.
        # If the unscored reply were defaulted to 0.0, the mean would be
        # (0.8 + 0.4 + 0.0) / 3 = 0.4 instead — a materially different,
        # wrong number. This is the test to break to prove the guard works
        # (see WATCH-IT-FAIL below).
        self.assertAlmostEqual(stats["mean_toxicity"], 0.6)

    # WATCH-IT-FAIL EVIDENCE: `test_coverage_and_mean_exclude_unscored` above
    # is the guard for this. It was verified to actually fail against a
    # buggy implementation by temporarily changing the line in aggregate()
    # from:
    #     if uri in scores:
    #         bucket["scored_values"].append(scores[uri])
    # to:
    #     bucket["scored_values"].append(scores.get(uri, 0.0))
    # and re-running `python -m pytest test_aggregate_weekly.py -k
    # test_coverage_and_mean_exclude_unscored -q`, which failed with
    # `AssertionError: 0.4 != 0.6 within 7 places` (mean pulled down by the
    # phantom 0.0 for the unscored reply) — full transcript recorded in the
    # task-7 report. The change was reverted immediately after confirming
    # the failure; aggregate_weekly.py never carried the buggy version.


class PercentileTests(unittest.TestCase):
    def test_p50_p90_hand_worked(self):
        # values 10..100 step 10 (n=10). Linear interpolation (numpy 'linear'):
        # idx = p * (n-1)
        values = [10, 20, 30, 40, 50, 60, 70, 80, 90, 100]
        # p50: idx = 0.5*9 = 4.5 -> between values[4]=50 and values[5]=60 -> 55
        self.assertAlmostEqual(aw.percentile(values, 0.50), 55.0)
        # p90: idx = 0.9*9 = 8.1 -> between values[8]=90 and values[9]=100 -> 91
        self.assertAlmostEqual(aw.percentile(values, 0.90), 91.0)

    def test_single_value(self):
        self.assertEqual(aw.percentile([0.42], 0.5), 0.42)


class PartialRunRefusalTests(unittest.TestCase):
    def test_partial_run_raises(self):
        with self.assertRaises(aw.PartialRunError):
            aw.check_run_complete({"run_status": "partial"})

    def test_complete_run_does_not_raise(self):
        aw.check_run_complete({"run_status": "complete"})  # should not raise

    def test_run_refuses_end_to_end_on_partial_summary(self):
        tmpdir = tempfile.mkdtemp()
        try:
            store_path = os.path.join(tmpdir, "s.store")
            make_store(store_path, accounts=[], roots=[], replies=[])
            scores_dir = os.path.join(tmpdir, "scores")
            os.makedirs(scores_dir)
            jsonl_path = os.path.join(scores_dir, "incivility-scores-2026-01-01T000000Z.jsonl")
            write_jsonl(jsonl_path, [score_record("at://p1", "toxicity", 0.5)])
            summary_path = os.path.join(scores_dir, "incivility-scores-2026-01-01T000000Z.summary.json")
            with open(summary_path, "w") as handle:
                json.dump({"run_status": "partial", "model_id": "m", "model_revision": "r"}, handle)

            out_dir = os.path.join(tmpdir, "out")
            with self.assertRaises(aw.PartialRunError):
                aw.run(scores_dir, store_path, out_dir)
        finally:
            import shutil
            shutil.rmtree(tmpdir)


class EndToEndTests(unittest.TestCase):
    def test_full_run_produces_csv_and_markdown(self):
        tmpdir = tempfile.mkdtemp()
        try:
            store_path = os.path.join(tmpdir, "s.store")
            t1 = iso(2026, 8, 10)  # week X
            t2 = iso(2026, 8, 18)  # next ISO week
            make_store(
                store_path,
                accounts=[(1, "outlet-a.bsky.social")],
                roots=[("at://root1", 1)],
                replies=[
                    ("at://r1", "at://root1", t1),
                    ("at://r2", "at://root1", t1),
                    ("at://r3", "at://root1", t2),
                ],
            )
            scores_dir = os.path.join(tmpdir, "scores")
            os.makedirs(scores_dir)
            jsonl_path = os.path.join(scores_dir, "incivility-scores-2026-08-11T131928Z.jsonl")
            write_jsonl(jsonl_path, [
                score_record("at://r1", "toxicity", 0.9),
                score_record("at://r1", "identity_attack", 0.05),
                score_record("at://r2", "toxicity", 0.1),
                # at://r3 deliberately left unscored (simulates corpus growth)
            ])
            summary_path = os.path.join(
                scores_dir, "incivility-scores-2026-08-11T131928Z.summary.json"
            )
            with open(summary_path, "w") as handle:
                json.dump({
                    "run_status": "complete", "model_id": "m", "model_revision": "r",
                }, handle)

            out_dir = os.path.join(tmpdir, "out")
            csv_path, md_path, rows, meta = aw.run(scores_dir, store_path, out_dir, stamp="TEST")

            self.assertTrue(os.path.exists(csv_path))
            self.assertTrue(os.path.exists(md_path))
            self.assertEqual(len(rows), 2)  # two (outlet, week) buckets

            with open(csv_path) as handle:
                csv_rows = list(csv.DictReader(handle))
            week1 = aw.iso_week(t1)
            row1 = next(r for r in csv_rows if r["iso_week"] == week1)
            self.assertEqual(row1["outlet"], "outlet-a.bsky.social")
            self.assertEqual(row1["n_scored"], "2")
            self.assertEqual(row1["n_replies_total"], "2")
            self.assertEqual(row1["coverage"], "1.0000")

            week2 = aw.iso_week(t2)
            row2 = next(r for r in csv_rows if r["iso_week"] == week2)
            self.assertEqual(row2["n_scored"], "0")
            self.assertEqual(row2["n_replies_total"], "1")
            self.assertEqual(row2["coverage"], "0.0000")
            self.assertEqual(row2["mean_toxicity"], "")  # never defaulted to 0

            with open(md_path) as handle:
                md_text = handle.read()
            self.assertIn("not hate", md_text)
            self.assertIn("0.198", md_text)
            self.assertIn("arbitrary illustrative threshold", md_text)
        finally:
            import shutil
            shutil.rmtree(tmpdir)


if __name__ == "__main__":
    unittest.main()
