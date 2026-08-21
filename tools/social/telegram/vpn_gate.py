"""Hard ProtonVPN gate — never contact Telegram from the home IP.

The user's home IP must never reach t.me. proton_vpn_active() is the single
source of truth callers must check before any HTTP request to Telegram, and
it fails CLOSED: any error (missing binary, timeout, unexpected exception)
is treated as "VPN not active", never as "VPN active".
"""
import subprocess

PROTON_SIGNAL = "inet 10.2.0."


def has_proton_interface(ifconfig_text: str) -> bool:
    """True iff a line contains the substring 'inet 10.2.0.' anywhere.

    Leading whitespace/tabs before the substring are irrelevant since this
    is a plain substring search, not a line-anchored match.
    """
    return PROTON_SIGNAL in ifconfig_text


def proton_vpn_active() -> bool:
    """Runs /sbin/ifconfig and checks for the ProtonVPN WireGuard interface.

    Any subprocess error (missing binary, timeout, non-zero exit raising,
    unexpected exception) fails CLOSED: returns False, never True.
    """
    try:
        result = subprocess.run(
            ["/sbin/ifconfig"],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except Exception:
        return False
    return has_proton_interface(result.stdout or "")
