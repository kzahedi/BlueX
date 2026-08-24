import json
import pathlib
import unittest
import unittest.mock

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

    def test_video_media_ref_captured(self):
        from tools.social.telegram.preview import parse_preview_html
        msgs = parse_preview_html(self.html)
        videos = [m for m in msgs if m.media_type == "video"]
        self.assertTrue(videos, "fixture should contain at least one video message")
        for m in videos:
            self.assertIsNotNone(m.media_ref)
            self.assertTrue(m.media_ref.startswith("http"), m.media_ref)


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


class TestCanonicalCasing(unittest.TestCase):
    """Telegram returns each channel's own canonical casing in data-post,
    which often differs from the casing that was requested/approved. The
    parser must normalise both the channel and forward-attribution identity
    at the boundary, before either ever reaches the store."""

    def test_channel_and_forward_attribution_are_canonicalized(self):
        from tools.social.telegram.preview import parse_preview_html
        html = """
        <div class="tgme_widget_message_wrap js-widget_message_wrap">
          <div class="tgme_widget_message text_not_supported_wrap js-widget_message" data-post="MiXeDcAsE/123">
            <div class="tgme_widget_message_forwarded_from">
              <span class="tgme_widget_message_forwarded_from_name_wrap">
                Forwarded from
                <a class="tgme_widget_message_forwarded_from_name" href="https://t.me/@OtherChannel/9">Other Channel</a>
              </span>
            </div>
            <div class="tgme_widget_message_text js-message_text" dir="auto">hi</div>
            <div class="tgme_widget_message_footer compact js-message_footer">
              <div class="tgme_widget_message_info short js-message_info">
                <span class="tgme_widget_message_meta">
                  <a class="tgme_widget_message_date" href="https://t.me/MiXeDcAsE/123">
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
        self.assertEqual(m.channel, "mixedcase")
        self.assertEqual(m.fwd_from_channel, "otherchannel")


class TestParseViews(unittest.TestCase):
    def test_plain_k_m(self):
        from tools.social.telegram.preview import parse_views
        self.assertEqual(parse_views("882"), 882)
        self.assertEqual(parse_views("1.2K"), 1200)
        self.assertEqual(parse_views("3.4M"), 3400000)


class _FakeResponse:
    def __init__(self, text="", status_ok=True):
        self.text = text
        self._status_ok = status_ok

    def raise_for_status(self):
        if not self._status_ok:
            import requests
            raise requests.HTTPError("429 Too Many Requests")


class _FakeSession:
    def __init__(self, response):
        self._response = response

    def get(self, *args, **kwargs):
        return self._response


class TestFetchPageDelay(unittest.TestCase):
    """The politeness delay must always run, even on error/no-preview paths --
    callers loop over many channels and must not hammer Telegram on failures.
    """

    def test_sleep_called_on_success(self):
        from tools.social.telegram import preview
        session = _FakeSession(_FakeResponse(text="...tgme_widget_message_wrap...", status_ok=True))
        with unittest.mock.patch.object(preview.time, "sleep") as mock_sleep:
            preview.fetch_page("telegram", None, session, vpn_check=lambda: True)
        mock_sleep.assert_called_once()

    def test_sleep_called_on_no_preview_error(self):
        from tools.social.telegram import preview
        session = _FakeSession(_FakeResponse(text="<html>join page</html>", status_ok=True))
        with unittest.mock.patch.object(preview.time, "sleep") as mock_sleep:
            with self.assertRaises(preview.NoPreviewError):
                preview.fetch_page("somechan", None, session, vpn_check=lambda: True)
        mock_sleep.assert_called_once()

    def test_sleep_called_on_http_error(self):
        from tools.social.telegram import preview
        session = _FakeSession(_FakeResponse(text="", status_ok=False))
        with unittest.mock.patch.object(preview.time, "sleep") as mock_sleep:
            with self.assertRaises(Exception):
                preview.fetch_page("telegram", None, session, vpn_check=lambda: True)
        mock_sleep.assert_called_once()

    def test_before_zero_is_sent_as_param(self):
        # before=0 is a legitimate value (not "no before") and must not be dropped.
        from tools.social.telegram import preview
        captured = {}

        class _CapturingSession:
            def get(self, url, params=None, **kwargs):
                captured["params"] = params
                return _FakeResponse(text="...tgme_widget_message_wrap...", status_ok=True)

        with unittest.mock.patch.object(preview.time, "sleep"):
            preview.fetch_page("telegram", 0, _CapturingSession(),
                               vpn_check=lambda: True)
        self.assertEqual(captured["params"], {"before": 0})


class _RecordingSession:
    """Records whether .get was ever called, for asserting it was NOT."""

    def __init__(self):
        self.calls = 0

    def get(self, *args, **kwargs):
        self.calls += 1
        return _FakeResponse(text="...tgme_widget_message_wrap...")


class TestFetchPageVpnGate(unittest.TestCase):
    """F2: the gate lives at the network boundary itself (fetch_page), not
    only at call sites -- so ungated access is structurally impossible.
    """

    def test_raises_and_never_calls_session_get_when_vpn_down(self):
        from tools.social.telegram import preview
        session = _RecordingSession()
        with self.assertRaises(preview.VPNNotActiveError):
            preview.fetch_page("telegram", None, session, vpn_check=lambda: False)
        self.assertEqual(session.calls, 0)

    def test_default_vpn_check_is_the_real_gate(self):
        # No vpn_check passed -> fetch_page must consult the real gate
        # (tools.social.telegram.vpn_gate.proton_vpn_active), not silently
        # skip enforcement. Patch the real gate to simulate "VPN down".
        from tools.social.telegram import preview
        session = _RecordingSession()
        with unittest.mock.patch.object(preview, "proton_vpn_active",
                                        return_value=False):
            with self.assertRaises(preview.VPNNotActiveError):
                preview.fetch_page("telegram", None, session)
        self.assertEqual(session.calls, 0)


if __name__ == "__main__":
    unittest.main()
