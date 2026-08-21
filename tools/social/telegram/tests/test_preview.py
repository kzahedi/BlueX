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


class TestSyntheticPaths(unittest.TestCase):
    """Hand-written markup modeled on the real fixture's tgme_widget_* structure,
    exercising forward/reply/document paths the live capture didn't happen to contain.
    """

    def test_forwarded_message(self):
        from tools.social.telegram.preview import parse_preview_html
        html = """
        <div class="tgme_widget_message_wrap js-widget_message_wrap">
          <div class="tgme_widget_message text_not_supported_wrap js-widget_message" data-post="telegram/100">
            <div class="tgme_widget_message_forwarded_from">
              <span class="tgme_widget_message_forwarded_from_name_wrap">
                Forwarded from
                <a class="tgme_widget_message_forwarded_from_name" href="https://t.me/somechan/123">Some Channel</a>
              </span>
            </div>
            <div class="tgme_widget_message_text js-message_text" dir="auto">Forwarded content.</div>
            <div class="tgme_widget_message_footer compact js-message_footer">
              <div class="tgme_widget_message_info short js-message_info">
                <span class="tgme_widget_message_views">10</span><span class="copyonly"> views</span>
                <span class="tgme_widget_message_meta">
                  <a class="tgme_widget_message_date" href="https://t.me/telegram/100">
                    <time datetime="2026-01-01T00:00:00+00:00" class="time">00:00</time>
                  </a>
                </span>
              </div>
            </div>
          </div>
        </div>
        """
        msgs = parse_preview_html(html)
        self.assertEqual(len(msgs), 1)
        m = msgs[0]
        self.assertEqual(m.fwd_from_channel, "somechan")
        self.assertEqual(m.fwd_from_msg_id, 123)

    def test_reply_message(self):
        from tools.social.telegram.preview import parse_preview_html
        html = """
        <div class="tgme_widget_message_wrap js-widget_message_wrap">
          <div class="tgme_widget_message text_not_supported_wrap js-widget_message" data-post="telegram/101">
            <a class="tgme_widget_message_reply" href="https://t.me/telegram/77">
              <div class="tgme_widget_message_metatext">In reply to</div>
            </a>
            <div class="tgme_widget_message_text js-message_text" dir="auto">Reply content.</div>
            <div class="tgme_widget_message_footer compact js-message_footer">
              <div class="tgme_widget_message_info short js-message_info">
                <span class="tgme_widget_message_views">10</span><span class="copyonly"> views</span>
                <span class="tgme_widget_message_meta">
                  <a class="tgme_widget_message_date" href="https://t.me/telegram/101">
                    <time datetime="2026-01-01T00:01:00+00:00" class="time">00:01</time>
                  </a>
                </span>
              </div>
            </div>
          </div>
        </div>
        """
        msgs = parse_preview_html(html)
        self.assertEqual(len(msgs), 1)
        self.assertEqual(msgs[0].reply_to_msg_id, 77)

    def test_document_message(self):
        from tools.social.telegram.preview import parse_preview_html
        html = """
        <div class="tgme_widget_message_wrap js-widget_message_wrap">
          <div class="tgme_widget_message text_not_supported_wrap js-widget_message" data-post="telegram/102">
            <div class="tgme_widget_message_document_wrap js-message_reply">
              <div class="tgme_widget_message_document">
                <div class="tgme_widget_message_document_icon"></div>
                <div class="tgme_widget_message_document_title">report.pdf</div>
              </div>
            </div>
            <div class="tgme_widget_message_text js-message_text" dir="auto">Document content.</div>
            <div class="tgme_widget_message_footer compact js-message_footer">
              <div class="tgme_widget_message_info short js-message_info">
                <span class="tgme_widget_message_views">10</span><span class="copyonly"> views</span>
                <span class="tgme_widget_message_meta">
                  <a class="tgme_widget_message_date" href="https://t.me/telegram/102">
                    <time datetime="2026-01-01T00:02:00+00:00" class="time">00:02</time>
                  </a>
                </span>
              </div>
            </div>
          </div>
        </div>
        """
        msgs = parse_preview_html(html)
        self.assertEqual(len(msgs), 1)
        m = msgs[0]
        self.assertEqual(m.media_type, "document")
        self.assertEqual(m.media_ref, "report.pdf")


class TestParseViews(unittest.TestCase):
    def test_plain_k_m(self):
        from tools.social.telegram.preview import parse_views
        self.assertEqual(parse_views("882"), 882)
        self.assertEqual(parse_views("1.2K"), 1200)
        self.assertEqual(parse_views("3.4M"), 3400000)


if __name__ == "__main__":
    unittest.main()
