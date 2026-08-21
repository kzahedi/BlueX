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

    try:
        route_result = subprocess.run(
            ["/sbin/route", "-n", "get", "1.1.1.1"],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except Exception:
        return False

    return route_interface(route_result.stdout or "") == utun_name
