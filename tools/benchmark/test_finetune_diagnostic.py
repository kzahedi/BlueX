import os
import sys
import unittest

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import finetune_diagnostic as fd


def _records(n_pos=6, n_hard=10, n_easy=8):
    recs = []
    for i in range(n_pos):
        recs.append({"uri": "p%d" % i, "text": "hateful text %d" % i,
                     "class": "positive", "language": "en"})
    for i in range(n_hard):
        recs.append({"uri": "h%d" % i, "text": "rude text %d" % i,
                     "class": "hard_negative", "language": "en"})
    for i in range(n_easy):
        recs.append({"uri": "e%d" % i, "text": "random text %d" % i,
                     "class": "easy_negative", "language": "en"})
    return recs


class TestSplitCoreAndEasy(unittest.TestCase):
    def test_splits_by_class(self):
        recs = _records()
        core, easy = fd.split_core_and_easy(recs)
        self.assertEqual(len(core), 16)  # 6 positive + 10 hard_negative
        self.assertEqual(len(easy), 8)
        self.assertTrue(all(r["class"] != "easy_negative" for r in core))
        self.assertTrue(all(r["class"] == "easy_negative" for r in easy))


class TestCoreLabels(unittest.TestCase):
    def test_positive_is_one_hard_negative_is_zero(self):
        core = [
            {"uri": "p0", "class": "positive"},
            {"uri": "h0", "class": "hard_negative"},
            {"uri": "h1", "class": "hard_negative"},
        ]
        labels = fd.core_labels(core)
        np.testing.assert_array_equal(labels, [1, 0, 0])


class TestBuildFolds(unittest.TestCase):
    def test_folds_cover_every_index_exactly_once_as_test(self):
        core, _ = fd.split_core_and_easy(_records(n_pos=6, n_hard=10))
        folds = fd.build_folds(core, k=5, seed=42)
        self.assertEqual(len(folds), 5)
        seen = []
        for _, test_idx in folds:
            seen.extend(test_idx.tolist())
        self.assertEqual(sorted(seen), list(range(len(core))))

    def test_folds_are_stratified(self):
        # 6 positive + 10 hard_negative, 5 folds -> each test fold should get
        # roughly 1 positive out of 6 (stratified, not lumped into one fold).
        core, _ = fd.split_core_and_easy(_records(n_pos=6, n_hard=10))
        labels = fd.core_labels(core)
        folds = fd.build_folds(core, k=5, seed=42)
        for _, test_idx in folds:
            n_pos_in_fold = int(labels[test_idx].sum())
            self.assertGreaterEqual(n_pos_in_fold, 0)
            self.assertLessEqual(n_pos_in_fold, 2)  # no fold swallows all 6

    def test_deterministic_given_same_seed(self):
        core, _ = fd.split_core_and_easy(_records(n_pos=6, n_hard=10))
        folds_a = fd.build_folds(core, k=5, seed=7)
        folds_b = fd.build_folds(core, k=5, seed=7)
        for (train_a, test_a), (train_b, test_b) in zip(folds_a, folds_b):
            np.testing.assert_array_equal(train_a, train_b)
            np.testing.assert_array_equal(test_a, test_b)


class TestLexiconBaseline(unittest.TestCase):
    def test_runs_without_training_and_produces_per_fold_metrics(self):
        core, easy = fd.split_core_and_easy(_records(n_pos=6, n_hard=10, n_easy=8))
        folds = fd.build_folds(core, k=5, seed=1)
        result = fd.run_lexicon_baseline(core, easy, folds)
        self.assertFalse(result["trainable"])
        self.assertEqual(len(result["fold_test_auc"]), 5)
        self.assertEqual(len(result["oof_core_scores"]), len(core))
        # every core example got exactly one OOF score (no NaN left over)
        self.assertFalse(any(np.isnan(s) for s in result["oof_core_scores"]))


class TestTfidfLogregBaseline(unittest.TestCase):
    def test_separates_a_trivially_separable_toy_set(self):
        # Deliberately trivial: positive texts share a token absent from
        # hard_negative texts, so a linear bag-of-words model should recover
        # near-perfect separation. This is a sanity check on the harness
        # (folds/scoring plumbing), not a claim about the real corpus.
        core = []
        for i in range(10):
            core.append({"uri": "p%d" % i, "text": "muslim jews immigrants group %d" % i,
                         "class": "positive", "language": "en"})
        for i in range(10):
            core.append({"uri": "h%d" % i, "text": "fuck off idiot shit %d" % i,
                         "class": "hard_negative", "language": "en"})
        easy = [{"uri": "e%d" % i, "text": "the weather today %d" % i,
                 "class": "easy_negative", "language": "en"} for i in range(8)]
        folds = fd.build_folds(core, k=5, seed=3)
        result = fd.run_tfidf_logreg_baseline(core, easy, folds, seed=3)
        self.assertTrue(result["trainable"])
        mean_test_auc = float(np.mean([a for a in result["fold_test_auc"] if a is not None]))
        self.assertGreater(mean_test_auc, 0.9)
        self.assertEqual(len(result["easy_negative_scores_per_fold_model"]), 5)


class TestBuildScoresByUriAndSummarize(unittest.TestCase):
    def test_easy_negative_score_is_mean_across_fold_models(self):
        core = [{"uri": "p0", "class": "positive", "language": "en"},
                {"uri": "h0", "class": "hard_negative", "language": "en"}]
        easy = [{"uri": "e0", "class": "easy_negative", "language": "en"}]
        result = {
            "oof_core_scores": [0.9, 0.1],
            "easy_negative_scores_per_fold_model": [[0.2], [0.4], [0.6]],
            "fold_test_auc": [1.0], "fold_train_auc": [1.0],
            "fold_easy_negative_auc": [1.0], "trainable": True,
        }
        scores_by_uri = fd.build_scores_by_uri(core, easy, result)
        self.assertAlmostEqual(scores_by_uri["p0"], 0.9)
        self.assertAlmostEqual(scores_by_uri["h0"], 0.1)
        self.assertAlmostEqual(scores_by_uri["e0"], 0.4)  # mean(0.2, 0.4, 0.6)

    def test_summarize_reports_mean_and_sd_not_a_single_number(self):
        core = [{"uri": "p0", "class": "positive", "language": "en"},
                {"uri": "p1", "class": "positive", "language": "en"},
                {"uri": "h0", "class": "hard_negative", "language": "en"},
                {"uri": "h1", "class": "hard_negative", "language": "en"}]
        easy = [{"uri": "e0", "class": "easy_negative", "language": "en"}]
        all_records = core + easy
        result = {
            "oof_core_scores": [0.9, 0.6, 0.1, 0.4],
            "easy_negative_scores_per_fold_model": [[0.3], [0.3]],
            "fold_test_auc": [1.0, 0.5],
            "fold_train_auc": [0.95, 0.9],
            "fold_easy_negative_auc": [0.8, 0.7],
            "trainable": True,
        }
        summary = fd.summarize_candidate("toy", result, core, easy, all_records, min_lang_n=1)
        cv = summary["cv_summary"]
        self.assertAlmostEqual(cv["mean_test_auc_hard_negative"], 0.75)
        self.assertIsNotNone(cv["sd_test_auc_hard_negative"])
        self.assertAlmostEqual(cv["overfitting_gap"], (0.95 + 0.9) / 2 - 0.75)
        self.assertIn("vs_hard_negative", summary["pooled_oof_report"])
        self.assertIn("vs_easy_negative", summary["pooled_oof_report"])


if __name__ == "__main__":
    unittest.main()
