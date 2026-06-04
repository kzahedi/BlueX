import unittest
import make_review


class RenderTest(unittest.TestCase):
    def setUp(self):
        self.entries = [
            {"uri": "at://hard1", "text": "tricky\ntext with > markdown",
             "tag": "hard",
             "claude_label": {"class": "hate", "severity": "moderate", "rationale": "why"},
             "user_label": None, "notes": "", "reviewed": False},
            {"uri": "at://core1", "text": "plain", "tag": "core",
             "claude_label": {"class": "neutral", "severity": None, "rationale": "ok"},
             "user_label": None, "notes": "", "reviewed": False},
        ]

    def test_anchor_present_for_each_post(self):
        md = make_review.render(self.entries)
        self.assertIn("<!-- bm: at://hard1 -->", md)
        self.assertIn("<!-- bm: at://core1 -->", md)

    def test_verdict_prefilled_with_claude_label(self):
        md = make_review.render(self.entries)
        self.assertIn("**Verdict:** hate", md)
        self.assertIn("**Verdict:** neutral", md)

    def test_hard_cases_render_before_core(self):
        md = make_review.render(self.entries)
        self.assertLess(md.index("at://hard1"), md.index("at://core1"))

    def test_reviewed_checkbox_reflects_state(self):
        self.entries[1]["reviewed"] = True
        md = make_review.render(self.entries)
        self.assertIn("- [x] reviewed", md)
        self.assertIn("- [ ] reviewed", md)

    def test_user_label_used_as_verdict_when_present(self):
        self.entries[0]["user_label"] = {"class": "counter", "severity": None}
        md = make_review.render(self.entries)
        self.assertIn("**Verdict:** counter", md)


if __name__ == "__main__":
    unittest.main()
