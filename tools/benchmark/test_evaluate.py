import json
import os
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evaluate


RECORDS = [
    {"uri": "p1", "text": "hateful", "class": "positive", "language": "en"},
    {"uri": "p2", "text": "hateful2", "class": "positive", "language": "en"},
    {"uri": "h1", "text": "rude", "class": "hard_negative", "language": "en"},
    {"uri": "h2", "text": "rude2", "class": "hard_negative", "language": "en"},
    {"uri": "e1", "text": "random", "class": "easy_negative", "language": "en"},
    {"uri": "e2", "text": "random2", "class": "easy_negative", "language": "en"},
]


class TestRunDetectorCaching(unittest.TestCase):
    def test_lexicon_cache_hit_skips_recompute(self):
        with tempfile.TemporaryDirectory() as out_dir:
            calls = {"n": 0}
            real_score = evaluate.lexicon.score

            def counting_score(texts):
                calls["n"] += 1
                return real_score(texts)

            with mock.patch.object(evaluate.lexicon, "score", counting_score):
                r1 = evaluate.run_detector("lexicon", RECORDS, out_dir, "stamp1")
                r2 = evaluate.run_detector("lexicon", RECORDS, out_dir, "stamp1")

            self.assertEqual(calls["n"], 1)  # second call was a cache hit
            self.assertEqual(r1, r2)
            self.assertEqual(r1["status"], "ok")

    def test_force_bypasses_cache(self):
        with tempfile.TemporaryDirectory() as out_dir:
            calls = {"n": 0}
            real_score = evaluate.lexicon.score

            def counting_score(texts):
                calls["n"] += 1
                return real_score(texts)

            with mock.patch.object(evaluate.lexicon, "score", counting_score):
                evaluate.run_detector("lexicon", RECORDS, out_dir, "stamp1")
                evaluate.run_detector("lexicon", RECORDS, out_dir, "stamp1", force=True)

            self.assertEqual(calls["n"], 2)

    def test_hf_load_failure_recorded_not_raised(self):
        with tempfile.TemporaryDirectory() as out_dir:
            def boom(texts, model_id, **kwargs):
                raise evaluate.hf_encoder.DetectorLoadError("nope: 404")

            with mock.patch.object(evaluate.hf_encoder, "score_heads", boom):
                result = evaluate.run_detector("hf:bad/model", RECORDS, out_dir, "stamp1")

            self.assertEqual(result["status"], "failed")
            self.assertIn("nope", result["reason"])

    def test_multi_head_detector_produces_one_series_per_head(self):
        with tempfile.TemporaryDirectory() as out_dir:
            def fake_heads(texts, model_id, **kwargs):
                return {"toxicity": [0.9] * len(texts), "threat": [0.1] * len(texts)}

            with mock.patch.object(evaluate.hf_encoder, "score_heads", fake_heads):
                result = evaluate.run_detector("hf:some/model", RECORDS, out_dir, "stamp1")

            self.assertEqual(result["status"], "ok")
            self.assertEqual(
                set(result["heads"].keys()),
                {"hf:some/model#toxicity", "hf:some/model#threat"},
            )


class TestComparisonTable(unittest.TestCase):
    def test_sorted_by_hard_negative_auc_descending(self):
        head_reports = {
            "weak": {"vs_hard_negative": {"roc_auc": 0.5, "pr_auc": 0.4}, "vs_easy_negative": {"roc_auc": 0.99}},
            "strong": {"vs_hard_negative": {"roc_auc": 0.9, "pr_auc": 0.8}, "vs_easy_negative": {"roc_auc": 0.6}},
            "failed_none": {"vs_hard_negative": {"roc_auc": None, "pr_auc": None}, "vs_easy_negative": {"roc_auc": None}},
        }
        rows = evaluate.build_comparison_table(head_reports)
        names = [r[0] for r in rows]
        # strong (0.9) before weak (0.5); None sorts last regardless of its easy-negative number
        self.assertEqual(names, ["strong", "weak", "failed_none"])


class TestEndToEndWithFakeDetectors(unittest.TestCase):
    def test_full_run_writes_outputs(self):
        with tempfile.TemporaryDirectory() as out_dir:
            eval_set_path = os.path.join(out_dir, "eval-set-test.jsonl")
            with open(eval_set_path, "w") as handle:
                for rec in RECORDS:
                    handle.write(json.dumps(rec) + "\n")

            argv = ["--eval-set", eval_set_path, "--detectors", "lexicon", "--out-dir", out_dir]
            rc = evaluate.main(argv)
            self.assertEqual(rc, 0)

            outputs = os.listdir(out_dir)
            self.assertTrue(any(f.startswith("evaluation-") and f.endswith(".json") for f in outputs))
            self.assertTrue(any(f.startswith("evaluation-") and f.endswith(".md") for f in outputs))
            self.assertIn("README-evaluate.md", outputs)


if __name__ == "__main__":
    unittest.main()
