import unittest

from tools.social.telegram.preview import NoPreviewError


def page_html(channel, ids):
    """Minimal t.me/s-shaped HTML the parser accepts."""
    msgs = "".join(
        f'<div class="tgme_widget_message" data-post="{channel}/{i}">'
        f'<div class="tgme_widget_message_text">msg {i}</div>'
        f'<span class="tgme_widget_message_views">5</span>'
        f'<a class="tgme_widget_message_date" href="https://t.me/{channel}/{i}">'
        f'<time datetime="2026-08-01T10:00:{i % 60:02d}+00:00"></time></a></div>'
        for i in ids)
    return f'<html><body class="tgme_widget_message_wrap">{msgs}</body></html>'


def make_fake_fetch(channel, all_ids, calls=None):
    """Serves pages of 5 ids, newest first, honouring ?before like t.me/s."""
    def fetch(username, before):
        if calls is not None:
            calls.append(before)
        older = sorted(i for i in all_ids if before is None or i < before)
        page = older[-5:]
        return page_html(channel, page)
    return fetch


class TestCollect(unittest.TestCase):
    def setUp(self):
        from tools.social.telegram.store import open_db
        self.conn = open_db(":memory:")
        self.conn.execute("INSERT INTO channels(username, status) "
                          "VALUES ('chan', 'seed_approved')")
        self.conn.commit()

    def test_backfill_walks_to_start_and_clears_cursor(self):
        from tools.social.telegram.collect import collect_channel
        from tools.social.telegram.store import get_cursor
        fetch = make_fake_fetch("chan", list(range(1, 14)))
        r = collect_channel(self.conn, "chan", fetch, mode="backfill")
        self.assertEqual(r["status"], "complete")
        self.assertEqual(r["new_messages"], 13)
        self.assertIsNone(get_cursor(self.conn, "chan"))

    def test_backfill_resumes_from_cursor(self):
        from tools.social.telegram.collect import collect_channel
        from tools.social.telegram.store import set_cursor
        calls = []
        fetch = make_fake_fetch("chan", list(range(1, 14)), calls)
        set_cursor(self.conn, "chan", 6)   # simulate a crash mid-history
        collect_channel(self.conn, "chan", fetch, mode="backfill")
        self.assertEqual(calls[0], 6)      # resumed, not restarted

    def test_no_preview_is_recorded_failure_not_crash(self):
        from tools.social.telegram.collect import collect_channel
        def fetch(username, before):
            raise NoPreviewError("chan: no public web preview")
        r = collect_channel(self.conn, "chan", fetch, mode="backfill")
        self.assertEqual(r["status"], "failed")
        self.assertIn("no public web preview", r["failure_reason"])

    def test_run_ok_requires_every_channel_accounted_for(self):
        from tools.social.telegram.collect import run
        self.conn.execute("INSERT INTO channels(username, status) "
                          "VALUES ('dead', 'seed_approved')")
        good = make_fake_fetch("chan", [1, 2, 3])
        def fetch(username, before):
            if username == "dead":
                raise NoPreviewError("dead: no public web preview")
            return good(username, before)
        report = run(self.conn, fetch, mode="backfill")
        self.assertTrue(report["ok"])      # failed-with-reason counts as accounted
        statuses = {c["channel"]: c["status"] for c in report["channels"]}
        self.assertEqual(statuses, {"chan": "complete", "dead": "failed"})

    def test_unapproved_channels_never_collected(self):
        from tools.social.telegram.collect import run
        self.conn.execute("INSERT INTO channels(username, status) "
                          "VALUES ('pendingchan', 'seed_pending')")
        fetch = make_fake_fetch("chan", [1, 2])
        report = run(self.conn, fetch, mode="backfill")
        self.assertNotIn("pendingchan", [c["channel"] for c in report["channels"]])


if __name__ == "__main__":
    unittest.main()
