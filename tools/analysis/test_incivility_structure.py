"""Tests for incivility_structure.py.

No network, no real store: a temp SQLite file built with the real ZPOST /
ZTRACKEDACCOUNT column shapes (same fixture pattern as
tools/incivility/test_aggregate_weekly.py), plus temp JSONL score and label
files. Covers: multi-file score merging, negated-label exclusion, nulls
never imputed as zero, Gini on a known distribution, a hand-computable
escalation table, honesty-header substrings, and reconciliation refusal.
"""
import csv
import datetime as dt
import json
import os
import shutil
import sqlite3
import tempfile
import unittest

import incivility_structure as inc

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
    return unix_ts - inc.CORE_DATA_EPOCH_OFFSET


def iso(y, m, d, hh=12):
    return dt.datetime(y, m, d, hh, tzinfo=dt.timezone.utc).timestamp()


def make_store(path, accounts=(), roots=(), replies=()):
    """accounts: [(pk, handle), ...]
    roots: [(uri, account_pk), ...]
    replies: [(uri, root_uri, parent_uri, depth, author_did, unix_created_at), ...]
    """
    conn = sqlite3.connect(path)
    conn.execute(POST_DDL)
    conn.execute(ACCOUNT_DDL)
    for pk, handle in accounts:
        conn.execute("INSERT INTO ZTRACKEDACCOUNT (Z_PK, ZHANDLE) VALUES (?, ?)", (pk, handle))
    for uri, account_pk in roots:
        conn.execute(
            "INSERT INTO ZPOST (ZISROOTPOST, ZURI, ZROOTURI, ZACCOUNT, ZCREATEDAT, ZDEPTH) "
            "VALUES (1, ?, ?, ?, 0, 0)",
            (uri, uri, account_pk),
        )
    for uri, root_uri, parent_uri, depth, author_did, created in replies:
        conn.execute(
            "INSERT INTO ZPOST (ZISROOTPOST, ZURI, ZROOTURI, ZPARENTURI, ZDEPTH, "
            "ZAUTHORDID, ZCREATEDAT) VALUES (0, ?, ?, ?, ?, ?, ?)",
            (uri, root_uri, parent_uri, depth, author_did, unix_to_coredata(created)),
        )
    conn.commit()
    conn.close()
    return path


def write_jsonl(path, records):
    with open(path, "w", encoding="utf-8") as handle:
        for rec in records:
            handle.write(json.dumps(rec) + "\n")


def score_record(uri, head, score, model_id="unitary/unbiased-toxic-roberta",
                  revision="rev1", scored_at="2026-08-11T00:00:00Z"):
    return {
        "uri": uri, "head": head, "score": score,
        "model_id": model_id, "model_revision": revision, "scored_at": scored_at,
    }


def label_record(subject, val, cts, neg=False, src="did:plc:ar7c4by46qjdydhdevvrndac",
                  observed_at="2026-08-10T12:00:00Z"):
    return {
        "subject": subject, "subject_type": "post", "src": src, "val": val,
        "cts": cts, "neg": neg, "observed_at": observed_at,
    }


class MultiFileScoreMergeTests(unittest.TestCase):
    def test_merges_across_two_files_and_dedupes(self):
        tmpdir = tempfile.mkdtemp()
        try:
            p1 = os.path.join(tmpdir, "incivility-scores-2026-01-01T000000Z.jsonl")
            p2 = os.path.join(tmpdir, "incivility-scores-2026-02-01T000000Z.jsonl")
            write_jsonl(p1, [
                score_record("at://p1", "toxicity", 0.1),
                score_record("at://p1", "identity_attack", 0.9),  # must be ignored
            ])
            write_jsonl(p2, [
                score_record("at://p2", "toxicity", 0.7),
                score_record("at://p1", "toxicity", 0.2),  # rescoring: later file wins
            ])
            paths = inc.find_score_files(tmpdir)
            self.assertEqual(len(paths), 2)
            scores = inc.load_scores(paths)
            self.assertEqual(scores, {"at://p1": 0.2, "at://p2": 0.7})
        finally:
            shutil.rmtree(tmpdir)


class NegatedLabelExclusionTests(unittest.TestCase):
    def test_negated_label_excluded_from_active(self):
        tmpdir = tempfile.mkdtemp()
        try:
            path = os.path.join(tmpdir, "label-harvest-posts-2026-01-01T000000Z.jsonl")
            write_jsonl(path, [
                label_record("at://p1", "rude", "2026-08-01T00:00:00Z", neg=False),
                label_record("at://p1", "rude", "2026-08-02T00:00:00Z", neg=True),  # retraction
                label_record("at://p2", "intolerant", "2026-08-03T00:00:00Z", neg=False),
            ])
            active = inc.load_active_post_labels([path])
            self.assertIn("at://p2", active)
            # at://p1's only surviving record must be excluded: the negated
            # record must not silently count as an active 'rude' label.
            p1_active_vals = [rec["val"] for rec in active.get("at://p1", [])]
            self.assertNotIn("rude", p1_active_vals)
        finally:
            shutil.rmtree(tmpdir)


class GiniTests(unittest.TestCase):
    def test_gini_zero_for_perfect_equality(self):
        self.assertAlmostEqual(inc.gini([5.0, 5.0, 5.0, 5.0]), 0.0, places=6)

    def test_gini_known_distribution(self):
        # [0, 0, 0, 10]: one author holds all the mass -> gini approaches
        # (n-1)/n = 0.75 for this discrete population formula.
        values = [0.0, 0.0, 0.0, 10.0]
        g = inc.gini(values)
        self.assertAlmostEqual(g, 0.75, places=6)

    def test_gini_all_zero_is_zero_not_nan(self):
        self.assertEqual(inc.gini([0.0, 0.0, 0.0]), 0.0)


class AuthorConcentrationTests(unittest.TestCase):
    def test_unscored_replies_never_imputed_as_zero(self):
        # Author with 3 replies, only 2 scored. Mean must be over scored
        # values only (0.8+0.4)/2=0.6, never (0.8+0.4+0.0)/3=0.4.
        replies = [
            {"uri": "at://r1", "author_did": "did:a", "parent_uri": "at://root", "depth": 1, "outlet": "o"},
            {"uri": "at://r2", "author_did": "did:a", "parent_uri": "at://root", "depth": 1, "outlet": "o"},
            {"uri": "at://r3", "author_did": "did:a", "parent_uri": "at://root", "depth": 1, "outlet": "o"},
        ]
        scores = {"at://r1": 0.8, "at://r2": 0.4}
        stats = inc.compute_author_stats(replies, scores, threshold=0.5)
        row = stats["did:a"]
        self.assertEqual(row["reply_count"], 3)
        self.assertEqual(row["n_scored"], 2)
        self.assertAlmostEqual(row["mean_toxicity"], 0.6)
        self.assertAlmostEqual(row["max_toxicity"], 0.8)
        self.assertEqual(row["n_above_threshold"], 1)

    def test_author_with_zero_scored_replies_reported_not_dropped(self):
        replies = [
            {"uri": "at://r1", "author_did": "did:b", "parent_uri": "at://root", "depth": 1, "outlet": "o"},
        ]
        stats = inc.compute_author_stats(replies, {}, threshold=0.5)
        row = stats["did:b"]
        self.assertEqual(row["reply_count"], 1)
        self.assertEqual(row["n_scored"], 0)
        self.assertIsNone(row["mean_toxicity"])
        self.assertIsNone(row["max_toxicity"])


class EscalationTableTests(unittest.TestCase):
    def test_hand_computable_escalation(self):
        # Two depth-2 replies to a scored depth-1 parent that is uncivil,
        # one child uncivil, one civil; plus a depth-2 pair under a civil
        # parent, both civil. Base rate over all 4 scored children: 1/4.
        replies = [
            {"uri": "at://parent1", "author_did": "a", "parent_uri": "at://root", "depth": 1, "outlet": "o"},
            {"uri": "at://c1", "author_did": "b", "parent_uri": "at://parent1", "depth": 2, "outlet": "o"},
            {"uri": "at://c2", "author_did": "c", "parent_uri": "at://parent1", "depth": 2, "outlet": "o"},
            {"uri": "at://parent2", "author_did": "d", "parent_uri": "at://root", "depth": 1, "outlet": "o"},
            {"uri": "at://c3", "author_did": "e", "parent_uri": "at://parent2", "depth": 2, "outlet": "o"},
            {"uri": "at://c4", "author_did": "f", "parent_uri": "at://parent2", "depth": 2, "outlet": "o"},
        ]
        scores = {
            "at://parent1": 0.9,  # uncivil parent
            "at://c1": 0.9,       # uncivil child of uncivil parent
            "at://c2": 0.1,       # civil child of uncivil parent
            "at://parent2": 0.1,  # civil parent
            "at://c3": 0.1,       # civil child of civil parent
            "at://c4": 0.1,       # civil child of civil parent
        }
        rows = inc.compute_escalation(replies, scores, threshold=0.5)
        depth2 = next(r for r in rows if r["outlet"] == "o" and r["depth_bucket"] == "2")
        # Among depth-2 children, both parent-scored: 2 with uncivil parent
        # (1 uncivil child -> 1/2), 2 with civil parent (0 uncivil -> 0/2).
        self.assertEqual(depth2["n_parent_uncivil"], 2)
        self.assertEqual(depth2["n_child_uncivil_given_parent_uncivil"], 1)
        self.assertEqual(depth2["n_parent_civil"], 2)
        self.assertEqual(depth2["n_child_uncivil_given_parent_civil"], 0)
        self.assertEqual(depth2["n_children_scored"], 4)
        self.assertEqual(depth2["n_base_uncivil"], 1)
        self.assertTrue(depth2["small_n"])  # n < 100

    def test_depth1_parent_is_root_never_scored(self):
        # depth-1 replies' parent is the root post, which score_corpus.py
        # never scores (ZISROOTPOST=0 only). Parent-conditional counts for
        # depth 1 must be zero/undefined, not silently treated as civil.
        replies = [
            {"uri": "at://r1", "author_did": "a", "parent_uri": "at://root", "depth": 1, "outlet": "o"},
        ]
        scores = {"at://r1": 0.9}  # root never appears in scores
        rows = inc.compute_escalation(replies, scores, threshold=0.5)
        depth1 = next(r for r in rows if r["outlet"] == "o" and r["depth_bucket"] == "1")
        self.assertEqual(depth1["n_parent_uncivil"], 0)
        self.assertEqual(depth1["n_parent_civil"], 0)
        self.assertEqual(depth1["n_children_scored"], 1)
        self.assertEqual(depth1["n_base_uncivil"], 1)

    def test_depth_bucket_four_plus(self):
        self.assertEqual(inc.depth_bucket(4), "4+")
        self.assertEqual(inc.depth_bucket(9), "4+")
        self.assertEqual(inc.depth_bucket(3), "3")
        self.assertEqual(inc.depth_bucket(1), "1")


class WilsonCiTests(unittest.TestCase):
    def test_matches_known_value(self):
        lo, hi = inc.wilson_ci(50, 100)
        self.assertAlmostEqual(lo, 0.4038, places=3)
        self.assertAlmostEqual(hi, 0.5962, places=3)

    def test_zero_n_returns_zero_zero(self):
        self.assertEqual(inc.wilson_ci(0, 0), (0.0, 0.0))


class ModerationCoverageTests(unittest.TestCase):
    def test_deciles_partition_scored_posts_and_label_join(self):
        scores = {"at://p%d" % i: i / 10.0 for i in range(1, 11)}  # 0.1..1.0
        active_labels = {
            "at://p10": [{"val": "intolerant", "cts": "2026-08-10T00:00:00Z"}],
            "at://p1": [{"val": "spam", "cts": "2026-08-01T00:00:00Z"}],
        }
        created_at = {uri: 1700000000.0 for uri in scores}
        rows = inc.compute_moderation_coverage(scores, active_labels, created_at, n_deciles=10)
        self.assertEqual(sum(r["n_posts"] for r in rows), 10)
        total_any = sum(r["n_any_active_label"] for r in rows)
        self.assertEqual(total_any, 2)
        total_hate = sum(r["n_hate_relevant_label"] for r in rows)
        self.assertEqual(total_hate, 1)


class HonestyHeaderTests(unittest.TestCase):
    def _meta(self):
        return {
            "model_id": "unitary/unbiased-toxic-roberta",
            "model_revision": "rev1",
            "threshold": 0.5,
            "n_scored": 100,
            "n_unscored": 20,
            "generated_at": "2026-08-22T00:00:00Z",
        }

    def test_all_honesty_elements_present(self):
        lines = inc.csv_honesty_comment_lines(self._meta())
        text = "\n".join(lines)
        self.assertTrue(all(ln.startswith("#") for ln in lines))
        self.assertIn("NOT HATE", text)
        self.assertIn("0.198", text)
        self.assertIn("0.946", text)
        self.assertIn("ILLUSTRATIVE", text)
        self.assertIn("0.5", text)
        self.assertIn("unitary/unbiased-toxic-roberta", text)
        self.assertIn("rev1", text)
        self.assertIn("100", text)
        self.assertIn("20", text)
        self.assertIn("2026-08-22T00:00:00Z", text)

    def test_written_csv_starts_with_comment_then_header(self):
        tmpdir = tempfile.mkdtemp()
        try:
            path = os.path.join(tmpdir, "out.csv")
            inc.write_csv_with_header(path, ["a", "b"], [{"a": 1, "b": 2}], self._meta())
            with open(path) as handle:
                lines = handle.readlines()
            comment_lines = [ln for ln in lines if ln.startswith("#")]
            self.assertGreater(len(comment_lines), 0)
            first_data_line = next(ln for ln in lines if not ln.startswith("#"))
            self.assertTrue(first_data_line.startswith("a,b"))
        finally:
            shutil.rmtree(tmpdir)


class ReconciliationTests(unittest.TestCase):
    def test_matching_counts_pass(self):
        inc.assert_reconciliation(10, 10, "a1")  # should not raise

    def test_mismatch_raises_by_default(self):
        with self.assertRaises(inc.CountMismatchError):
            inc.assert_reconciliation(9, 10, "a1")

    def test_mismatch_allowed_with_flag(self):
        inc.assert_reconciliation(9, 10, "a1", allow_mismatch=True)  # no raise


class FetchReplyRowsTests(unittest.TestCase):
    def test_reads_depth_parent_author_outlet(self):
        tmpdir = tempfile.mkdtemp()
        try:
            store_path = os.path.join(tmpdir, "s.store")
            t1 = iso(2026, 8, 10)
            make_store(
                store_path,
                accounts=[(1, "outlet-a.bsky.social")],
                roots=[("at://root1", 1)],
                replies=[
                    ("at://r1", "at://root1", "at://root1", 1, "did:a", t1),
                    ("at://r2", "at://root1", "at://r1", 2, "did:b", t1),
                ],
            )
            rows = inc.fetch_reply_rows(store_path)
            by_uri = {r["uri"]: r for r in rows}
            self.assertEqual(by_uri["at://r1"]["outlet"], "outlet-a.bsky.social")
            self.assertEqual(by_uri["at://r1"]["depth"], 1)
            self.assertEqual(by_uri["at://r2"]["parent_uri"], "at://r1")
            self.assertEqual(by_uri["at://r2"]["author_did"], "did:b")
        finally:
            shutil.rmtree(tmpdir)


class EndToEndRunTests(unittest.TestCase):
    def _build_fixture(self, tmpdir):
        store_path = os.path.join(tmpdir, "s.store")
        t1 = iso(2026, 8, 10)
        make_store(
            store_path,
            accounts=[(1, "outlet-a.bsky.social")],
            roots=[("at://root1", 1)],
            replies=[
                ("at://r1", "at://root1", "at://root1", 1, "did:a", t1),
                ("at://r2", "at://root1", "at://r1", 2, "did:b", t1),
                ("at://r3", "at://root1", "at://root1", 1, "did:a", t1),
            ],
        )
        scores_dir = os.path.join(tmpdir, "scores")
        os.makedirs(scores_dir)
        write_jsonl(os.path.join(scores_dir, "incivility-scores-2026-08-11T000000Z.jsonl"), [
            score_record("at://r1", "toxicity", 0.9),
            score_record("at://r2", "toxicity", 0.2),
            # at://r3 left unscored deliberately
        ])
        labels_dir = os.path.join(tmpdir, "labels")
        os.makedirs(labels_dir)
        write_jsonl(os.path.join(labels_dir, "label-harvest-posts-2026-08-10T000000Z.jsonl"), [
            label_record("at://r1", "intolerant", "2026-08-10T13:00:00Z", neg=False),
            label_record("at://r1", "intolerant", "2026-08-11T13:00:00Z", neg=True),  # retracted
        ])
        return store_path, scores_dir, labels_dir

    def test_full_run_writes_all_outputs(self):
        tmpdir = tempfile.mkdtemp()
        try:
            store_path, scores_dir, labels_dir = self._build_fixture(tmpdir)
            out_dir = os.path.join(tmpdir, "out")
            result = inc.run(store_path, scores_dir, labels_dir, out_dir, threshold=0.5)

            for name in ["a1_author_incivility.csv", "a2_escalation.csv",
                         "a3_moderation_coverage.csv", "incivility_structure_summary.md"]:
                self.assertTrue(os.path.exists(os.path.join(out_dir, name)), name)

            with open(os.path.join(out_dir, "a1_author_incivility.csv")) as handle:
                text = handle.read()
            self.assertIn("NOT HATE", text)
            self.assertIn("0.198", text)
            self.assertIn("0.946", text)

            with open(os.path.join(out_dir, "incivility_structure_summary.md")) as handle:
                md_text = handle.read()
            self.assertIn("0.198", md_text)
            self.assertIn("not hate", md_text.lower())
            self.assertIsNotNone(result)
        finally:
            shutil.rmtree(tmpdir)

    def test_allow_count_mismatch_flag_accepted_without_raising(self):
        tmpdir = tempfile.mkdtemp()
        try:
            store_path, scores_dir, labels_dir = self._build_fixture(tmpdir)
            out_dir = os.path.join(tmpdir, "out")
            # Internally-consistent fixture (no real mismatch is possible
            # here since A1/A2/A3 counts are derived from the same
            # scores/replies join they are checked against) -- this proves
            # the flag is wired through run()'s signature and does not
            # break a normal run. Mismatch-detection itself is exercised
            # directly in ReconciliationTests against assert_reconciliation.
            result = inc.run(store_path, scores_dir, labels_dir, out_dir,
                              threshold=0.5, allow_count_mismatch=True)
            self.assertIsNotNone(result)
        finally:
            shutil.rmtree(tmpdir)


if __name__ == "__main__":
    unittest.main()
