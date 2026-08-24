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

from tools.social.telegram.identity import canonical_channel
from tools.social.telegram.preview import (NoPreviewError, fetch_page,
                                           parse_preview_html)
from tools.social.telegram.store import (APPROVED, backfill_completed_at,
                                         get_cursor, mark_backfill_complete,
                                         max_msg_id, migrate_canonical_names,
                                         newest_msg_id, open_db,
                                         record_coverage, set_cursor,
                                         upsert_messages)
from tools.social.telegram.candidates import update_candidates
from tools.common.single_instance import AlreadyRunningError, single_instance
from tools.social.telegram.vpn_gate import VPNNotActiveError

_VPN_DOWN_REASON = "aborted: ProtonVPN not active"

# Backstop for every mode: N consecutive fetched pages that insert zero new
# messages means the walk is grinding for no benefit (e.g. a channel whose
# incremental/repair overlap target is wrong, or any other condition that
# makes "keep walking back" unproductive) -- stop rather than run
# unboundedly. This is what would have caught the 2026-08-22
# EvaHermanOffiziell incident (~4,400 unproductive pages over four hours)
# within a minute instead.
DEFAULT_MAX_UNPRODUCTIVE_PAGES = 20


def collect_channel(conn, username, fetch, mode, max_pages=None,
                     vpn_check=None, force=False,
                     max_unproductive_pages=DEFAULT_MAX_UNPRODUCTIVE_PAGES):
    new_total, pages, unproductive_streak = 0, 0, 0
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
        if mode in ("incremental", "repair"):
            # I1: a channel with no stored history has no resume
            # checkpoints -- silently full-walking it here would be an
            # uncheckpointed, unbounded backfill hiding inside what's
            # supposed to be a bounded incremental/repair run. Fail loudly
            # and accounted-for instead; a human runs backfill first.
            #
            # incremental (top-up only, the daily default) stops at the
            # raw MAX(msg_id): cheap and bounded, one or two pages for a
            # channel that is already up to date. repair (explicit,
            # operator-invoked, never the scheduled job) stops at the
            # CONTIGUOUS-prefix top instead, so it walks all the way down
            # to heal a real hole -- see store.newest_msg_id/max_msg_id
            # docstrings for exactly why each is correct for its mode and
            # wrong for the other.
            overlap_max = (newest_msg_id(conn, username) if mode == "incremental"
                           else max_msg_id(conn, username))
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
            unproductive_streak = 0 if inserted else unproductive_streak + 1
            if unproductive_streak >= max_unproductive_pages:
                record_coverage(conn, username)
                return {"channel": username, "status": "complete",
                        "new_messages": new_total, "failure_reason": None,
                        "stopped": (f"unproductive: {max_unproductive_pages}"
                                    " pages with no new messages")}
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
            else:  # incremental/repair: walk back until the page's own
                   # minimum overlaps the mode's overlap target, or we hit
                   # the very start. NOT merely because a page inserted
                   # zero new rows -- that early-stop is the defect (I1)
                   # that repair mode exists to avoid: a page can be
                   # entirely already-known while a real gap still sits
                   # further back, left by an earlier interrupted run.
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
    channel = canonical_channel(channel)
    set_cursor(conn, channel, None)
    mark_backfill_complete(conn, channel)


def run(conn, fetch, mode, max_pages=None, only_channel=None, vpn_check=None,
        force=False, max_unproductive_pages=DEFAULT_MAX_UNPRODUCTIVE_PAGES):
    channels = [r[0] for r in conn.execute(
        "SELECT username FROM channels WHERE status IN (?,?) ORDER BY username",
        APPROVED)]
    # A silent re-divergence between an approved channel's stored casing and
    # its canonical identity is worse than a loud stop: never even attempt
    # to collect while that holds -- run the migration first.
    non_canonical = [c for c in channels if c != canonical_channel(c)]
    if non_canonical:
        return {"mode": mode, "channels": [], "ok": False,
                "error": (
                    "approved channel(s) stored non-canonically: "
                    f"{non_canonical} -- run `python3 -m "
                    "tools.social.telegram.collect --migrate-canonical-names "
                    "--db PATH` first")}
    if only_channel:
        only_channel = canonical_channel(only_channel)
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
                            vpn_check=vpn_check, force=force,
                            max_unproductive_pages=max_unproductive_pages)
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


def run_migration(db_path: str) -> dict:
    """Run the one-shot canonical-names migration against db_path.

    Refuses (raises AlreadyRunningError, never blocks) if a collector
    currently holds the single-instance lock for this store -- the
    migration mutates the same tables a running collector writes to, and
    the two must never run concurrently.
    """
    lock_path = f"{db_path}.collector.lock"
    with single_instance(lock_path):
        conn = open_db(db_path)
        report = migrate_canonical_names(conn)
    return report


def _build_arg_parser():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True)
    ap.add_argument("--mode", choices=["backfill", "incremental", "repair"],
                    help="backfill: initial history walk to msg_id 1. "
                         "incremental: daily top-up only, stops at the raw "
                         "newest stored msg_id -- cheap and bounded, never "
                         "walks deep. repair: explicit, operator-invoked "
                         "gap-healing walk that stops at the contiguous-"
                         "history overlap instead -- can walk very deep; "
                         "never run this from the scheduled daily job.")
    ap.add_argument("--channel")
    ap.add_argument("--max-pages", type=int)
    ap.add_argument("--max-unproductive-pages", type=int,
                    default=DEFAULT_MAX_UNPRODUCTIVE_PAGES,
                    help="stop (status complete) after this many "
                         "consecutive fetched pages insert zero new "
                         "messages, in any mode (default "
                         f"{DEFAULT_MAX_UNPRODUCTIVE_PAGES})")
    ap.add_argument("--force-backfill", action="store_true",
                    help="ignore backfill completion markers and re-walk "
                         "even channels already marked complete")
    ap.add_argument("--mark-complete", metavar="CHANNEL",
                    help="maintenance: mark CHANNEL as backfill-complete "
                         "and clear its cursor, without collecting")
    ap.add_argument("--migrate-canonical-names", action="store_true",
                    help="one-shot maintenance: lowercase the channel "
                         "identity column in messages/channels/candidates/"
                         "cursors/coverage, merging any collision a "
                         "lowercase pass creates. Idempotent. Refuses if a "
                         "collector holds this store's lock.")
    return ap


if __name__ == "__main__":
    from tools.social.telegram.vpn_gate import proton_vpn_active

    ap = _build_arg_parser()
    args = ap.parse_args()

    if args.migrate_canonical_names:
        try:
            report = run_migration(args.db)
        except AlreadyRunningError:
            print(json.dumps({"ok": False,
                              "error": "another collector is already "
                                       "running",
                              "mode": "migrate-canonical-names"}))
            raise SystemExit(3)
        print(json.dumps({"ok": True,
                          "before_counts": report["before_counts"],
                          "after_counts": report["after_counts"],
                          "renames": report["renames"],
                          "merges": report["merges"]}, indent=1))
        for line in report["merge_lines"]:
            print(line)
        raise SystemExit(0)

    # --mark-complete is a lock-free maintenance path: no network, no long
    # work, just a couple of writes -- it stays exactly as it was before the
    # single-instance lock existed. It is safe to run concurrently with a
    # collector holding the lock, and requiring the lock here would only
    # block a cheap, useful maintenance fixup behind an hours-long backfill
    # for no reason.
    if args.mark_complete:
        conn = open_db(args.db)
        mark_channel_complete(conn, args.mark_complete)
        print(json.dumps({"ok": True, "marked_complete": args.mark_complete}))
        raise SystemExit(0)

    if not args.mode:
        ap.error("--mode is required unless --mark-complete is given")

    # Single-instance lock, acquired BEFORE any work (including the VPN
    # check) -- see single_instance.py's module docstring for why this is
    # flock-based rather than a PID file. Per store, so an unrelated store's
    # collector never contends with this one.
    lock_path = f"{args.db}.collector.lock"
    try:
        with single_instance(lock_path):
            # Hard rule: never contact Telegram unless ProtonVPN is
            # connected — the user's home IP must never reach t.me. Checked
            # BEFORE opening any HTTP session, no override flag exists,
            # this is absolute.
            if not proton_vpn_active():
                print(json.dumps({"ok": False,
                                  "error": "ProtonVPN not active — refusing "
                                           "to contact Telegram"}))
                raise SystemExit(2)

            conn = open_db(args.db)
            session = requests.Session()
            report = run(conn, lambda u, b: fetch_page(u, b, session),
                         args.mode, max_pages=args.max_pages,
                         only_channel=args.channel,
                         vpn_check=proton_vpn_active,
                         force=args.force_backfill,
                         max_unproductive_pages=args.max_unproductive_pages)
            print(json.dumps(report, indent=1))
            raise SystemExit(0 if report["ok"] else 1)
    except AlreadyRunningError:
        print(json.dumps({"ok": False,
                          "error": "another collector is already running",
                          "mode": args.mode}))
        raise SystemExit(3)
