"""Gated reachability checker for Telegram usernames.

Replaces the bare `curl -sI https://t.me/s/<username>` step that used to be
documented for seed-list curation (see
docs/superpowers/plans/2026-08-21-telegram-collector.md, seed-list Step 1).
That curl command is a network path with NO ProtonVPN gate at all -- it can
leak the user's home IP to Telegram. This CLI is gated the same way
collect.py is: it hard-aborts (exit 2) if ProtonVPN is not active, and every
actual check goes through preview.fetch_page, which itself enforces the gate
again at the network boundary (F2 hardening).

Usage:
    python3 -m tools.social.telegram.check_reachable somechan otherchan
    python3 -m tools.social.telegram.check_reachable --db path/to/telegram.db
"""
import pathlib
import sys

# Shim so this module works both as `python3 -m tools.social.telegram.
# check_reachable` and as a direct-file invocation (`python3
# tools/social/telegram/check_reachable.py`) -- same pattern as collect.py.
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3]))

import argparse
import json

import requests

from tools.social.telegram.preview import NoPreviewError, fetch_page
from tools.social.telegram.store import APPROVED, open_db
from tools.social.telegram.vpn_gate import proton_vpn_active


def check_username(username: str, session, fetch=None) -> bool:
    """True iff username has a reachable public web preview.

    `fetch` defaults to preview.fetch_page (real network + real VPN gate);
    tests inject a fake to avoid any network access.
    """
    fetch = fetch or fetch_page
    try:
        fetch(username, None, session)
        return True
    except (NoPreviewError, requests.RequestException):
        return False


def main(argv, vpn_check=None, fetch=None, open_db_fn=None, db_path=None) -> int:
    """Returns a process exit code. Never makes a network request unless
    vpn_check() is True.
    """
    vpn_check = vpn_check if vpn_check is not None else proton_vpn_active
    open_db_fn = open_db_fn if open_db_fn is not None else open_db

    ap = argparse.ArgumentParser()
    ap.add_argument("usernames", nargs="*")
    ap.add_argument("--db")
    args = ap.parse_args(argv)

    # Hard rule: never contact Telegram unless ProtonVPN is connected — same
    # rule, same JSON-error shape, as collect.py's CLI hard-abort.
    if not vpn_check():
        print(json.dumps({"ok": False,
                          "error": "ProtonVPN not active — refusing to "
                                   "contact Telegram"}))
        return 2

    usernames = list(args.usernames)
    db = db_path if db_path is not None else args.db
    if db:
        conn = open_db_fn(db)
        usernames += [r[0] for r in conn.execute(
            "SELECT username FROM channels WHERE status IN (?,?) "
            "ORDER BY username", APPROVED)]

    session = requests.Session()
    for u in usernames:
        reachable = check_username(u, session, fetch=fetch)
        print(f"{u}: {'reachable' if reachable else 'unreachable'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
