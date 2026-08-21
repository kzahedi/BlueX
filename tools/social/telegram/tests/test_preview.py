import json
import pathlib
import unittest

FIXTURES = pathlib.Path(__file__).parent / "fixtures"


class TestParsePreview(unittest.TestCase):
    def setUp(self):
        self.html = (FIXTURES / "tgme_sample.html").read_text(encoding="utf-8")

    def test_parses_messages_with_required_fields(self):
        from tools.social.telegram.preview import parse_preview_html
        msgs = parse_preview_html(self.html)
        self.assertGreaterEqual(len(msgs), 10)
        ids = [m.msg_id for m in msgs]
        self.assertEqual(ids, sorted(ids))          # ascending
        self.assertEqual(len(ids), len(set(ids)))   # unique
        for m in msgs:
            self.assertEqual(m.channel, "telegram")
            self.assertIsInstance(m.msg_id, int)
            # ISO-8601 with timezone, e.g. 2024-05-01T12:34:56+00:00
            self.assertRegex(m.date, r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}")
        self.assertTrue(any(m.views is not None for m in msgs))

    def test_matches_committed_snapshot(self):
        from tools.social.telegram.preview import parse_preview_html
        expected = json.loads((FIXTURES / "tgme_sample_expected.json").read_text())
        got = [vars(m) for m in parse_preview_html(self.html)]
        self.assertEqual(got, expected)


class TestParseViews(unittest.TestCase):
    def test_plain_k_m(self):
        from tools.social.telegram.preview import parse_views
        self.assertEqual(parse_views("882"), 882)
        self.assertEqual(parse_views("1.2K"), 1200)
        self.assertEqual(parse_views("3.4M"), 3400000)


if __name__ == "__main__":
    unittest.main()
