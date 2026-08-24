"""Tests for seal_doc2vec_predictions.py -- the post-hoc, honestly-scoped
seal of the doc2vec_lr committee member for posts NOT already covered by
the original two-model Stage 0 pre-registration.

Fixture SQLite stores mirror the real Z-schema, same pattern as
test_seal_predictions.py. A tiny fake gensim-like KeyedVectors stand-in
avoids depending on the real (huge) doc2vec model in unit tests.
"""
import gzip
import json
import os
import sqlite3
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "labelling"))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "committee"))

import seal_doc2vec_predictions as sdp  # noqa: E402


def make_store(path, posts, annotations=None):
    """posts: list of dicts {uri, text}. annotations: list of dicts
    {post_pk (1-based index into posts)} -- values other than the join are
    irrelevant here since this module must read URIs only."""
    annotations = annotations or []
    conn = sqlite3.connect(path)
    conn.execute(
        "CREATE TABLE ZPOST (Z_PK INTEGER PRIMARY KEY, ZISROOTPOST INTEGER, "
        "ZTEXT VARCHAR, ZURI VARCHAR)"
    )
    conn.execute(
        "CREATE TABLE ZANNOTATION (Z_PK INTEGER PRIMARY KEY, ZPOST INTEGER, "
        "ZSPEECHCLASS VARCHAR, ZSTAGE VARCHAR)"
    )
    for i, p in enumerate(posts, start=1):
        conn.execute(
            "INSERT INTO ZPOST (Z_PK, ZISROOTPOST, ZTEXT, ZURI) VALUES (?, 0, ?, ?)",
            (i, p["text"], p["uri"]),
        )
    for a in annotations:
        conn.execute(
            "INSERT INTO ZANNOTATION (ZPOST, ZSPEECHCLASS, ZSTAGE) VALUES (?, 'hate', 'human')",
            (a["post_pk"],),
        )
    conn.commit()
    conn.close()


class FakeDV(dict):
    """Minimal stand-in for gensim's KeyedVectors dv: supports `in`,
    `__getitem__`, and `.index_to_key`."""
    @property
    def index_to_key(self):
        return list(self.keys())


class FakeModel:
    def __init__(self, dv):
        self.dv = dv


# --------------------------------------------------------------------------
# ZANNOTATION-URI-only exclusion read
# --------------------------------------------------------------------------

class FetchLabelledUrisTests(unittest.TestCase):
    def test_reads_uris_only_not_label_values(self):
        with tempfile.TemporaryDirectory() as d:
            store_path = os.path.join(d, "default.store")
            make_store(store_path, [
                {"uri": "u1", "text": "a"},
                {"uri": "u2", "text": "b"},
                {"uri": "u3", "text": "c"},
            ], annotations=[{"post_pk": 1}, {"post_pk": 3}])
            conn = sqlite3.connect(sdp.sp.ro_uri(store_path), uri=True)
            try:
                uris = sdp.fetch_labelled_uris_readonly(conn)
            finally:
                conn.close()
            self.assertEqual(uris, {"u1", "u3"})

    def test_no_annotations_yet_returns_empty_set(self):
        with tempfile.TemporaryDirectory() as d:
            store_path = os.path.join(d, "default.store")
            make_store(store_path, [{"uri": "u1", "text": "a"}])
            conn = sqlite3.connect(sdp.sp.ro_uri(store_path), uri=True)
            try:
                uris = sdp.fetch_labelled_uris_readonly(conn)
            finally:
                conn.close()
            self.assertEqual(uris, set())


# --------------------------------------------------------------------------
# Excluded-pool arithmetic (pure function, no I/O)
# --------------------------------------------------------------------------

class UnlabelledPoolTests(unittest.TestCase):
    def test_excludes_labelled_uris(self):
        population = {"u1", "u2", "u3", "u4"}
        excluded = {"u2", "u4"}
        pool = sdp.unlabelled_pool(population, excluded)
        self.assertEqual(pool, {"u1", "u3"})

    def test_excluded_uri_not_in_population_is_harmless(self):
        population = {"u1", "u2"}
        excluded = {"u2", "unrelated"}
        pool = sdp.unlabelled_pool(population, excluded)
        self.assertEqual(pool, {"u1"})


# --------------------------------------------------------------------------
# Seal writes records ONLY for the unlabelled pool
# --------------------------------------------------------------------------

class WriteSealedFileTests(unittest.TestCase):
    def test_only_unlabelled_uris_written(self):
        with tempfile.TemporaryDirectory() as d:
            out_path = os.path.join(d, "sealed-doc2vec.jsonl.gz")
            scores = {"u1": 0.2, "u3": 0.7}  # already excludes u2 by construction
            sdp.write_sealed_doc2vec_file(out_path, scores)
            with gzip.open(out_path, "rt", encoding="utf-8") as f:
                recs = [json.loads(line) for line in f]
            uris = {r["uri"] for r in recs}
            self.assertEqual(uris, {"u1", "u3"})
            for r in recs:
                self.assertEqual(r["model"], "doc2vec_lr")
                self.assertIn("meaning", r)


# --------------------------------------------------------------------------
# Manifest honesty: states post-hoc status for excluded/labelled posts
# --------------------------------------------------------------------------

class ManifestTests(unittest.TestCase):
    def test_manifest_states_posthoc_and_counts(self):
        manifest = sdp.build_manifest(
            sealed_file="sealed-doc2vec-x.jsonl.gz",
            sha256="deadbeef",
            n_sealed=100,
            n_excluded_labelled=76,
            exclusion_source="store_readonly_uris_only",
            training_counts={"positive": 10, "hard_negative": 20},
            random_state=20260822,
            sklearn_version="1.9.0",
            gensim_version="4.4.0",
            d2v_model_path="/x/doc2vec-final.model",
            labels_file="label-harvest-posts-x.jsonl",
        )
        self.assertEqual(manifest["n_sealed"], 100)
        self.assertEqual(manifest["n_excluded_labelled"], 76)
        text = json.dumps(manifest).lower()
        self.assertIn("post-hoc", text)
        self.assertIn("doc2vec_lr", text)


if __name__ == "__main__":
    unittest.main()
