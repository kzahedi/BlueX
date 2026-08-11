import unittest

import metrics


class TestRocAuc(unittest.TestCase):
    def test_hand_worked_example(self):
        # Classic textbook example: labels [0,0,1,1], scores [0.1,0.4,0.35,0.8].
        # Mann-Whitney U over the two positive scores {0.35, 0.8} against the
        # two negative scores {0.1, 0.4}:
        #   0.35 > 0.1 (1), 0.35 vs 0.4 (0.5 tie... actually 0.35<0.4 -> 0)
        #   0.8 > 0.1 (1), 0.8 > 0.4 (1)
        # U = 1 + 0 + 1 + 1 = 3, AUC = U / (n_pos * n_neg) = 3/4 = 0.75
        pos = [0.35, 0.8]
        neg = [0.1, 0.4]
        self.assertAlmostEqual(metrics.roc_auc(pos, neg), 0.75, places=6)

    def test_perfect_separation_is_one(self):
        self.assertAlmostEqual(metrics.roc_auc([0.9, 0.8], [0.1, 0.2]), 1.0)

    def test_perfect_inversion_is_zero(self):
        self.assertAlmostEqual(metrics.roc_auc([0.1, 0.2], [0.9, 0.8]), 0.0)

    def test_chance_level(self):
        self.assertAlmostEqual(metrics.roc_auc([0.5, 0.5], [0.5, 0.5]), 0.5)


class TestDegenerateInput(unittest.TestCase):
    """A benchmark run must never crash because one class is empty."""

    def test_empty_positive_group(self):
        self.assertIsNone(metrics.roc_auc([], [0.1, 0.2, 0.3]))
        self.assertIsNone(metrics.pr_auc([], [0.1, 0.2, 0.3]))
        self.assertIsNone(metrics.best_f1([], [0.1, 0.2, 0.3]))

    def test_empty_negative_group(self):
        self.assertIsNone(metrics.roc_auc([0.1, 0.2], []))
        self.assertIsNone(metrics.pr_auc([0.1, 0.2], []))
        self.assertIsNone(metrics.best_f1([0.1, 0.2], []))

    def test_both_empty(self):
        self.assertIsNone(metrics.roc_auc([], []))
        self.assertIsNone(metrics.pr_auc([], []))
        self.assertIsNone(metrics.best_f1([], []))


class TestBestF1(unittest.TestCase):
    def test_well_separated_case(self):
        pos = [0.9, 0.8, 0.85]
        neg = [0.1, 0.2, 0.15]
        result = metrics.best_f1(pos, neg)
        self.assertAlmostEqual(result["f1"], 1.0)
        self.assertAlmostEqual(result["precision"], 1.0)
        self.assertAlmostEqual(result["recall"], 1.0)


class TestPerLanguageBreakdown(unittest.TestCase):
    def _records(self):
        return [
            {"uri": "p1", "class": "positive", "language": "en"},
            {"uri": "p2", "class": "positive", "language": "en"},
            {"uri": "p3", "class": "positive", "language": "de"},
            {"uri": "h1", "class": "hard_negative", "language": "en"},
            {"uri": "h2", "class": "hard_negative", "language": "en"},
            {"uri": "h3", "class": "hard_negative", "language": "de"},
        ]

    def test_buckets_by_language_and_reports_n(self):
        scores = {"p1": 0.9, "p2": 0.8, "p3": 0.85, "h1": 0.1, "h2": 0.2, "h3": 0.15}
        out = metrics.per_language_breakdown(
            self._records(), scores, "positive", "hard_negative", min_n=1,
        )
        self.assertEqual(out["en"]["n_positive"], 2)
        self.assertEqual(out["en"]["n_negative"], 2)
        self.assertEqual(out["de"]["n_positive"], 1)
        self.assertAlmostEqual(out["en"]["roc_auc"], 1.0)

    def test_suppresses_small_cells(self):
        scores = {"p1": 0.9, "p2": 0.8, "p3": 0.85, "h1": 0.1, "h2": 0.2, "h3": 0.15}
        out = metrics.per_language_breakdown(
            self._records(), scores, "positive", "hard_negative", min_n=20,
        )
        # n=1..2 everywhere is below min_n=20 -> every cell suppressed, no AUC
        for lang_stats in out.values():
            self.assertTrue(lang_stats["suppressed"])
            self.assertIsNone(lang_stats["roc_auc"])
            self.assertIsNone(lang_stats["pr_auc"])
        # but n is still reported, not hidden
        self.assertEqual(out["en"]["n_positive"], 2)

    def test_unknown_language_buckets_to_other(self):
        self.assertEqual(metrics.bucket_language("fr"), "other")
        self.assertEqual(metrics.bucket_language(None), "other")
        self.assertEqual(metrics.bucket_language("en"), "en")
        self.assertEqual(metrics.bucket_language("de"), "de")


if __name__ == "__main__":
    unittest.main()
