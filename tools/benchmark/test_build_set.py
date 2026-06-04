import unittest
import build_set


class MergeTest(unittest.TestCase):
    def test_merge_preserves_user_fields(self):
        existing = [{
            "uri": "at://a", "text": "old text", "tag": "core",
            "claude_label": {"class": "neutral", "severity": None, "rationale": "r"},
            "user_label": {"class": "hate", "severity": "mild"},
            "notes": "my note", "reviewed": True,
        }]
        fresh = [
            {"uri": "at://a", "text": "new text", "tag": "core"},
            {"uri": "at://b", "text": "b text", "tag": "hard"},
        ]
        merged = build_set.merge(existing, fresh)
        by_uri = {e["uri"]: e for e in merged}
        self.assertEqual(by_uri["at://a"]["user_label"], {"class": "hate", "severity": "mild"})
        self.assertEqual(by_uri["at://a"]["notes"], "my note")
        self.assertTrue(by_uri["at://a"]["reviewed"])
        self.assertEqual(by_uri["at://a"]["claude_label"]["class"], "neutral")
        self.assertEqual(by_uri["at://a"]["text"], "new text")
        self.assertIsNone(by_uri["at://b"]["user_label"])
        self.assertFalse(by_uri["at://b"]["reviewed"])
        self.assertEqual(by_uri["at://b"]["claude_label"], None)

    def test_fresh_only_when_no_existing(self):
        merged = build_set.merge([], [{"uri": "at://x", "text": "t", "tag": "core"}])
        self.assertEqual(len(merged), 1)
        self.assertEqual(merged[0]["uri"], "at://x")
        self.assertFalse(merged[0]["reviewed"])


if __name__ == "__main__":
    unittest.main()
