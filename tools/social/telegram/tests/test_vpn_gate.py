import subprocess
import unittest

from tools.social.telegram.vpn_gate import (has_proton_interface,
                                             proton_vpn_active,
                                             route_interface)

# --- Realistic fixtures -----------------------------------------------

IFCONFIG_REAL_PROTON = """\
lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
\tinet 127.0.0.1 netmask 0xff000000
en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
\tinet 192.168.1.42 netmask 0xffffff00 broadcast 192.168.1.255
utun7: flags=80d1<UP,POINTOPOINT,RUNNING,PROMISC,MULTICAST> mtu 1420
\tinet 10.2.0.2 --> 10.2.0.2 netmask 0xffffffff
"""

ROUTE_REAL_PROTON = """\
   route to: 1.1.1.1
destination: default
       mask: default
    gateway: 10.2.0.1
  interface: utun7
      flags: <UP,GATEWAY,DONE,STATIC,PRCLONING>
"""

IFCONFIG_NO_VPN = """\
lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
\tinet 127.0.0.1 netmask 0xff000000
en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
\tinet 192.168.1.42 netmask 0xffffff00 broadcast 192.168.1.255
"""

ROUTE_VIA_EN0 = """\
   route to: 1.1.1.1
destination: default
       mask: default
    gateway: 192.168.1.1
  interface: en0
      flags: <UP,GATEWAY,DONE,STATIC,PRCLONING>
"""

# Stale utun left over after a crash: present, has the right address, but
# is administratively down (no RUNNING, no UP even) -- must not count.
IFCONFIG_STALE_UTUN = """\
lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
\tinet 127.0.0.1 netmask 0xff000000
utun7: flags=8010<POINTOPOINT> mtu 1420
\tinet 10.2.0.2 --> 10.2.0.2 netmask 0xffffffff
"""

# A Docker/VM bridge on the same subnet -- not a tunnel interface at all.
IFCONFIG_BRIDGE_LOOKALIKE = """\
lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
\tinet 127.0.0.1 netmask 0xff000000
bridge100: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
\tinet 10.2.0.5 netmask 0xffffff00 broadcast 10.2.0.255
vmnet1: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
\tinet 10.2.0.9 netmask 0xffffff00 broadcast 10.2.0.255
"""


class TestHasProtonInterface(unittest.TestCase):
    def test_real_proton_shape_is_true(self):
        self.assertTrue(has_proton_interface(IFCONFIG_REAL_PROTON))

    def test_absent_when_no_proton_interface(self):
        self.assertFalse(has_proton_interface(IFCONFIG_NO_VPN))

    def test_stale_utun_without_running_flag_is_false(self):
        self.assertFalse(has_proton_interface(IFCONFIG_STALE_UTUN))

    def test_non_utun_bridge_with_matching_subnet_is_false(self):
        self.assertFalse(has_proton_interface(IFCONFIG_BRIDGE_LOOKALIKE))

    def test_empty_string_is_false(self):
        self.assertFalse(has_proton_interface(""))


class TestRouteInterface(unittest.TestCase):
    def test_parses_interface_line(self):
        self.assertEqual(route_interface(ROUTE_REAL_PROTON), "utun7")

    def test_returns_none_when_no_interface_line(self):
        self.assertIsNone(route_interface("route to: 1.1.1.1\n"))

    def test_returns_none_for_empty_string(self):
        self.assertIsNone(route_interface(""))


def _fake_run_factory(ifconfig_text=None, route_text=None,
                       ifconfig_exc=None, route_exc=None):
    def fake_run(cmd, *args, **kwargs):
        class FakeCompletedProcess:
            def __init__(self, stdout):
                self.stdout = stdout

        if cmd[0] == "/sbin/ifconfig":
            if ifconfig_exc is not None:
                raise ifconfig_exc
            return FakeCompletedProcess(ifconfig_text)
        elif cmd[0] == "/sbin/route":
            if route_exc is not None:
                raise route_exc
            return FakeCompletedProcess(route_text)
        raise AssertionError(f"unexpected command: {cmd}")
    return fake_run


class TestProtonVpnActive(unittest.TestCase):
    def setUp(self):
        import tools.social.telegram.vpn_gate as vpn_gate
        self.vpn_gate = vpn_gate
        self._orig_run = vpn_gate.subprocess.run

    def tearDown(self):
        self.vpn_gate.subprocess.run = self._orig_run

    def test_true_when_real_proton_shape_and_route_agree(self):
        self.vpn_gate.subprocess.run = _fake_run_factory(
            ifconfig_text=IFCONFIG_REAL_PROTON, route_text=ROUTE_REAL_PROTON)
        self.assertTrue(self.vpn_gate.proton_vpn_active())

    def test_false_when_no_vpn_interface_at_all(self):
        self.vpn_gate.subprocess.run = _fake_run_factory(
            ifconfig_text=IFCONFIG_NO_VPN, route_text=ROUTE_VIA_EN0)
        self.assertFalse(self.vpn_gate.proton_vpn_active())

    def test_false_when_stale_utun_lacks_running_flag(self):
        self.vpn_gate.subprocess.run = _fake_run_factory(
            ifconfig_text=IFCONFIG_STALE_UTUN, route_text=ROUTE_REAL_PROTON)
        self.assertFalse(self.vpn_gate.proton_vpn_active())

    def test_false_when_bridge_carries_matching_subnet(self):
        self.vpn_gate.subprocess.run = _fake_run_factory(
            ifconfig_text=IFCONFIG_BRIDGE_LOOKALIKE, route_text=ROUTE_VIA_EN0)
        self.assertFalse(self.vpn_gate.proton_vpn_active())

    def test_false_when_utun_present_but_route_disagrees(self):
        # The key false-positive this hardening closes: a utun interface is
        # UP/RUNNING with the right address, but the OS is not actually
        # routing traffic through it -- traffic would leak via en0.
        self.vpn_gate.subprocess.run = _fake_run_factory(
            ifconfig_text=IFCONFIG_REAL_PROTON, route_text=ROUTE_VIA_EN0)
        self.assertFalse(self.vpn_gate.proton_vpn_active())

    def test_false_when_ifconfig_subprocess_errors(self):
        self.vpn_gate.subprocess.run = _fake_run_factory(
            ifconfig_exc=OSError("ifconfig not found"),
            route_text=ROUTE_REAL_PROTON)
        self.assertFalse(self.vpn_gate.proton_vpn_active())

    def test_false_when_route_subprocess_times_out(self):
        self.vpn_gate.subprocess.run = _fake_run_factory(
            ifconfig_text=IFCONFIG_REAL_PROTON,
            route_exc=subprocess.TimeoutExpired(cmd="/sbin/route", timeout=5))
        self.assertFalse(self.vpn_gate.proton_vpn_active())

    def test_false_when_ifconfig_times_out(self):
        self.vpn_gate.subprocess.run = _fake_run_factory(
            ifconfig_exc=subprocess.TimeoutExpired(cmd="/sbin/ifconfig",
                                                     timeout=5),
            route_text=ROUTE_REAL_PROTON)
        self.assertFalse(self.vpn_gate.proton_vpn_active())


if __name__ == "__main__":
    unittest.main()
