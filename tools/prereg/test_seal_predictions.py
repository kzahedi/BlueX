"""Tests for seal_predictions.py.

All store access goes through a tiny fixture SQLite database mirroring the
real Z-schema (ZPOST, ZANNOTATION, ZLABELBATCH) the way test_base_rate.py
does for base_rate.py. Score/label inputs are tiny synthetic JSONL fixtures
under a temp dir. No network, no real store, no real /Volumes paths.
"""
import gzip
import json
import os
import sqlite3
import sys
import tempfile
import unittest
import uuid

sys.path.insert(0, os.path.dirname(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "labelling"))

import seal_predictions as sp
import base_rate as br


# --------------------------------------------------------------------------
# Fixture builders
# --------------------------------------------------------------------------

def make_store(path, posts, annotations=None, batches=None):
    """posts: list of dicts {uri, text, is_root=False}.
    annotations: list of dicts {post_pk (1-based index into posts, or None),
        speech_class, stage='human', batch_id: uuid|None, pass_number}.
    batches: list of dicts {id: uuid, kind, pass_number}.
    """
    annotations = annotations or []
    batches = batches or []
    conn = sqlite3.connect(path)
    conn.execute(
        "CREATE TABLE ZPOST (Z_PK INTEGER PRIMARY KEY, ZISROOTPOST INTEGER, "
        "ZTEXT VARCHAR, ZURI VARCHAR)"
    )
    conn.execute(
        "CREATE TABLE ZANNOTATION (Z_PK INTEGER PRIMARY KEY, ZPOST INTEGER, "
        "ZSPEECHCLASS VARCHAR, ZSTAGE VARCHAR, ZBATCHID BLOB, ZPASSNUMBER INTEGER)"
    )
    conn.execute(
        "CREATE TABLE ZLABELBATCH (Z_PK INTEGER PRIMARY KEY, ZID BLOB, "
        "ZFRAMEJSON VARCHAR, ZPASSNUMBER INTEGER)"
    )
    for i, p in enumerate(posts, start=1):
        conn.execute(
            "INSERT INTO ZPOST (Z_PK, ZISROOTPOST, ZTEXT, ZURI) VALUES (?, ?, ?, ?)",
            (i, 1 if p.get("is_root") else 0, p["text"], p["uri"]),
        )
    for b in batches:
        conn.execute(
            "INSERT INTO ZLABELBATCH (ZID, ZFRAMEJSON, ZPASSNUMBER) VALUES (?, ?, ?)",
            (str(b["id"]), json.dumps({"kind": b["kind"]}), b["pass_number"]),
        )
    for a in annotations:
        conn.execute(
            "INSERT INTO ZANNOTATION (ZPOST, ZSPEECHCLASS, ZSTAGE, ZBATCHID, ZPASSNUMBER) "
            "VALUES (?, ?, ?, ?, ?)",
            (
                a.get("post_pk"),
                a["speech_class"],
                a.get("stage", "human"),
                str(a["batch_id"]) if a.get("batch_id") else None,
                a.get("pass_number"),
            ),
        )
    conn.commit()
    conn.close()


def write_jsonl(path, records):
    with open(path, "w", encoding="utf-8") as f:
        for r in records:
            f.write(json.dumps(r) + "\n")


# --------------------------------------------------------------------------
# Pure helper tests
# --------------------------------------------------------------------------

class Sha256Tests(unittest.TestCase):
    def test_sha256_file_matches_known_hash(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "f.bin")
            with open(path, "wb") as f:
                f.write(b"hello world")
            import hashlib
            expected = hashlib.sha256(b"hello world").hexdigest()
            self.assertEqual(sp.sha256_file(path), expected)


class MergeIncivilityScoresTests(unittest.TestCase):
    def test_merges_multiple_files_not_just_newest(self):
        with tempfile.TemporaryDirectory() as d:
            f1 = os.path.join(d, "incivility-scores-2026-08-11T131928Z.jsonl")
            f2 = os.path.join(d, "incivility-scores-2026-08-11T153517Z.jsonl")
            write_jsonl(f1, [
                {"uri": "u1", "head": "toxicity", "score": 0.1, "model_id": "m",
                 "model_revision": "r", "scored_at": "2026-08-11T13:19:31Z"},
                {"uri": "u1", "head": "identity_attack", "score": 0.9, "model_id": "m",
                 "model_revision": "r", "scored_at": "2026-08-11T13:19:31Z"},
            ])
            write_jsonl(f2, [
                {"uri": "u2", "head": "toxicity", "score": 0.2, "model_id": "m",
                 "model_revision": "r", "scored_at": "2026-08-11T15:35:17Z"},
            ])
            merged = sp.merge_incivility_scores([f1, f2])
            # both files' toxicity scores present -- the bug this guards against
            # is using only the newest file and silently dropping f1's uri.
            self.assertIn("u1", merged)
            self.assertIn("u2", merged)
            self.assertEqual(merged["u1"][0], 0.1)
            self.assertEqual(merged["u2"][0], 0.2)
            # identity_attack head must never leak into the toxicity dict
            self.assertEqual(len(merged), 2)

    def test_duplicate_uri_across_files_keeps_most_recent_scored_at(self):
        with tempfile.TemporaryDirectory() as d:
            f1 = os.path.join(d, "incivility-scores-a.jsonl")
            f2 = os.path.join(d, "incivility-scores-b.jsonl")
            write_jsonl(f1, [
                {"uri": "u1", "head": "toxicity", "score": 0.1, "model_id": "m",
                 "model_revision": "r", "scored_at": "2026-08-11T10:00:00Z"},
            ])
            write_jsonl(f2, [
                {"uri": "u1", "head": "toxicity", "score": 0.9, "model_id": "m",
                 "model_revision": "r", "scored_at": "2026-08-12T10:00:00Z"},
            ])
            merged = sp.merge_incivility_scores([f1, f2])
            self.assertEqual(merged["u1"][0], 0.9)


class ClassifySubjectTests(unittest.TestCase):
    def test_positive_values(self):
        for val in ("intolerant", "threat", "extremist", "intolerant-race"):
            self.assertEqual(sp.classify_subject([val]), "positive")

    def test_hard_negative(self):
        self.assertEqual(sp.classify_subject(["rude"]), "hard_negative")

    def test_unrecognized_is_none(self):
        self.assertIsNone(sp.classify_subject(["spam"]))


# --------------------------------------------------------------------------
# The guard: refuse to seal if the store already has human annotations
# --------------------------------------------------------------------------

class GuardTests(unittest.TestCase):
    def test_seal_refuses_when_human_labels_exist(self):
        with tempfile.TemporaryDirectory() as d:
            store = os.path.join(d, "default.store")
            make_store(store, posts=[{"uri": "u1", "text": "hello"}],
                       annotations=[{"post_pk": 1, "speech_class": "hate"}])
            conn = sqlite3.connect(store)
            self.assertTrue(sp.store_has_human_annotations(conn))
            conn.close()

            rc = sp.main([
                "seal", "--store", store,
                "--incivility-dir", d, "--labels-dir", d,
                "--predictions-dir", os.path.join(d, "predictions"),
                "--manifest-dir", os.path.join(d, "manifest"),
            ])
            self.assertNotEqual(rc, 0)
            self.assertFalse(os.path.exists(os.path.join(d, "predictions")))

    def test_store_has_human_annotations_false_when_empty(self):
        with tempfile.TemporaryDirectory() as d:
            store = os.path.join(d, "default.store")
            make_store(store, posts=[{"uri": "u1", "text": "hello"}])
            conn = sqlite3.connect(store)
            self.assertFalse(sp.store_has_human_annotations(conn))
            conn.close()


# --------------------------------------------------------------------------
# End-to-end seal() on synthetic data
# --------------------------------------------------------------------------

def build_seal_fixture(d):
    """Build a small store + label file + 2 incivility score files under d.
    Returns dict of paths."""
    store = os.path.join(d, "default.store")

    # Training text needs repeated tokens so TfidfVectorizer(min_df=2) keeps
    # a non-empty vocabulary on this tiny synthetic set.
    positive_texts = [
        "you filthy immigrants should all be deported now",
        "immigrants like you filthy people ruin this country",
        "those filthy immigrants deserve nothing but hatred",
    ]
    rude_texts = [
        "you are such an idiot get lost jerk",
        "what an idiot jerk you truly are",
        "idiot jerk nobody likes your posts",
    ]
    pool_texts = [
        "the weather today is sunny and pleasant outside",
        "immigrants and filthy jerks discuss local weather calmly",
        "i had a lovely quiet morning walk",
    ]

    posts = []
    for i, t in enumerate(positive_texts):
        posts.append({"uri": "at://pos/%d" % i, "text": t})
    for i, t in enumerate(rude_texts):
        posts.append({"uri": "at://rude/%d" % i, "text": t})
    for i, t in enumerate(pool_texts):
        posts.append({"uri": "at://pool/%d" % i, "text": t})
    # one post with empty text -- must never enter the pool
    posts.append({"uri": "at://empty/0", "text": ""})
    # one root post -- must never enter the pool
    posts.append({"uri": "at://root/0", "text": "a root post", "is_root": True})

    make_store(store, posts=posts)

    labels_path = os.path.join(d, "label-harvest-posts-fixture.jsonl")
    label_records = []
    for i in range(len(positive_texts)):
        label_records.append({"subject": "at://pos/%d" % i, "subject_type": "post",
                               "val": "intolerant", "neg": False})
    for i in range(len(rude_texts)):
        label_records.append({"subject": "at://rude/%d" % i, "subject_type": "post",
                               "val": "rude", "neg": False})
    # a negated label must never count
    label_records.append({"subject": "at://pool/0", "subject_type": "post",
                           "val": "intolerant", "neg": True})
    write_jsonl(labels_path, label_records)
    summary_path = labels_path[: -len(".jsonl")] + ".summary.json"
    with open(summary_path, "w", encoding="utf-8") as f:
        json.dump({"run_status": "complete"}, f)

    incivility_dir = os.path.join(d, "incivility")
    os.makedirs(incivility_dir, exist_ok=True)
    f1 = os.path.join(incivility_dir, "incivility-scores-2026-08-11T131928Z.jsonl")
    f2 = os.path.join(incivility_dir, "incivility-scores-2026-08-11T153517Z.jsonl")
    # pool/0 scored only in f1, pool/1 scored only in f2 -- covers the file
    # merge requirement. pool/2 has no score at all -- must come out null.
    write_jsonl(f1, [
        {"uri": "at://pool/0", "head": "toxicity", "score": 0.05, "model_id": "m",
         "model_revision": "rev1", "scored_at": "2026-08-11T13:19:31Z"},
    ])
    write_jsonl(f2, [
        {"uri": "at://pool/1", "head": "toxicity", "score": 0.9, "model_id": "m",
         "model_revision": "rev1", "scored_at": "2026-08-11T15:35:17Z"},
    ])

    return {
        "store": store,
        "labels_dir": d,
        "incivility_dir": incivility_dir,
        "predictions_dir": os.path.join(d, "predictions"),
        "manifest_dir": os.path.join(d, "manifest"),
    }


class SealEndToEndTests(unittest.TestCase):
    def test_seal_writes_predictions_and_manifest(self):
        with tempfile.TemporaryDirectory() as d:
            paths = build_seal_fixture(d)
            rc = sp.main([
                "seal", "--store", paths["store"],
                "--incivility-dir", paths["incivility_dir"],
                "--labels-dir", paths["labels_dir"],
                "--predictions-dir", paths["predictions_dir"],
                "--manifest-dir", paths["manifest_dir"],
                "--random-state", "42",
            ])
            self.assertEqual(rc, 0)

            pred_files = [f for f in os.listdir(paths["predictions_dir"])
                          if f.startswith("sealed-stage0-") and f.endswith(".jsonl.gz")]
            self.assertEqual(len(pred_files), 1)
            manifest_files = [f for f in os.listdir(paths["manifest_dir"])
                               if f.startswith("sealed-stage0-") and f.endswith(".json")]
            self.assertEqual(len(manifest_files), 1)

            pred_path = os.path.join(paths["predictions_dir"], pred_files[0])
            with gzip.open(pred_path, "rt", encoding="utf-8") as f:
                records = [json.loads(line) for line in f]

            # the pool is EVERY reply post with non-empty text (a superset of
            # any possible Stage 0 batch) -- 9 posts (pos/0-2, rude/0-2,
            # pool/0-2) x 2 models = 18 records. empty-text and root posts
            # must never appear.
            uris = {r["uri"] for r in records}
            expected_uris = {"at://pos/0", "at://pos/1", "at://pos/2",
                              "at://rude/0", "at://rude/1", "at://rude/2",
                              "at://pool/0", "at://pool/1", "at://pool/2"}
            self.assertEqual(uris, expected_uris)
            self.assertEqual(len(records), 18)

            by_uri_model = {(r["uri"], r["model"]): r["score"] for r in records}
            # null scores preserved, never imputed
            self.assertEqual(by_uri_model[("at://pool/0", "incivility_toxicity")], 0.05)
            self.assertEqual(by_uri_model[("at://pool/1", "incivility_toxicity")], 0.9)
            self.assertIsNone(by_uri_model[("at://pool/2", "incivility_toxicity")])
            for uri in uris:
                self.assertIn(("uri", "tfidf_lr_hate_vs_rude"), [("uri", "tfidf_lr_hate_vs_rude")])
                score = by_uri_model[(uri, "tfidf_lr_hate_vs_rude")]
                self.assertIsInstance(score, float)
                self.assertGreaterEqual(score, 0.0)
                self.assertLessEqual(score, 1.0)
            for r in records:
                self.assertIn("meaning", r)
                if r["model"] == "tfidf_lr_hate_vs_rude":
                    self.assertIn("P(hate | one of", r["meaning"])

            manifest_path = os.path.join(paths["manifest_dir"], manifest_files[0])
            with open(manifest_path, "r", encoding="utf-8") as f:
                manifest = json.load(f)

            # manifest contains no predictions -- only metadata
            manifest_text = json.dumps(manifest)
            self.assertNotIn("at://pool", manifest_text)
            self.assertEqual(manifest["record_count"], 18)
            self.assertEqual(manifest["distinct_uri_count"], 9)
            self.assertEqual(manifest["sha256"], sp.sha256_file(pred_path))
            self.assertIn("intent", manifest)
            self.assertIn("tamper", json.dumps(manifest).lower())
            self.assertEqual(
                manifest["models"]["tfidf_lr_hate_vs_rude"]["training_label_counts"],
                {"positive": 3, "hard_negative": 3},
            )
            self.assertEqual(manifest["models"]["tfidf_lr_hate_vs_rude"]["random_state"], 42)
            self.assertIn("sklearn_version", manifest["models"]["tfidf_lr_hate_vs_rude"])
            self.assertEqual(manifest["models"]["incivility_toxicity"]["model_id"], "m")
            self.assertEqual(manifest["models"]["incivility_toxicity"]["model_revision"], "rev1")


# --------------------------------------------------------------------------
# verify
# --------------------------------------------------------------------------

class VerifyTests(unittest.TestCase):
    def _seal(self, d):
        paths = build_seal_fixture(d)
        rc = sp.main([
            "seal", "--store", paths["store"],
            "--incivility-dir", paths["incivility_dir"],
            "--labels-dir", paths["labels_dir"],
            "--predictions-dir", paths["predictions_dir"],
            "--manifest-dir", paths["manifest_dir"],
            "--random-state", "42",
        ])
        self.assertEqual(rc, 0)
        manifest_file = [f for f in os.listdir(paths["manifest_dir"])
                          if f.endswith(".json")][0]
        return paths, os.path.join(paths["manifest_dir"], manifest_file)

    def test_verify_passes_on_untouched_file(self):
        with tempfile.TemporaryDirectory() as d:
            paths, manifest_path = self._seal(d)
            rc = sp.main(["verify", "--manifest", manifest_path,
                          "--predictions-dir", paths["predictions_dir"]])
            self.assertEqual(rc, 0)

    def test_verify_fails_on_tampered_file(self):
        with tempfile.TemporaryDirectory() as d:
            paths, manifest_path = self._seal(d)
            pred_file = [f for f in os.listdir(paths["predictions_dir"])][0]
            pred_path = os.path.join(paths["predictions_dir"], pred_file)
            with open(pred_path, "ab") as f:
                f.write(b"tampered")
            rc = sp.main(["verify", "--manifest", manifest_path,
                          "--predictions-dir", paths["predictions_dir"]])
            self.assertNotEqual(rc, 0)


# --------------------------------------------------------------------------
# compare
# --------------------------------------------------------------------------

class CompareTests(unittest.TestCase):
    def _seal(self, d):
        paths = build_seal_fixture(d)
        rc = sp.main([
            "seal", "--store", paths["store"],
            "--incivility-dir", paths["incivility_dir"],
            "--labels-dir", paths["labels_dir"],
            "--predictions-dir", paths["predictions_dir"],
            "--manifest-dir", paths["manifest_dir"],
            "--random-state", "42",
        ])
        self.assertEqual(rc, 0)
        manifest_file = [f for f in os.listdir(paths["manifest_dir"])
                          if f.endswith(".json")][0]
        return paths, os.path.join(paths["manifest_dir"], manifest_file)

    def _add_human_labels(self, store_path, uri_speechclass_pairs):
        """Append a uniformRandom pass-1 batch and human annotations for the
        given (uri, speech_class) pairs onto an already-built store."""
        conn = sqlite3.connect(store_path)
        batch_id = uuid.uuid4()
        conn.execute(
            "INSERT INTO ZLABELBATCH (ZID, ZFRAMEJSON, ZPASSNUMBER) VALUES (?, ?, ?)",
            (str(batch_id), json.dumps({"kind": "uniformRandom"}), 1),
        )
        for uri, speech_class in uri_speechclass_pairs:
            pk = conn.execute("SELECT Z_PK FROM ZPOST WHERE ZURI = ?", (uri,)).fetchone()[0]
            conn.execute(
                "INSERT INTO ZANNOTATION (ZPOST, ZSPEECHCLASS, ZSTAGE, ZBATCHID, ZPASSNUMBER) "
                "VALUES (?, ?, 'human', ?, 1)",
                (pk, speech_class, str(batch_id)),
            )
        conn.commit()
        conn.close()

    def test_compare_refuses_on_hash_mismatch(self):
        with tempfile.TemporaryDirectory() as d:
            paths, manifest_path = self._seal(d)
            pred_file = [f for f in os.listdir(paths["predictions_dir"])][0]
            pred_path = os.path.join(paths["predictions_dir"], pred_file)
            with open(pred_path, "ab") as f:
                f.write(b"tampered")
            rc = sp.main(["compare", "--manifest", manifest_path,
                          "--predictions-dir", paths["predictions_dir"],
                          "--store", paths["store"]])
            self.assertNotEqual(rc, 0)

    def test_compare_refuses_with_fewer_than_30_labels(self):
        with tempfile.TemporaryDirectory() as d:
            paths, manifest_path = self._seal(d)
            self._add_human_labels(paths["store"], [("at://pool/0", "hate")])
            rc = sp.main(["compare", "--manifest", manifest_path,
                          "--predictions-dir", paths["predictions_dir"],
                          "--store", paths["store"]])
            self.assertNotEqual(rc, 0)

    def test_compare_happy_path_known_auc(self):
        with tempfile.TemporaryDirectory() as d:
            paths, manifest_path = self._seal(d)

            # Build a store with 40 pool posts scored by both models with
            # KNOWN, perfectly-separating incivility scores, then attach 40
            # human labels (20 hate at score>=0.5, 20 neutral at score<0.5)
            # so this model's AUC against the human label is exactly 1.0.
            store = os.path.join(d, "big.store")
            posts = [{"uri": "at://big/%d" % i, "text": "post number %d text" % i}
                     for i in range(40)]
            make_store(store, posts=posts)

            incivility_dir = os.path.join(d, "incivility2")
            os.makedirs(incivility_dir)
            score_records = []
            for i in range(40):
                score_records.append({
                    "uri": "at://big/%d" % i, "head": "toxicity",
                    "score": 0.9 if i < 20 else 0.1, "model_id": "m",
                    "model_revision": "rev1", "scored_at": "2026-08-11T00:00:00Z",
                })
            write_jsonl(os.path.join(incivility_dir, "incivility-scores-x.jsonl"), score_records)

            labels_path = os.path.join(d, "label-harvest-posts-big.jsonl")
            write_jsonl(labels_path, [])
            with open(labels_path[: -len(".jsonl")] + ".summary.json", "w") as f:
                json.dump({"run_status": "complete"}, f)
            # need at least one positive + one hard_negative example for the
            # tfidf model to train; borrow from the earlier fixture's texts.
            write_jsonl(labels_path, [
                {"subject": "at://big/0", "subject_type": "post", "val": "intolerant", "neg": False},
                {"subject": "at://big/1", "subject_type": "post", "val": "rude", "neg": False},
            ])

            pred_dir = os.path.join(d, "predictions2")
            manifest_dir = os.path.join(d, "manifest2")
            rc = sp.main([
                "seal", "--store", store,
                "--incivility-dir", incivility_dir,
                "--labels-dir", d,
                "--labels-file", labels_path,
                "--predictions-dir", pred_dir,
                "--manifest-dir", manifest_dir,
                "--random-state", "42",
            ])
            self.assertEqual(rc, 0)
            manifest_file = [f for f in os.listdir(manifest_dir) if f.endswith(".json")][0]
            big_manifest_path = os.path.join(manifest_dir, manifest_file)

            # human labels: first 20 uris -> hate, next 20 -> neutral.
            # this makes incivility_toxicity's AUC against the human label
            # exactly 1.0 (perfect separation by construction).
            pairs = [("at://big/%d" % i, "hate" if i < 20 else "neutral") for i in range(40)]
            self._add_human_labels(store, pairs)

            rc, report = sp.run_compare(
                manifest_path=big_manifest_path,
                predictions_dir=pred_dir,
                store_path=store,
            )
            self.assertEqual(rc, 0)
            self.assertEqual(report["n_human_labels"], 40)
            self.assertEqual(report["human_base_rate"]["k"], 20)
            self.assertEqual(report["human_base_rate"]["n"], 40)
            lo, hi = report["human_base_rate"]["wilson_ci"]
            self.assertLess(lo, 0.5)
            self.assertGreater(hi, 0.5)
            model_report = report["models"]["incivility_toxicity"]
            self.assertEqual(model_report["n_compared"], 40)
            self.assertEqual(model_report["n_null"], 0)
            self.assertAlmostEqual(model_report["roc_auc"], 1.0)
            self.assertIn("threshold", model_report)
            self.assertIn("agreement", report)


if __name__ == "__main__":
    unittest.main()
