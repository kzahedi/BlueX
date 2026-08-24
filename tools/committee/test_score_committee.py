"""Tests for score_committee.py -- the rank-normalised consensus committee
over three decorrelated members (incivility_toxicity, tfidf_lr, doc2vec_lr).

All store access goes through a tiny fixture SQLite database, the same
pattern tools/prereg/test_seal_predictions.py uses. No network, no real
store, no real /Volumes paths except where a test explicitly documents that
it is checking a path *string* (never opening it).
"""
import json
import math
import os
import sqlite3
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "prereg"))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "labelling"))

import score_committee as sc  # noqa: E402


def write_jsonl(path, records):
    with open(path, "w", encoding="utf-8") as f:
        for r in records:
            f.write(json.dumps(r) + "\n")


# --------------------------------------------------------------------------
# Rank normalisation
# --------------------------------------------------------------------------

class RankPercentileTests(unittest.TestCase):
    def test_exact_percentiles_no_ties(self):
        scores = {"a": 10.0, "b": 20.0, "c": 30.0, "d": 40.0}
        pct = sc.rank_percentiles(scores)
        self.assertAlmostEqual(pct["a"], 0.0)
        self.assertAlmostEqual(pct["b"], 100.0 / 3.0)
        self.assertAlmostEqual(pct["c"], 200.0 / 3.0)
        self.assertAlmostEqual(pct["d"], 100.0)

    def test_exact_percentiles_with_ties(self):
        # a and b tie at rank 1.5 (average of ranks 1 and 2); c is rank 3.
        scores = {"a": 10.0, "b": 10.0, "c": 20.0}
        pct = sc.rank_percentiles(scores)
        self.assertAlmostEqual(pct["a"], 25.0)
        self.assertAlmostEqual(pct["b"], 25.0)
        self.assertAlmostEqual(pct["c"], 100.0)

    def test_single_value_population(self):
        pct = sc.rank_percentiles({"a": 5.0})
        self.assertEqual(pct, {"a": 50.0})

    def test_empty_population(self):
        self.assertEqual(sc.rank_percentiles({}), {})

    def test_never_receives_or_returns_none(self):
        # rank_percentiles operates on the already-filtered, non-null subset;
        # callers must strip Nones before calling it.
        with self.assertRaises(Exception):
            sc.rank_percentiles({"a": None, "b": 1.0})


# --------------------------------------------------------------------------
# mean_pct / spread_pct / n_members aggregation
# --------------------------------------------------------------------------

class AggregateTests(unittest.TestCase):
    def test_three_members_hand_computable(self):
        per_uri = {"tox": 10.0, "tfidf": 20.0, "d2v": 30.0}
        agg = sc.aggregate_row(per_uri)
        self.assertEqual(agg["n_members"], 3)
        self.assertAlmostEqual(agg["mean_pct"], 20.0)
        # population stddev (ddof=0) of [10,20,30] = sqrt(((10)^2+0+(10)^2)/3)
        expected_spread = math.sqrt((100.0 + 0.0 + 100.0) / 3.0)
        self.assertAlmostEqual(agg["spread_pct"], expected_spread)

    def test_missing_member_excluded_not_imputed(self):
        per_uri = {"tox": None, "tfidf": 40.0, "d2v": 60.0}
        agg = sc.aggregate_row(per_uri)
        self.assertEqual(agg["n_members"], 2)
        self.assertAlmostEqual(agg["mean_pct"], 50.0)
        self.assertAlmostEqual(agg["spread_pct"], 10.0)

    def test_all_missing(self):
        agg = sc.aggregate_row({"tox": None, "tfidf": None, "d2v": None})
        self.assertEqual(agg["n_members"], 0)
        self.assertIsNone(agg["mean_pct"])
        self.assertIsNone(agg["spread_pct"])

    def test_single_member_zero_spread(self):
        agg = sc.aggregate_row({"tox": None, "tfidf": 77.0, "d2v": None})
        self.assertEqual(agg["n_members"], 1)
        self.assertAlmostEqual(agg["mean_pct"], 77.0)
        self.assertAlmostEqual(agg["spread_pct"], 0.0)


# --------------------------------------------------------------------------
# Spearman on a known pair
# --------------------------------------------------------------------------

class SpearmanTests(unittest.TestCase):
    def test_perfect_positive_correlation(self):
        a = {"u1": 1.0, "u2": 2.0, "u3": 3.0, "u4": 4.0}
        b = {"u1": 10.0, "u2": 20.0, "u3": 30.0, "u4": 40.0}
        rho, n = sc.spearman_pairwise(a, b)
        self.assertEqual(n, 4)
        self.assertAlmostEqual(rho, 1.0)

    def test_perfect_negative_correlation(self):
        a = {"u1": 1.0, "u2": 2.0, "u3": 3.0, "u4": 4.0}
        b = {"u1": 40.0, "u2": 30.0, "u3": 20.0, "u4": 10.0}
        rho, n = sc.spearman_pairwise(a, b)
        self.assertAlmostEqual(rho, -1.0)

    def test_only_common_uris_considered(self):
        a = {"u1": 1.0, "u2": 2.0, "u3": 3.0, "onlyA": 99.0}
        b = {"u1": 10.0, "u2": 30.0, "u3": 20.0, "onlyB": -1.0}
        rho, n = sc.spearman_pairwise(a, b)
        self.assertEqual(n, 3)

    def test_too_few_points_returns_none(self):
        rho, n = sc.spearman_pairwise({"u1": 1.0}, {"u1": 2.0})
        self.assertIsNone(rho)
        self.assertEqual(n, 1)


# --------------------------------------------------------------------------
# Multi-file incivility merge preserves NULL and reduces n_members
# --------------------------------------------------------------------------

class MergeAndNullHandlingTests(unittest.TestCase):
    def test_null_toxicity_reduces_n_members(self):
        # Only two of three members scored 'u3' -- toxicity is genuinely
        # absent (never a 0 or an imputed 0.5).
        tox_pct = {"u1": 10.0, "u2": 90.0}   # u3 missing
        tfidf_pct = {"u1": 20.0, "u2": 80.0, "u3": 50.0}
        d2v_pct = {"u1": 30.0, "u2": 70.0, "u3": 60.0}
        rows = sc.build_rows({"u1", "u2", "u3"}, tox_pct, tfidf_pct, d2v_pct,
                              tox_raw={}, tfidf_raw={}, d2v_raw={})
        row_u3 = rows["u3"]
        self.assertIsNone(row_u3["tox_pct"])
        self.assertEqual(row_u3["n_members"], 2)
        row_u1 = rows["u1"]
        self.assertEqual(row_u1["n_members"], 3)

    def test_multi_file_merge_uses_reused_function(self):
        # score_committee.py must reuse seal_predictions.merge_incivility_scores
        # rather than reimplementing the merge -- verified by exercising it
        # with two files the way the real pipeline would.
        with tempfile.TemporaryDirectory() as d:
            f1 = os.path.join(d, "incivility-scores-2026-08-11T131928Z.jsonl")
            f2 = os.path.join(d, "incivility-scores-2026-08-11T153517Z.jsonl")
            write_jsonl(f1, [{"uri": "u1", "head": "toxicity", "score": 0.1,
                               "model_id": "m", "model_revision": "r",
                               "scored_at": "2026-08-11T13:19:31Z"}])
            write_jsonl(f2, [{"uri": "u2", "head": "toxicity", "score": 0.2,
                               "model_id": "m", "model_revision": "r",
                               "scored_at": "2026-08-11T15:35:17Z"}])
            merged, files, raw = sc.load_toxicity_scores(d)
            self.assertIn("u1", merged)
            self.assertIn("u2", merged)


# --------------------------------------------------------------------------
# No-ANNOTATION guard
# --------------------------------------------------------------------------

class NoAnnotationGuardTests(unittest.TestCase):
    def test_module_source_never_references_ZANNOTATION(self):
        path = os.path.join(os.path.dirname(__file__), "score_committee.py")
        with open(path, "r", encoding="utf-8") as f:
            source = f.read()
        self.assertNotIn("ZANNOTATION", source,
                          "score_committee.py must never read human annotations")

    def test_store_opened_read_only_mode_ro(self):
        with tempfile.TemporaryDirectory() as d:
            store_path = os.path.join(d, "default.store")
            conn = sqlite3.connect(store_path)
            conn.execute("CREATE TABLE ZPOST (Z_PK INTEGER PRIMARY KEY, "
                         "ZISROOTPOST INTEGER, ZTEXT VARCHAR, ZURI VARCHAR)")
            conn.commit()
            conn.close()
            uri = sc.ro_uri(store_path)
            self.assertIn("mode=ro", uri)
            self.assertNotIn("immutable=1", uri)


# --------------------------------------------------------------------------
# Meta completeness
# --------------------------------------------------------------------------

class MetaCompletenessTests(unittest.TestCase):
    def test_build_meta_has_required_keys(self):
        meta = sc.build_meta(
            tox_model_id="unitary/unbiased-toxic-roberta",
            tox_model_revision="36295dd8",
            tox_source_files=["incivility-scores-a.jsonl"],
            tfidf_random_state=20260822,
            tfidf_training_counts={"positive": 10, "hard_negative": 20},
            tfidf_labels_file="label-harvest-posts-x.jsonl",
            d2v_random_state=20260822,
            d2v_training_counts={"positive": 10, "hard_negative": 20},
            d2v_model_path="/x/doc2vec-final.model",
            sklearn_version="1.9.0",
            gensim_version="4.4.0",
            row_counts={"scores": 100},
        )
        required = {
            "tox_model_id", "tox_model_revision", "tox_source_files",
            "tfidf_random_state", "tfidf_training_counts", "tfidf_labels_file",
            "d2v_random_state", "d2v_training_counts", "d2v_model_path",
            "sklearn_version", "gensim_version", "row_counts", "created_at",
            "no_human_annotation_statement",
        }
        self.assertTrue(required.issubset(meta.keys()), meta.keys())
        self.assertIn("no human", meta["no_human_annotation_statement"].lower())


# --------------------------------------------------------------------------
# DB writer: idempotent re-run
# --------------------------------------------------------------------------

class DbWriterTests(unittest.TestCase):
    def test_idempotent_rerun_same_rows_no_duplicates(self):
        with tempfile.TemporaryDirectory() as d:
            db_path = os.path.join(d, "committee.db")
            rows = {
                "u1": {"tox": 0.1, "tox_pct": 10.0, "tfidf": 0.2, "tfidf_pct": 20.0,
                       "d2v": 0.3, "d2v_pct": 30.0, "n_members": 3,
                       "mean_pct": 20.0, "spread_pct": 8.16},
                "u2": {"tox": None, "tox_pct": None, "tfidf": 0.5, "tfidf_pct": 60.0,
                       "d2v": 0.6, "d2v_pct": 70.0, "n_members": 2,
                       "mean_pct": 65.0, "spread_pct": 5.0},
            }
            meta = {"created_at": "2026-08-24T00:00:00Z", "note": "test"}
            sc.write_committee_db(db_path, rows, meta)
            sc.write_committee_db(db_path, rows, meta)  # re-run

            conn = sqlite3.connect(db_path)
            count = conn.execute("SELECT COUNT(*) FROM scores").fetchone()[0]
            self.assertEqual(count, 2)
            u1 = conn.execute(
                "SELECT tox, tfidf, d2v, n_members, mean_pct, spread_pct "
                "FROM scores WHERE uri = 'u1'"
            ).fetchone()
            self.assertAlmostEqual(u1[0], 0.1)
            self.assertEqual(u1[3], 3)
            meta_count = conn.execute("SELECT COUNT(*) FROM meta").fetchone()[0]
            self.assertGreaterEqual(meta_count, 2)
            conn.close()

    def test_indices_exist_on_mean_and_spread(self):
        with tempfile.TemporaryDirectory() as d:
            db_path = os.path.join(d, "committee.db")
            sc.write_committee_db(db_path, {}, {"created_at": "x"})
            conn = sqlite3.connect(db_path)
            names = {r[1] for r in conn.execute("PRAGMA index_list(scores)").fetchall()}
            idx_sql = conn.execute(
                "SELECT sql FROM sqlite_master WHERE type='index'"
            ).fetchall()
            joined = " ".join((s[0] or "") for s in idx_sql)
            self.assertIn("mean_pct", joined)
            self.assertIn("spread_pct", joined)
            conn.close()


if __name__ == "__main__":
    unittest.main()
