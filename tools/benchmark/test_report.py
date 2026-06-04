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

    def test_macro_f1_penalizes_zero_support_class(self):
        # Perfect on the 2 present classes, but 'counter' has zero support -> macro avg over 3.
        gold = {"a": "hate", "b": "neutral"}
        preds = {"a": {"m": "hate"}, "b": {"m": "neutral"}}
        m = report.score(gold, preds)["m"]
        self.assertEqual(m["accuracy"], 1.0)
        self.assertAlmostEqual(m["macro_f1"], 2 / 3, places=3)  # (1+1+0)/3

    def test_empty_inputs_do_not_crash(self):
        self.assertEqual(report.score({}, {}), {})
        self.assertEqual(report.agreement({}), {})

    def test_agreement_three_models_all_pairs(self):
        preds = {"a": {"m1": "hate", "m2": "hate", "m3": "neutral"}}
        agree = report.agreement(preds)
        self.assertEqual(set(agree.keys()), {("m1", "m2"), ("m1", "m3"), ("m2", "m3")})
        self.assertEqual(agree[("m1", "m2")], 1.0)
        self.assertEqual(agree[("m1", "m3")], 0.0)

    def test_load_preds_keeps_latest_per_model(self):
        import sqlite3
        conn = sqlite3.connect(":memory:")
        conn.executescript(
            '''
            CREATE TABLE ZPOST (Z_PK INTEGER PRIMARY KEY, ZURI TEXT);
            CREATE TABLE ZANNOTATION (Z_PK INTEGER PRIMARY KEY, ZPOST INTEGER,
              ZMODELNAME TEXT, ZSPEECHCLASS TEXT, ZSTAGE TEXT, ZCONFIDENCE REAL, ZCREATEDAT REAL);
            INSERT INTO ZPOST VALUES (1, 'at://u1');
            -- two annotations for the same (uri, model); the later ZCREATEDAT must win
            INSERT INTO ZANNOTATION VALUES (10, 1, 'm', 'hate',    'llm', 0.9, 100.0);
            INSERT INTO ZANNOTATION VALUES (11, 1, 'm', 'neutral', 'llm', 0.9, 200.0);
            -- a confidence-0 sentinel must be excluded
            INSERT INTO ZANNOTATION VALUES (12, 1, 'm2', 'neutral','llm', 0.0, 300.0);
            '''
        )
        preds = report.load_preds(conn, ['at://u1'])
        self.assertEqual(preds['at://u1']['m'], 'neutral')  # latest wins
        self.assertNotIn('m2', preds['at://u1'])             # sentinel excluded


if __name__ == "__main__":
    unittest.main()
