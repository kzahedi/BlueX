import json
import os
import sqlite3
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_eval_set

POST_DDL = """
CREATE TABLE ZPOST (
    Z_PK INTEGER PRIMARY KEY, ZISROOTPOST INTEGER, ZTEXT VARCHAR, ZURI VARCHAR
)
"""


def make_store(path, rows):
    """rows: list of (uri, text, is_root)."""
    conn = sqlite3.connect(path)
    conn.execute(POST_DDL)
    for i, (uri, text, is_root) in enumerate(rows):
        conn.execute(
            "INSERT INTO ZPOST (Z_PK, ZISROOTPOST, ZTEXT, ZURI) VALUES (?, ?, ?, ?)",
            (i, is_root, text, uri),
        )
    conn.commit()
    conn.close()


def write_labels_jsonl(path, records):
    with open(path, "w", encoding="utf-8") as handle:
        for rec in records:
            handle.write(json.dumps(rec) + "\n")


def label_rec(subject, val, neg=False, subject_type="post"):
    return {"subject": subject, "subject_type": subject_type, "src": "did:plc:mod",
            "val": val, "cts": "2026-08-01T00:00:00Z", "neg": neg,
            "observed_at": "2026-08-10T00:00:00Z"}


class TestLoadPostLabels(unittest.TestCase):
    def test_basic_grouping(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "labels.jsonl")
            write_labels_jsonl(path, [
                label_rec("uri1", "intolerant"),
                label_rec("uri1", "rude"),  # a subject can carry multiple values
                label_rec("uri2", "rude"),
                label_rec("acct1", "spam", subject_type="account"),  # ignored: not a post
            ])
            labels = build_eval_set.load_post_labels(path)
        self.assertEqual(labels, {"uri1": ["intolerant", "rude"], "uri2": ["rude"]})

    def test_negated_label_excluded(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "labels.jsonl")
            write_labels_jsonl(path, [
                label_rec("uri1", "intolerant", neg=True),
                label_rec("uri2", "rude", neg=False),
            ])
            labels = build_eval_set.load_post_labels(path)
        # uri1's only label was negated -> absent entirely, not merely un-classed
        self.assertNotIn("uri1", labels)
        self.assertEqual(labels["uri2"], ["rude"])

    def test_negation_of_one_value_keeps_other_values(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "labels.jsonl")
            write_labels_jsonl(path, [
                label_rec("uri1", "intolerant", neg=True),
                label_rec("uri1", "rude", neg=False),
            ])
            labels = build_eval_set.load_post_labels(path)
        self.assertEqual(labels["uri1"], ["rude"])


class TestClassifySubject(unittest.TestCase):
    def test_positive_values(self):
        for val in ("intolerant", "threat", "extremist", "intolerant-race"):
            self.assertEqual(build_eval_set.classify_subject([val]), "positive")

    def test_hard_negative(self):
        self.assertEqual(build_eval_set.classify_subject(["rude"]), "hard_negative")

    def test_positive_takes_priority_over_hard_negative(self):
        self.assertEqual(build_eval_set.classify_subject(["rude", "intolerant"]), "positive")

    def test_unrelated_label_is_unclassified(self):
        self.assertIsNone(build_eval_set.classify_subject(["spam"]))
        self.assertIsNone(build_eval_set.classify_subject([]))


class TestBuildEvalSet(unittest.TestCase):
    def _fake_nl_score(self, texts, **kwargs):
        # Deterministic stand-in: language derived from a marker in the text
        # so tests never touch a Swift binary.
        out = []
        for t in texts:
            if "[DE]" in t:
                out.append({"sentiment": 0.0, "language": "de"})
            else:
                out.append({"sentiment": 0.0, "language": "en"})
        return out

    def test_class_assignment_and_easy_negative_excludes_all_labelled(self):
        with tempfile.TemporaryDirectory() as d:
            store_path = os.path.join(d, "test.store")
            labels_path = os.path.join(d, "labels.jsonl")

            make_store(store_path, [
                ("uri:pos1", "hateful text", 0),
                ("uri:hard1", "rude text", 0),
                ("uri:spam1", "spam text", 0),   # labelled but neither class -> excluded from ALL pools
                ("uri:easy1", "easy text one", 0),
                ("uri:easy2", "[DE] einfacher text", 0),
                ("uri:root1", "root text", 1),   # root post, never eligible as easy_negative
            ])
            write_labels_jsonl(labels_path, [
                label_rec("uri:pos1", "intolerant"),
                label_rec("uri:hard1", "rude"),
                label_rec("uri:spam1", "spam"),
            ])

            with mock.patch.object(build_eval_set.nl_score, "score_texts", self._fake_nl_score):
                records, extra = build_eval_set.build_eval_set(
                    labels_path, store_path, control_ratio=4.0, seed=1,
                )

        by_class = {}
        for rec in records:
            by_class.setdefault(rec["class"], []).append(rec)

        self.assertEqual(len(by_class["positive"]), 1)
        self.assertEqual(by_class["positive"][0]["uri"], "uri:pos1")
        self.assertEqual(len(by_class["hard_negative"]), 1)
        self.assertEqual(by_class["hard_negative"][0]["uri"], "uri:hard1")

        easy_uris = {r["uri"] for r in by_class["easy_negative"]}
        self.assertNotIn("uri:spam1", easy_uris)  # labelled-but-uncategorised must not leak in
        self.assertNotIn("uri:root1", easy_uris)  # root posts are never candidates
        self.assertTrue(easy_uris.issubset({"uri:easy1", "uri:easy2"}))

        # language attached from the (mocked) nl_score result
        for rec in records:
            self.assertIn(rec["language"], ("en", "de"))

    def test_empty_text_dropped_not_crashing(self):
        with tempfile.TemporaryDirectory() as d:
            store_path = os.path.join(d, "test.store")
            labels_path = os.path.join(d, "labels.jsonl")
            make_store(store_path, [
                ("uri:pos1", "", 0),  # empty text -> dropped
                ("uri:easy1", "some text", 0),
            ])
            write_labels_jsonl(labels_path, [label_rec("uri:pos1", "intolerant")])

            with mock.patch.object(build_eval_set.nl_score, "score_texts", self._fake_nl_score):
                records, extra = build_eval_set.build_eval_set(
                    labels_path, store_path, control_ratio=4.0, seed=1,
                )

        self.assertEqual([r for r in records if r["class"] == "positive"], [])
        self.assertEqual(extra["droppedForEmptyOrMissingText"]["positive"], 1)


class TestFindLatestCompletePostsFile(unittest.TestCase):
    def test_picks_newest_complete_and_skips_partial(self):
        with tempfile.TemporaryDirectory() as d:
            def write(stamp, status):
                jsonl = os.path.join(d, "label-harvest-posts-%s.jsonl" % stamp)
                summary = os.path.join(d, "label-harvest-posts-%s.summary.json" % stamp)
                open(jsonl, "w").close()
                with open(summary, "w") as h:
                    json.dump({"run_status": status}, h)
                return jsonl

            write("2026-08-01T000000Z", "complete")
            newest_partial = write("2026-08-05T000000Z", "partial")
            newest_complete = write("2026-08-03T000000Z", "complete")

            result = build_eval_set.find_latest_complete_posts_file(d)
        self.assertEqual(result, newest_complete)
        self.assertNotEqual(result, newest_partial)

    def test_raises_when_none_complete(self):
        with tempfile.TemporaryDirectory() as d:
            jsonl = os.path.join(d, "label-harvest-posts-2026-08-01T000000Z.jsonl")
            summary = os.path.join(d, "label-harvest-posts-2026-08-01T000000Z.summary.json")
            open(jsonl, "w").close()
            with open(summary, "w") as h:
                json.dump({"run_status": "partial"}, h)
            with self.assertRaises(SystemExit):
                build_eval_set.find_latest_complete_posts_file(d)


if __name__ == "__main__":
    unittest.main()
