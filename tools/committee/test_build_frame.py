"""Tests for build_frame.py -- the stratified labelling frame-file generator.

Uses a small synthetic committee.db fixture (never the real
/Volumes/Eregion/bluex-data/committee/committee.db) so thresholds and
population sizes are hand-checkable. No network, no real store, except
where a test explicitly builds a throwaway SQLite file to exercise the
ZANNOTATION-URI exclusion path.
"""
import json
import os
import re
import sqlite3
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(__file__))

import build_frame as bf  # noqa: E402


SCORES_SCHEMA = """
CREATE TABLE scores (
    uri TEXT PRIMARY KEY,
    tox REAL, tox_pct REAL,
    tfidf REAL, tfidf_pct REAL,
    d2v REAL, d2v_pct REAL,
    n_members INTEGER,
    mean_pct REAL, spread_pct REAL,
    mean_pct_full REAL, spread_pct_full REAL
)
"""


def make_committee_db(path, rows):
    """rows: list of dicts with keys matching the scores columns (missing
    keys default to None)."""
    conn = sqlite3.connect(path)
    conn.execute(SCORES_SCHEMA)
    conn.execute("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)")
    cols = ["uri", "tox", "tox_pct", "tfidf", "tfidf_pct", "d2v", "d2v_pct",
            "n_members", "mean_pct", "spread_pct", "mean_pct_full", "spread_pct_full"]
    for r in rows:
        conn.execute(
            "INSERT INTO scores (%s) VALUES (%s)" % (", ".join(cols), ", ".join(["?"] * len(cols))),
            [r.get(c) for c in cols],
        )
    conn.commit()
    conn.close()


def synthetic_rows(n=1000):
    """1000 uris, uniformly spread percentiles 0..99.9 on every member, all
    three members present except a deliberate 'missing tox' subset (u_miss_*)
    so tox_missing has a non-trivial population."""
    rows = []
    for i in range(n):
        pct = i / (n - 1) * 100.0
        rows.append({
            "uri": "at://u%04d" % i,
            "tox": pct / 100.0, "tox_pct": pct,
            "tfidf": pct / 100.0, "tfidf_pct": pct,
            "d2v": pct / 100.0, "d2v_pct": pct,
            "n_members": 3,
            "mean_pct": pct, "spread_pct": 0.0,
            "mean_pct_full": pct, "spread_pct_full": 0.0,
        })
    # 50 posts missing the toxicity member entirely
    for i in range(50):
        rows.append({
            "uri": "at://miss%03d" % i,
            "tox": None, "tox_pct": None,
            "tfidf": 0.5, "tfidf_pct": 50.0,
            "d2v": 0.5, "d2v_pct": 50.0,
            "n_members": 2,
            "mean_pct": 50.0, "spread_pct": 0.0,
            "mean_pct_full": None, "spread_pct_full": None,
        })
    return rows


class ThresholdTests(unittest.TestCase):
    def test_percentile_thresholds_hand_computable(self):
        with tempfile.TemporaryDirectory() as d:
            db_path = os.path.join(d, "committee.db")
            # 0..100 inclusive, 101 values -> exact percentile = value itself
            rows = [{"uri": "u%03d" % i, "tox_pct": float(i), "tfidf_pct": float(i),
                     "d2v_pct": float(i), "n_members": 3,
                     "mean_pct_full": float(i), "spread_pct_full": float(i)}
                    for i in range(101)]
            make_committee_db(db_path, rows)
            conn = sqlite3.connect(db_path)
            p99 = bf.percentile(conn, "tox_pct", 99)
            p50 = bf.percentile(conn, "mean_pct_full", 50)
            conn.close()
            self.assertAlmostEqual(p99, 99.0, delta=0.5)
            self.assertAlmostEqual(p50, 50.0, delta=0.5)

    def test_thresholds_recorded_verbatim_in_definition(self):
        with tempfile.TemporaryDirectory() as d:
            db_path = os.path.join(d, "committee.db")
            make_committee_db(db_path, synthetic_rows())
            thresholds = bf.compute_thresholds(sqlite3.connect(db_path))
            strata = bf.build_strata_specs(thresholds)
            tox_stratum = next(s for s in strata if s["id"] == "tox_top_1")
            self.assertIn(("%.4f" % thresholds["tox_p99"]), tox_stratum["definition"])


class PopulationSizeTests(unittest.TestCase):
    def test_population_size_is_true_stratum_size_not_sample_size(self):
        with tempfile.TemporaryDirectory() as d:
            db_path = os.path.join(d, "committee.db")
            make_committee_db(db_path, synthetic_rows(1000))
            conn = sqlite3.connect(db_path)
            thresholds = bf.compute_thresholds(conn)
            strata = bf.build_strata_specs(thresholds)
            tox_stratum = next(s for s in strata if s["id"] == "tox_top_1")
            pop = bf.population_size(conn, tox_stratum["sql_where"])
            conn.close()
            # top 1% of 1000 uniformly spread values ~ 10-11 posts
            self.assertGreater(pop, 5)
            self.assertLess(pop, 20)
            # sampling only 25 requested but population is small -- population_size
            # must report the true (small) population, not the requested sample n
            self.assertNotEqual(pop, 25)


class SamplingReproducibilityTests(unittest.TestCase):
    def _build(self, d):
        db_path = os.path.join(d, "committee.db")
        make_committee_db(db_path, synthetic_rows(1000))
        return db_path

    def test_same_seed_same_sample(self):
        with tempfile.TemporaryDirectory() as d:
            db_path = self._build(d)
            frame1 = bf.build_frame(db_path, seed=42, n_per_stratum={}, exclude_uris=set())
            frame2 = bf.build_frame(db_path, seed=42, n_per_stratum={}, exclude_uris=set())
            uris1 = {s["id"]: s["uris"] for s in frame1["strata"]}
            uris2 = {s["id"]: s["uris"] for s in frame2["strata"]}
            self.assertEqual(uris1, uris2)

    def test_different_seed_different_sample(self):
        with tempfile.TemporaryDirectory() as d:
            db_path = self._build(d)
            frame1 = bf.build_frame(db_path, seed=1, n_per_stratum={}, exclude_uris=set())
            frame2 = bf.build_frame(db_path, seed=2, n_per_stratum={}, exclude_uris=set())
            uris1 = {s["id"]: s["uris"] for s in frame1["strata"]}
            uris2 = {s["id"]: s["uris"] for s in frame2["strata"]}
            self.assertNotEqual(uris1, uris2)


class ExclusionTests(unittest.TestCase):
    def test_already_labelled_uris_excluded_from_samples(self):
        with tempfile.TemporaryDirectory() as d:
            db_path = os.path.join(d, "committee.db")
            rows = synthetic_rows(1000)
            make_committee_db(db_path, rows)
            all_uris = {r["uri"] for r in rows}
            exclude = set(list(all_uris)[:500])  # exclude half the corpus
            frame = bf.build_frame(db_path, seed=42, n_per_stratum={}, exclude_uris=exclude)
            for stratum in frame["strata"]:
                for uri in stratum["uris"]:
                    self.assertNotIn(uri, exclude)

    def test_exclude_file_plain_text_lines(self):
        with tempfile.TemporaryDirectory() as d:
            exclude_path = os.path.join(d, "exclude.txt")
            with open(exclude_path, "w", encoding="utf-8") as f:
                f.write("at://a\nat://b\n\nat://c\n")
            uris = bf.load_exclude_file(exclude_path)
            self.assertEqual(uris, {"at://a", "at://b", "at://c"})

    def test_exclude_file_json_array(self):
        with tempfile.TemporaryDirectory() as d:
            exclude_path = os.path.join(d, "exclude.json")
            with open(exclude_path, "w", encoding="utf-8") as f:
                json.dump(["at://x", "at://y"], f)
            uris = bf.load_exclude_file(exclude_path)
            self.assertEqual(uris, {"at://x", "at://y"})

    def test_read_labelled_uris_from_store_reads_no_label_values(self):
        # The isolated read-only exclusion path must read URIs ONLY, never
        # ZSPEECHCLASS or any other label value. Verify against a synthetic
        # store fixture with a ZPOST<->ZANNOTATION join.
        with tempfile.TemporaryDirectory() as d:
            store_path = os.path.join(d, "default.store")
            conn = sqlite3.connect(store_path)
            conn.execute("CREATE TABLE ZPOST (Z_PK INTEGER PRIMARY KEY, ZURI VARCHAR)")
            conn.execute("CREATE TABLE ZANNOTATION (Z_PK INTEGER PRIMARY KEY, "
                         "ZPOST INTEGER, ZSTAGE VARCHAR, ZSPEECHCLASS VARCHAR)")
            conn.execute("INSERT INTO ZPOST (Z_PK, ZURI) VALUES (1, 'at://labelled1')")
            conn.execute("INSERT INTO ZPOST (Z_PK, ZURI) VALUES (2, 'at://unlabelled')")
            conn.execute("INSERT INTO ZANNOTATION (ZPOST, ZSTAGE, ZSPEECHCLASS) "
                         "VALUES (1, 'human', 'hate')")
            conn.commit()
            conn.close()
            uris = bf.read_labelled_uris_from_store(store_path)
            self.assertEqual(uris, {"at://labelled1"})

    def test_source_never_selects_zspeechclass_or_zseverity(self):
        path = os.path.join(os.path.dirname(__file__), "build_frame.py")
        with open(path, "r", encoding="utf-8") as f:
            source = f.read()
        # the URI-only exclusion function must be isolated and never SELECT
        # any label-value column
        func_match = re.search(
            r"def read_labelled_uris_from_store.*?(?=\ndef |\Z)", source, re.S)
        self.assertIsNotNone(func_match)
        body = func_match.group(0)
        self.assertNotIn("ZSPEECHCLASS", body)
        self.assertNotIn("ZSEVERITY", body)
        self.assertNotIn("ZCONFIDENCE", body)


class NoScoresLeakTests(unittest.TestCase):
    def test_no_numeric_score_fields_in_per_uri_payload(self):
        with tempfile.TemporaryDirectory() as d:
            db_path = os.path.join(d, "committee.db")
            make_committee_db(db_path, synthetic_rows(1000))
            frame = bf.build_frame(db_path, seed=42, n_per_stratum={}, exclude_uris=set())
            forbidden = {"tox", "tox_pct", "tfidf", "tfidf_pct", "d2v", "d2v_pct",
                         "mean_pct", "spread_pct", "mean_pct_full", "spread_pct_full",
                         "n_members", "score", "percentile"}
            for stratum in frame["strata"]:
                for uri in stratum["uris"]:
                    self.assertIsInstance(uri, str)
                # the stratum object itself must not carry per-uri scores either
                self.assertTrue(set(stratum.keys()).isdisjoint(forbidden))

    def test_frame_json_round_trip_has_no_score_keys_anywhere_in_uris(self):
        with tempfile.TemporaryDirectory() as d:
            db_path = os.path.join(d, "committee.db")
            make_committee_db(db_path, synthetic_rows(1000))
            frame = bf.build_frame(db_path, seed=42, n_per_stratum={}, exclude_uris=set())
            dumped = json.dumps(frame)
            # every uris entry must be a plain string, not an object -- catches
            # any future accidental {"uri":..., "score":...} shape
            reparsed = json.loads(dumped)
            for stratum in reparsed["strata"]:
                for u in stratum["uris"]:
                    self.assertIsInstance(u, str)


class NoBareMeanPctStratumTests(unittest.TestCase):
    def test_no_stratum_defined_on_bare_mean_pct(self):
        with tempfile.TemporaryDirectory() as d:
            db_path = os.path.join(d, "committee.db")
            make_committee_db(db_path, synthetic_rows(1000))
            conn = sqlite3.connect(db_path)
            thresholds = bf.compute_thresholds(conn)
            conn.close()
            strata = bf.build_strata_specs(thresholds)
            bare_mean_pct = re.compile(r"(?<!_full)\bmean_pct\b(?!_full)")
            bare_spread_pct = re.compile(r"(?<!_full)\bspread_pct\b(?!_full)")
            for s in strata:
                self.assertIsNone(bare_mean_pct.search(s["definition"]),
                                   s["definition"])
                self.assertIsNone(bare_spread_pct.search(s["definition"]),
                                   s["definition"])
                self.assertIsNone(bare_mean_pct.search(s["sql_where"]), s["sql_where"])
                self.assertIsNone(bare_spread_pct.search(s["sql_where"]), s["sql_where"])

    def test_generator_refuses_a_bare_mean_pct_stratum_spec(self):
        with self.assertRaises(ValueError):
            bf.validate_stratum_definition("bad", "mean_pct >= 99.9")


class EmptyStratumHonestyTests(unittest.TestCase):
    def test_empty_stratum_reported_not_omitted(self):
        with tempfile.TemporaryDirectory() as d:
            db_path = os.path.join(d, "committee.db")
            # No posts at all match an impossible threshold-free scenario:
            # use a single row so tox_missing (tox_pct IS NULL) is empty.
            rows = [{"uri": "at://only1", "tox": 0.5, "tox_pct": 50.0,
                     "tfidf": 0.5, "tfidf_pct": 50.0, "d2v": 0.5, "d2v_pct": 50.0,
                     "n_members": 3, "mean_pct": 50.0, "spread_pct": 0.0,
                     "mean_pct_full": 50.0, "spread_pct_full": 0.0}]
            make_committee_db(db_path, rows)
            frame = bf.build_frame(db_path, seed=42, n_per_stratum={}, exclude_uris=set())
            tox_missing = next(s for s in frame["strata"] if s["id"] == "tox_missing")
            self.assertEqual(tox_missing["population_size"], 0)
            self.assertEqual(tox_missing["uris"], [])
            self.assertIn("tox_missing", {s["id"] for s in frame["strata"]})


class FrameFileShapeTests(unittest.TestCase):
    def test_frame_has_required_top_level_fields(self):
        with tempfile.TemporaryDirectory() as d:
            db_path = os.path.join(d, "committee.db")
            make_committee_db(db_path, synthetic_rows(1000))
            frame = bf.build_frame(db_path, seed=7, n_per_stratum={}, exclude_uris=set())
            for key in ("frame_kind", "created_at", "committee", "population_total",
                        "strata", "seed"):
                self.assertIn(key, frame)
            self.assertEqual(frame["frame_kind"], "stratified")
            self.assertIn("db_sha256", frame["committee"])
            self.assertIn("members", frame["committee"])

    def test_n_per_stratum_override_respected(self):
        with tempfile.TemporaryDirectory() as d:
            db_path = os.path.join(d, "committee.db")
            make_committee_db(db_path, synthetic_rows(2000))
            frame = bf.build_frame(db_path, seed=7, n_per_stratum={"tox_top_1": 3},
                                    exclude_uris=set())
            tox_stratum = next(s for s in frame["strata"] if s["id"] == "tox_top_1")
            self.assertLessEqual(len(tox_stratum["uris"]), 3)

    def test_all_eight_strata_present(self):
        with tempfile.TemporaryDirectory() as d:
            db_path = os.path.join(d, "committee.db")
            make_committee_db(db_path, synthetic_rows(2000))
            frame = bf.build_frame(db_path, seed=7, n_per_stratum={}, exclude_uris=set())
            ids = {s["id"] for s in frame["strata"]}
            expected = {"mean_full_top_0.1", "tox_top_1", "tfidf_top_1", "d2v_top_1",
                        "spread_full_top_1", "tox_missing", "mid", "bottom"}
            self.assertEqual(ids, expected)


if __name__ == "__main__":
    unittest.main()
