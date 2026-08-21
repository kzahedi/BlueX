"""Backfill / incremental collector over approved channels (spec §5-§6).

Reconciliation rule: run() reports ok=True only when every approved channel
either completed or recorded its failure reason. Silence is the failure mode
being designed out."""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3]))

import argparse
import json

import requests

from tools.social.telegram.preview import (NoPreviewError, fetch_page,
                                           parse_preview_html)
from tools.social.telegram.store import (APPROVED, backfill_completed_at,
                                         get_cursor, mark_backfill_complete,
                                         max_msg_id, open_db, record_coverage,
                                         set_cursor, upsert_messages)
from tools.social.telegram.candidates import update_candidates
from tools.social.telegram.vpn_gate import VPNNotActiveError

_VPN_DOWN_REASON = "aborted: ProtonVPN not active"


def collect_channel(conn, username, fetch, mode, max_pages=None,
                     vpn_check=None, force=False):
    new_total, pages = 0, 0
    try:
        before = get_cursor(conn, username) if mode == "backfill" else None
        # A completed backfill clears its cursor as the completion signal,
        # but that's indistinguishable from "never walked" without an
        # explicit marker -- without this check, every subsequent backfill
        # re-walks the channel's entire history for zero new rows.
        if (mode == "backfill" and not force and before is None
                and backfill_completed_at(conn, username) is not None):
            return {"channel": username, "status": "complete",
                    "new_messages": 0, "failure_reason": None,
                    "skipped": "already-backfilled"}
        overlap_max = None
        if mode == "incremental":
            # I1: a channel with no stored history has no resume
            # checkpoints -- silently full-walking it here would be an
            # uncheckpointed, unbounded backfill hiding inside what's
            # supposed to be a bounded incremental run. Fail loudly and
            # accounted-for instead; a human runs backfill first.
            overlap_max = max_msg_id(conn, username)
            if overlap_max is None:
                return {"channel": username, "status": "failed",
                        "new_messages": 0,
                        "failure_reason": "no history: run backfill first"}
        while True:
            # F1: checked at the top of EVERY page iteration -- a mid-channel
            # tunnel drop must stop the walk immediately, not go unnoticed
            # for the rest of a (potentially hours-long) channel walk.
            if vpn_check is not None and not vpn_check():
                record_coverage(conn, username)
                return {"channel": username, "status": "failed",
                        "new_messages": new_total,
                        "failure_reason": _VPN_DOWN_REASON}
            if max_pages is not None and pages >= max_pages:
                record_coverage(conn, username)
                return {"channel": username, "status": "failed",
                        "new_messages": new_total,
                        "failure_reason": f"page budget exhausted ({max_pages})"}
            fetched_before = before
            msgs = parse_preview_html(fetch(username, before))
            pages += 1
            if not msgs:
                break
            inserted = upsert_messages(conn, msgs)
            new_total += inserted
            oldest = min(m.msg_id for m in msgs)
            if mode == "backfill":
                if fetched_before is not None and oldest >= fetched_before:
                    record_coverage(conn, username)
                    return {"channel": username, "status": "failed",
                            "new_messages": new_total,
                            "failure_reason": (
                                f"no progress: page at before={fetched_before}"
                                f" returned oldest={oldest}")}
                set_cursor(conn, username, oldest)
                if oldest <= 1:
                    break
                before = oldest
            else:  # incremental: walk back until the page's own minimum
                   # overlaps already-known contiguous history, or we hit
                   # the very start. NOT merely because a page inserted
                   # zero new rows -- that early-stop is the defect (I1):
                   # a page can be entirely already-known while a real
                   # gap still sits further back, left by an earlier
                   # interrupted run.
                before = oldest
                if oldest <= overlap_max or oldest <= 1:
                    break
        if mode == "backfill":
            set_cursor(conn, username, None)
            mark_backfill_complete(conn, username)
        record_coverage(conn, username)
        return {"channel": username, "status": "complete",
                "new_messages": new_total, "failure_reason": None}
    except (NoPreviewError, requests.RequestException, VPNNotActiveError) as e:
        try:
            record_coverage(conn, username)
        except Exception:
            pass  # never let a coverage error mask the real failure reason
        # F2: VPNNotActiveError can also surface here if fetch_page's own
        # network-boundary gate tripped (e.g. VPN dropped between our
        # per-page check above and the actual HTTP call) -- recorded with
        # the same reason string as the per-page check, never a crash.
        reason = _VPN_DOWN_REASON if isinstance(e, VPNNotActiveError) else str(e)
        return {"channel": username, "status": "failed",
                "new_messages": new_total, "failure_reason": reason}


def mark_channel_complete(conn, channel: str) -> None:
    """Idempotent maintenance: mark `channel` as backfill-complete and
    clear any stale cursor, without walking it. For a channel that is
    genuinely complete in the DB (e.g. holds msg_id 1) but carries a
    cursor left over from an interrupted re-walk and no marker."""
    set_cursor(conn, channel, None)
    mark_backfill_complete(conn, channel)


def run(conn, fetch, mode, max_pages=None, only_channel=None, vpn_check=None,
        force=False):
    channels = [r[0] for r in conn.execute(
        "SELECT username FROM channels WHERE status IN (?,?) ORDER BY username",
        APPROVED)]
    if only_channel:
        channels = [c for c in channels if c == only_channel]
    results = []
    aborted = False
    for c in channels:
        if aborted:
            results.append({"channel": c, "status": "failed",
                             "new_messages": 0,
                             "failure_reason": _VPN_DOWN_REASON})
            continue
        r = collect_channel(conn, c, fetch, mode, max_pages,
                            vpn_check=vpn_check, force=force)
        if vpn_check is not None and r["failure_reason"] == _VPN_DOWN_REASON:
            # Once one channel aborts on a VPN drop, don't bother checking
            # again for the rest of the run -- it isn't coming back up
            # mid-run, and every remaining channel is accounted for as
            # aborted without spending a fetch attempt on any of them.
            aborted = True
        results.append(r)
    update_candidates(conn)
    ok = all(r["status"] == "complete" or r["failure_reason"] for r in results)
    return {"mode": mode, "channels": results, "ok": ok}


def _build_arg_parser():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True)
    ap.add_argument("--mode", choices=["backfill", "incremental"])
    ap.add_argument("--channel")
    ap.add_argument("--max-pages", type=int)
    ap.add_argument("--force-backfill", action="store_true",
                    help="ignore backfill completion markers and re-walk "
                         "even channels already marked complete")
    ap.add_argument("--mark-complete", metavar="CHANNEL",
                    help="maintenance: mark CHANNEL as backfill-complete "
                         "and clear its cursor, without collecting")
    return ap


if __name__ == "__main__":
    from tools.social.telegram.vpn_gate import proton_vpn_active

    ap = _build_arg_parser()
    args = ap.parse_args()

    if args.mark_complete:
        conn = open_db(args.db)
        mark_channel_complete(conn, args.mark_complete)
        print(json.dumps({"ok": True, "marked_complete": args.mark_complete}))
        raise SystemExit(0)

    if not args.mode:
        ap.error("--mode is required unless --mark-complete is given")

    # Hard rule: never contact Telegram unless ProtonVPN is connected — the
    # user's home IP must never reach t.me. Checked BEFORE opening any HTTP
    # session, no override flag exists, this is absolute.
    if not proton_vpn_active():
        print(json.dumps({"ok": False,
                          "error": "ProtonVPN not active — refusing to "
                                   "contact Telegram"}))
        raise SystemExit(2)

    conn = open_db(args.db)
    session = requests.Session()
    report = run(conn, lambda u, b: fetch_page(u, b, session), args.mode,
                 max_pages=args.max_pages, only_channel=args.channel,
                 vpn_check=proton_vpn_active, force=args.force_backfill)
    print(json.dumps(report, indent=1))
    raise SystemExit(0 if report["ok"] else 1)
