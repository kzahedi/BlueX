import io
import unittest
import unittest.mock

from tools.social.telegram.preview import NoPreviewError


class TestCheckUsername(unittest.TestCase):
    def test_reachable_when_fetch_succeeds(self):
        from tools.social.telegram.check_reachable import check_username

        def fake_fetch(username, before, session, vpn_check=None):
            return "<html>...tgme_widget_message_wrap...</html>"

        self.assertTrue(check_username("telegram", session=object(),
                                       fetch=fake_fetch))

    def test_unreachable_on_no_preview(self):
        from tools.social.telegram.check_reachable import check_username

        def fake_fetch(username, before, session, vpn_check=None):
            raise NoPreviewError(f"{username}: no public web preview")

        self.assertFalse(check_username("ghostchan", session=object(),
                                        fetch=fake_fetch))

    def test_unreachable_on_request_exception(self):
        from tools.social.telegram.check_reachable import check_username
        import requests

        def fake_fetch(username, before, session, vpn_check=None):
            raise requests.HTTPError("404")

        self.assertFalse(check_username("deadchan", session=object(),
                                        fetch=fake_fetch))


class TestMain(unittest.TestCase):
    def test_hard_aborts_with_exit_2_when_vpn_down(self):
        from tools.social.telegram.check_reachable import main

        fetch_calls = []

        def fetch(username, before, session, vpn_check=None):
            fetch_calls.append(username)
            return "<html>...tgme_widget_message_wrap...</html>"

        with unittest.mock.patch("sys.stdout", new_callable=io.StringIO) as out:
            code = main(["somechan"], vpn_check=lambda: False, fetch=fetch)

        self.assertEqual(code, 2)
        self.assertEqual(fetch_calls, [])
        # Same JSON-error shape as collect.py's CLI hard-abort.
        self.assertIn('"ok": false', out.getvalue())
        self.assertIn("ProtonVPN not active", out.getvalue())

    def test_checks_each_username_given_on_command_line(self):
        from tools.social.telegram.check_reachable import main

        seen = []

        def fetch(username, before, session, vpn_check=None):
            seen.append(username)
            if username == "deadchan":
                raise NoPreviewError(f"{username}: no public web preview")
            return "<html>...tgme_widget_message_wrap...</html>"

        with unittest.mock.patch("sys.stdout", new_callable=io.StringIO) as out:
            code = main(["livechan", "deadchan"], vpn_check=lambda: True,
                        fetch=fetch)

        self.assertEqual(code, 0)
        self.assertEqual(seen, ["livechan", "deadchan"])
        printed = out.getvalue()
        self.assertIn("livechan: reachable", printed)
        self.assertIn("deadchan: unreachable", printed)

    def test_canonicalizes_command_line_usernames(self):
        from tools.social.telegram.check_reachable import main

        seen = []

        def fetch(username, before, session, vpn_check=None):
            seen.append(username)
            return "<html>...tgme_widget_message_wrap...</html>"

        with unittest.mock.patch("sys.stdout", new_callable=io.StringIO) as out:
            code = main(["@FrankKraemer", "  QUERDENKEN_711  "],
                        vpn_check=lambda: True, fetch=fetch)

        self.assertEqual(code, 0)
        self.assertEqual(seen, ["frankkraemer", "querdenken_711"])
        printed = out.getvalue()
        self.assertIn("frankkraemer: reachable", printed)
        self.assertIn("querdenken_711: reachable", printed)

    def test_checks_channels_from_db_when_given(self):
        from tools.social.telegram.check_reachable import main
        from tools.social.telegram.store import open_db

        conn = open_db(":memory:")
        conn.execute("INSERT INTO channels(username, status) "
                    "VALUES ('approved1', 'seed_approved')")
        conn.execute("INSERT INTO channels(username, status) "
                    "VALUES ('notapproved', 'seed_pending')")
        conn.commit()

        seen = []

        def fetch(username, before, session, vpn_check=None):
            seen.append(username)
            return "<html>...tgme_widget_message_wrap...</html>"

        with unittest.mock.patch("sys.stdout", new_callable=io.StringIO):
            code = main([], vpn_check=lambda: True, fetch=fetch,
                       open_db_fn=lambda path: conn, db_path=":memory:")

        self.assertEqual(code, 0)
        self.assertEqual(seen, ["approved1"])


if __name__ == "__main__":
    unittest.main()
