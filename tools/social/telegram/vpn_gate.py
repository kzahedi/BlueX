"""Hard ProtonVPN gate — never contact Telegram from the home IP.

The user's home IP must never reach t.me. proton_vpn_active() is the single
source of truth callers must check before any HTTP request to Telegram, and
it fails CLOSED: any error (missing binary, timeout, unexpected exception)
is treated as "VPN not active", never as "VPN active".

Detection requires BOTH:
  (a) an interface whose name starts with "utun", whose flags contain both
      UP and RUNNING, carrying an `inet 10.2.0.` address (has_proton_interface
      / find_proton_utun_interface); and
  (b) the OS routing table actually sending traffic through that SAME utun
      interface (`route -n get 1.1.1.1` -> `interface: <name>`).

A bare substring search for "inet 10.2.0." anywhere in ifconfig output is
NOT sufficient: it doesn't require a tunnel interface, doesn't require the
interface to be UP/RUNNING, and a stale utun left over after a crash, a
Docker/VM bridge, or another WireGuard tool on the same subnet would all
read as "connected" under that weaker rule. Requiring routing agreement
closes the case where a utun interface exists and looks right but the OS
isn't actually sending traffic through it (i.e. it would leak via another
interface, such as en0).
"""
import re
import subprocess

PROTON_SUBNET_PREFIX = "10.2.0."

# Probe the path TELEGRAM traffic will actually take, not a generic host: a
# host-specific route (split tunnel, or a DNS tool installing a /32) can send
# 1.1.1.1 through the tunnel while t.me still exits via en0. Two addresses
# from Telegram's ranges; ALL must route through the tunnel interface.
ROUTE_PROBE_TARGETS = ("149.154.167.99", "149.154.175.100")

# Telegram publishes AAAA records. If an IPv6 route to Telegram exists and it
# does NOT go through the tunnel, requests could leak over IPv6 while every
# IPv4 check reads green. No IPv6 route at all is safe (nothing to leak over).
ROUTE_PROBE_TARGET_V6 = "2001:67c:4e8:f004::9"


class VPNNotActiveError(Exception):
    """Raised at the network boundary when ProtonVPN is not active."""


def _interface_blocks(ifconfig_text: str):
    """Yield (name, flags_str, block_text) for each interface stanza.

    ifconfig output looks like:
        utun7: flags=80d1<UP,POINTOPOINT,RUNNING,PROMISC,MULTICAST> mtu 1420
        \tinet 10.2.0.2 --> 10.2.0.2 netmask 0xffffffff
    A new stanza starts at a line with no leading whitespace containing
    "<name>: flags=...<FLAGS>...". Everything indented below it belongs to
    that interface until the next unindented header line.
    """
    header_re = re.compile(r"^(\S+):.*flags=[0-9a-fA-F]+<([^>]*)>")
    name = None
    flags = ""
    lines: list[str] = []
    for line in ifconfig_text.splitlines():
        m = header_re.match(line)
        if m:
            if name is not None:
                yield name, flags, "\n".join(lines)
            name, flags = m.group(1), m.group(2)
            lines = []
        else:
            lines.append(line)
    if name is not None:
        yield name, flags, "\n".join(lines)


def find_proton_utun_interface(ifconfig_text: str) -> str | None:
    """Name of the first utun interface that is UP, RUNNING, and carries a
    10.2.0.x address — or None if no such interface exists.
    """
    for name, flags, block in _interface_blocks(ifconfig_text):
        if not name.startswith("utun"):
            continue
        flag_set = set(flags.split(","))
        if "UP" not in flag_set or "RUNNING" not in flag_set:
            continue
        if any(f"inet {PROTON_SUBNET_PREFIX}" in bline
               for bline in block.splitlines()):
            return name
    return None


def has_proton_interface(ifconfig_text: str) -> bool:
    """True iff a utun interface is UP, RUNNING, and carries a 10.2.0.x
    address. See module docstring for why a bare substring match is not
    sufficient.
    """
    return find_proton_utun_interface(ifconfig_text) is not None


def route_interface(route_text: str) -> str | None:
    """Parse `route -n get <dest>` output for its `interface: <name>` line."""
    m = re.search(r"^\s*interface:\s*(\S+)", route_text, re.MULTILINE)
    return m.group(1) if m else None


def proton_vpn_active() -> bool:
    """Runs /sbin/ifconfig and /sbin/route to verify ProtonVPN is both
    present (a UP/RUNNING utun interface on the Proton subnet) AND actually
    carrying traffic (the routing table agrees on that same interface).

    Any subprocess error (missing binary, timeout, non-zero exit raising,
    unexpected exception) on either command fails CLOSED: returns False,
    never True.
    """
    try:
        ifconfig_result = subprocess.run(
            ["/sbin/ifconfig"],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except Exception:
        return False

    utun_name = find_proton_utun_interface(ifconfig_result.stdout or "")
    if utun_name is None:
        return False

    # Every Telegram probe address must route through that same interface.
    for target in ROUTE_PROBE_TARGETS:
        try:
            route_result = subprocess.run(
                ["/sbin/route", "-n", "get", target],
                capture_output=True,
                text=True,
                timeout=5,
            )
        except Exception:
            return False
        if route_interface(route_result.stdout or "") != utun_name:
            return False

    # IPv6: a route that exists but bypasses the tunnel is a leak path. A
    # missing/unresolvable IPv6 route is fine — there is nothing to leak over.
    try:
        route6_result = subprocess.run(
            ["/sbin/route", "-n", "get", "-inet6", ROUTE_PROBE_TARGET_V6],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except Exception:
        return False
    iface6 = route_interface(route6_result.stdout or "")
    if iface6 is not None and iface6 != utun_name:
        return False

    return True
