import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from detectors import lexicon


class TestLexicon(unittest.TestCase):
    def test_no_match_scores_zero(self):
        self.assertEqual(lexicon.score(["have a nice day"]), [0.0])

    def test_case_insensitive_match(self):
        self.assertEqual(lexicon.score(["GAS THE whatever"]), [1.0])

    def test_multiple_matches_counted(self):
        text = "nazi kolonie and gas the people, subhuman vermin"
        self.assertEqual(lexicon.score([text]), [4.0])

    def test_empty_and_none_text_safe(self):
        self.assertEqual(lexicon.score(["", None]), [0.0, 0.0])

    def test_batch_independence(self):
        scores = lexicon.score(["nazi kolonie", "have a nice day", "kill yourself"])
        self.assertEqual(scores, [1.0, 0.0, 1.0])


if __name__ == "__main__":
    unittest.main()
