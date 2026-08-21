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
from tools.social.telegram.store import (APPROVED, get_cursor, open_db,
                                         record_coverage, set_cursor,
                                         upsert_messages)
from tools.social.telegram.candidates import update_candidates


def collect_channel(conn, username, fetch, mode, max_pages=None):
    new_total, pages = 0, 0
    try:
        before = get_cursor(conn, username) if mode == "backfill" else None
        while True:
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
            else:  # incremental: newest pages until nothing new
                if inserted == 0:
                    break
                before = oldest
        if mode == "backfill":
            set_cursor(conn, username, None)
        record_coverage(conn, username)
        return {"channel": username, "status": "complete",
                "new_messages": new_total, "failure_reason": None}
    except (NoPreviewError, requests.RequestException) as e:
        try:
            record_coverage(conn, username)
        except Exception:
            pass  # never let a coverage error mask the real failure reason
        return {"channel": username, "status": "failed",
                "new_messages": new_total, "failure_reason": str(e)}


def run(conn, fetch, mode, max_pages=None, only_channel=None):
    channels = [r[0] for r in conn.execute(
        "SELECT username FROM channels WHERE status IN (?,?) ORDER BY username",
        APPROVED)]
    if only_channel:
        channels = [c for c in channels if c == only_channel]
    results = [collect_channel(conn, c, fetch, mode, max_pages)
               for c in channels]
    update_candidates(conn)
    ok = all(r["status"] == "complete" or r["failure_reason"] for r in results)
    return {"mode": mode, "channels": results, "ok": ok}


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True)
    ap.add_argument("--mode", choices=["backfill", "incremental"], required=True)
    ap.add_argument("--channel")
    ap.add_argument("--max-pages", type=int)
    args = ap.parse_args()
    conn = open_db(args.db)
    session = requests.Session()
    report = run(conn, lambda u, b: fetch_page(u, b, session), args.mode,
                 max_pages=args.max_pages, only_channel=args.channel)
    print(json.dumps(report, indent=1))
    raise SystemExit(0 if report["ok"] else 1)
