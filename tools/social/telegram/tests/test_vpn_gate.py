import unittest

from tools.social.telegram.vpn_gate import has_proton_interface, proton_vpn_active

IFCONFIG_WITH_VPN = """\
lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
\tinet 127.0.0.1 netmask 0xff000000
en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
\tinet 192.168.1.42 netmask 0xffffff00 broadcast 192.168.1.255
utun7: flags=80d1<UP,POINTOPOINT,RUNNING,PROMISC,MULTICAST> mtu 1420
\tinet 10.2.0.2 --> 10.2.0.2 netmask 0xffffffff
"""

IFCONFIG_WITHOUT_VPN = """\
lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
\tinet 127.0.0.1 netmask 0xff000000
en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
\tinet 192.168.1.42 netmask 0xffffff00 broadcast 192.168.1.255
"""

# 10.2.0. appears, but not as "inet 10.2.0." — should NOT count.
IFCONFIG_COMMENT_LOOKALIKE = """\
lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
\tinet 127.0.0.1 netmask 0xff000000
# some note mentioning 10.2.0.5 in a comment, not an inet line
en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
\tinet 192.168.1.42 netmask 0xffffff00 broadcast 192.168.1.255
"""


class TestHasProtonInterface(unittest.TestCase):
    def test_detects_proton_interface(self):
        self.assertTrue(has_proton_interface(IFCONFIG_WITH_VPN))

    def test_absent_when_no_proton_interface(self):
        self.assertFalse(has_proton_interface(IFCONFIG_WITHOUT_VPN))

    def test_leading_whitespace_tolerated(self):
        text = "utun3:\n    inet 10.2.0.2 --> 10.2.0.2 netmask 0xffffffff\n"
        self.assertTrue(has_proton_interface(text))

    def test_tab_indentation_tolerated(self):
        text = "utun3:\n\tinet 10.2.0.2 --> 10.2.0.2 netmask 0xffffffff\n"
        self.assertTrue(has_proton_interface(text))

    def test_substring_match_is_simple_rule(self):
        # Per spec: substring "inet 10.2.0." anywhere counts as active, even
        # in a line that merely mentions it (keeps the rule simple).
        self.assertTrue(has_proton_interface("inet 10.2.0.5 whatever"))

    def test_comment_lookalike_without_inet_prefix_is_false(self):
        self.assertFalse(has_proton_interface(IFCONFIG_COMMENT_LOOKALIKE))

    def test_empty_string_is_false(self):
        self.assertFalse(has_proton_interface(""))


class TestProtonVpnActive(unittest.TestCase):
    def test_true_when_subprocess_reports_vpn(self):
        import tools.social.telegram.vpn_gate as vpn_gate

        class FakeCompletedProcess:
            stdout = IFCONFIG_WITH_VPN

        def fake_run(*args, **kwargs):
            return FakeCompletedProcess()

        orig = vpn_gate.subprocess.run
        vpn_gate.subprocess.run = fake_run
        try:
            self.assertTrue(proton_vpn_active())
        finally:
            vpn_gate.subprocess.run = orig

    def test_false_when_subprocess_reports_no_vpn(self):
        import tools.social.telegram.vpn_gate as vpn_gate

        class FakeCompletedProcess:
            stdout = IFCONFIG_WITHOUT_VPN

        def fake_run(*args, **kwargs):
            return FakeCompletedProcess()

        orig = vpn_gate.subprocess.run
        vpn_gate.subprocess.run = fake_run
        try:
            self.assertFalse(proton_vpn_active())
        finally:
            vpn_gate.subprocess.run = orig

    def test_subprocess_error_fails_closed(self):
        import tools.social.telegram.vpn_gate as vpn_gate

        def fake_run(*args, **kwargs):
            raise OSError("ifconfig not found")

        orig = vpn_gate.subprocess.run
        vpn_gate.subprocess.run = fake_run
        try:
            self.assertFalse(proton_vpn_active())
        finally:
            vpn_gate.subprocess.run = orig

    def test_subprocess_timeout_fails_closed(self):
        import subprocess
        import tools.social.telegram.vpn_gate as vpn_gate

        def fake_run(*args, **kwargs):
            raise subprocess.TimeoutExpired(cmd="/sbin/ifconfig", timeout=5)

        orig = vpn_gate.subprocess.run
        vpn_gate.subprocess.run = fake_run
        try:
            self.assertFalse(proton_vpn_active())
        finally:
            vpn_gate.subprocess.run = orig


if __name__ == "__main__":
    unittest.main()
