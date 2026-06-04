import unittest
import report

CLASSES = ("hate", "counter", "neutral")


class ScoreTest(unittest.TestCase):
    def test_perfect_model_scores_1(self):
        gold = {"u1": "hate", "u2": "neutral", "u3": "counter"}
        preds = {"u1": {"m": "hate"}, "u2": {"m": "neutral"}, "u3": {"m": "counter"}}
        metrics = report.score(gold, preds)["m"]
        self.assertEqual(metrics["accuracy"], 1.0)
        self.assertEqual(metrics["macro_f1"], 1.0)

    def test_precision_recall_on_confusion(self):
        gold = {"a": "hate", "b": "hate", "c": "neutral", "d": "neutral"}
        preds = {k: {"m": "hate"} for k in gold}
        m = report.score(gold, preds)["m"]
        self.assertAlmostEqual(m["per_class"]["hate"]["precision"], 0.5, places=3)
        self.assertAlmostEqual(m["per_class"]["hate"]["recall"], 1.0, places=3)
        self.assertAlmostEqual(m["per_class"]["hate"]["f1"], 2 / 3, places=3)
        self.assertEqual(m["per_class"]["neutral"]["recall"], 0.0)

    def test_only_scores_posts_the_model_predicted(self):
        gold = {"a": "hate", "b": "neutral"}
        preds = {"a": {"m": "hate"}}
        m = report.score(gold, preds)["m"]
        self.assertEqual(m["n"], 1)
        self.assertEqual(m["accuracy"], 1.0)

    def test_agreement_matrix_pairwise(self):
        gold = {"a": "hate", "b": "neutral"}
        preds = {"a": {"m1": "hate", "m2": "hate"}, "b": {"m1": "neutral", "m2": "hate"}}
        agree = report.agreement(preds)
        self.assertAlmostEqual(agree[("m1", "m2")], 0.5, places=3)


if __name__ == "__main__":
    unittest.main()
