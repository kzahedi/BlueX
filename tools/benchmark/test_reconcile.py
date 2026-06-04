import unittest
import reconcile

SAMPLE = """# BlueX Benchmark Review

<!-- bm: at://hard1 -->
### [1] · hard
> tricky
> text with > markdown and an anchor-looking <!-- bm: fake --> inside

**Claude:** hate (moderate) — why
**Verdict:** counter
**Notes:** this is actually counter-speech
- [x] reviewed

---

<!-- bm: at://core1 -->
### [2] · core
> plain

**Claude:** neutral — ok
**Verdict:** neutral
**Notes:**
- [ ] reviewed

---
"""


class ParseTest(unittest.TestCase):
    def test_parses_verdict_notes_reviewed_per_uri(self):
        parsed = reconcile.parse_review(SAMPLE)
        self.assertEqual(parsed["at://hard1"]["verdict"], "counter")
        self.assertEqual(parsed["at://hard1"]["notes"], "this is actually counter-speech")
        self.assertTrue(parsed["at://hard1"]["reviewed"])
        self.assertEqual(parsed["at://core1"]["verdict"], "neutral")
        self.assertFalse(parsed["at://core1"]["reviewed"])

    def test_inline_fake_anchor_in_quote_does_not_split(self):
        parsed = reconcile.parse_review(SAMPLE)
        self.assertNotIn("fake", parsed)
        self.assertEqual(len(parsed), 2)

    def test_merge_writes_user_label_and_keeps_unreviewed_as_claude(self):
        entries = [
            {"uri": "at://hard1", "text": "t", "tag": "hard",
             "claude_label": {"class": "hate", "severity": "moderate", "rationale": "x"},
             "user_label": None, "notes": "", "reviewed": False},
            {"uri": "at://core1", "text": "t", "tag": "core",
             "claude_label": {"class": "neutral", "severity": None, "rationale": "x"},
             "user_label": None, "notes": "", "reviewed": False},
        ]
        parsed = reconcile.parse_review(SAMPLE)
        merged = reconcile.apply(entries, parsed)
        by = {e["uri"]: e for e in merged}
        self.assertEqual(by["at://hard1"]["user_label"]["class"], "counter")
        self.assertEqual(by["at://hard1"]["notes"], "this is actually counter-speech")
        self.assertTrue(by["at://hard1"]["reviewed"])
        self.assertIsNone(by["at://core1"]["user_label"])


if __name__ == "__main__":
    unittest.main()
