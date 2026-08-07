#!/usr/bin/env python3
"""Extract the replies that existed in an archived BlueX store but are gone from
the live one — a candidate sample of moderated / removed content.

WHY THIS EXISTS
---------------
Bluesky moderation removes replies over time. A corpus scraped late therefore
systematically under-reports hate speech: the worst material is exactly the
material most likely to have been taken down before we looked. Comparing the
2026-06-04 archive against a fresh scrape showed ~1.08% of replies had vanished
and ~17% of threads had lost at least one reply.

The archive is the only surviving copy of those posts. This script lifts them
out into a durable JSONL dataset before the archive is ever pruned or lost.

THE SCOPING RULE — DO NOT "SIMPLIFY" THIS AWAY
----------------------------------------------
A reply being absent from the live store is only meaningful if the live scrape
actually *looked* at the thread it belongs to. If a root post was never
re-fetched, every one of its replies is trivially "absent" — nothing went
looking for them. Including those would drown the real signal in tens of
thousands of false positives.

So we restrict to archive replies whose ZROOTURI appears in the set of roots the
live store has demonstrably re-scraped, which we derive from the replies the
live store holds:

    SELECT DISTINCT ZROOTURI FROM ZPOST WHERE ZISROOTPOST = 0

Deriving the re-scraped set from *replies* rather than from root rows matters:
a root row can exist in the live store simply because it was enumerated from the
account timeline, with its reply tree never fetched. Holding at least one reply
for that root is positive evidence that the tree was walked.

WHAT THIS DATASET IS NOT
------------------------
"Absent from the live store" is NOT proof of moderation. It can equally mean:

  * the author deleted their own post,
  * the account was deactivated, suspended or renamed,
  * the reply fell outside a retrievable window or pagination limit,
  * the live scrape's tree for that thread was still incomplete when we compared.

This is a CANDIDATE set of removed content. Downstream analysis must treat it as
such and must not report it as a measured moderation rate.

To help narrow it, each record carries `rootTreeComplete`: whether the live
store marks that root's reply tree as fully scraped (ZREPLYTREESTATUS =
'complete'). Records with rootTreeComplete = true are materially stronger
candidates than those whose tree was still 'pending' / 'inProgress'.

SAFETY
------
Both stores are opened strictly read-only via `file:...?mode=ro`. We never use
`?immutable=1`: that is WAL-blind and silently returns stale or zero counts,
which has already produced one false conclusion in this project. A live scrape
may be writing to the live store while this runs; counts will drift slightly
between runs, which is expected and recorded in the summary rather than treated
as an error.

Outputs are named with the extraction date and land on the external volume
(/Volumes/Eregion/bluex-deletions), because the internal disk has filled up and
crashed the scraper before.
"""
import argparse
import datetime as dt
import json
import os
import sqlite3
import sys
import tempfile

# Core Data stores timestamps as seconds since 2001-01-01T00:00:00Z.
CORE_DATA_EPOCH_OFFSET = 978307200

DEFAULT_ARCHIVE = "/Volumes/Eregion/bluex-archive/default.store.2026-08-04-preclean"
DEFAULT_LIVE = "/Volumes/Eregion/bluex-data/default.store"
DEFAULT_OUT_DIR = "/Volumes/Eregion/bluex-deletions"


def ro_uri(path):
    """Read-only SQLite URI. Deliberately NOT immutable=1 (see module docstring)."""
    return "file:" + os.path.abspath(path) + "?mode=ro"


def coredata_to_iso(value):
    """Core Data timestamp (seconds since 2001-01-01Z) -> ISO 8601 UTC string."""
    if value is None:
        return None
    ts = float(value) + CORE_DATA_EPOCH_OFFSET
    moment = dt.datetime.fromtimestamp(ts, dt.timezone.utc)
    return moment.replace(microsecond=0).isoformat().replace("+00:00", "Z")


def open_workspace(archive_path, live_path):
    """In-memory scratch DB with both stores attached read-only.

    Nothing is ever written to either store; the temp tables live only in the
    in-memory main database.
    """
    conn = sqlite3.connect(":memory:", uri=True)
    conn.execute("ATTACH DATABASE ? AS arc", (ro_uri(archive_path),))
    conn.execute("ATTACH DATABASE ? AS live", (ro_uri(live_path),))
    return conn


def build_indexes(conn):
    """Materialise the two lookup sets as indexed temp tables.

    A correlated NOT EXISTS straight across ~750k archive rows x ~840k live rows
    times out. Indexed temp tables turn each check into a B-tree probe.
    """
    # Every URI the live store currently holds, root or reply. Comparing against
    # all posts (not just replies) is the conservative choice: if a post is
    # present in any form, it has not been removed.
    conn.execute("CREATE TABLE live_uri (uri TEXT PRIMARY KEY)")
    conn.execute(
        "INSERT OR IGNORE INTO live_uri (uri) "
        "SELECT ZURI FROM live.ZPOST WHERE ZURI IS NOT NULL"
    )

    # The roots the live scrape demonstrably re-walked, plus whether that walk
    # finished. See "THE SCOPING RULE" in the module docstring.
    conn.execute("CREATE TABLE live_root (root_uri TEXT PRIMARY KEY, complete INTEGER)")
    conn.execute(
        """
        INSERT OR IGNORE INTO live_root (root_uri, complete)
        SELECT r.root_uri,
               CASE WHEN p.ZREPLYTREESTATUS = 'complete' THEN 1 ELSE 0 END
          FROM (
              SELECT DISTINCT ZROOTURI AS root_uri
                FROM live.ZPOST
               WHERE ZISROOTPOST = 0 AND ZROOTURI IS NOT NULL
          ) AS r
          LEFT JOIN live.ZPOST p
                 ON p.ZURI = r.root_uri AND p.ZISROOTPOST = 1
        """
    )
    conn.commit()


def account_handles(conn):
    """Z_PK -> handle for the tracked news accounts (from the archive)."""
    rows = conn.execute("SELECT Z_PK, ZHANDLE FROM arc.ZTRACKEDACCOUNT").fetchall()
    return {pk: handle for pk, handle in rows}


DELETED_QUERY = """
SELECT a.ZURI,
       a.ZTEXT,
       a.ZAUTHORHANDLE,
       a.ZAUTHORDID,
       a.ZCREATEDAT,
       a.ZROOTURI,
       a.ZPARENTURI,
       a.ZDEPTH,
       a.ZLIKECOUNT,
       a.ZREPLYCOUNT,
       a.ZREPOSTCOUNT,
       a.ZQUOTECOUNT,
       lr.complete,
       root.ZACCOUNT
  FROM arc.ZPOST a
  JOIN live_root lr ON lr.root_uri = a.ZROOTURI
  LEFT JOIN arc.ZPOST root ON root.ZURI = a.ZROOTURI AND root.ZISROOTPOST = 1
 WHERE a.ZISROOTPOST = 0
   AND a.ZURI IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM live_uri lu WHERE lu.uri = a.ZURI)
"""


def iter_deleted(conn, provenance):
    """Yield one dict per candidate deleted reply."""
    handles = account_handles(conn)
    for row in conn.execute(DELETED_QUERY):
        (uri, text, handle, did, created, root_uri, parent_uri, depth,
         likes, replies, reposts, quotes, complete, account_pk) = row
        yield {
            "uri": uri,
            "text": text or "",
            "authorHandle": handle,
            "authorDID": did,
            "createdAt": coredata_to_iso(created),
            "rootURI": root_uri,
            "parentURI": parent_uri,
            "depth": depth,
            "likeCount": likes,
            "replyCount": replies,
            "repostCount": reposts,
            "quoteCount": quotes,
            "rootTreeComplete": bool(complete),
            "trackedAccount": handles.get(account_pk),
            "archiveStore": provenance["archiveStore"],
            "liveStore": provenance["liveStore"],
            "extractedAt": provenance["extractedAt"],
        }


def summarize(records, provenance):
    """Aggregate counts, date range, per-account and per-depth breakdowns."""
    by_account = {}
    by_depth = {}
    empty_text = 0
    tree_complete = 0
    earliest = None
    latest = None
    total = 0

    for rec in records:
        total += 1
        account = rec.get("trackedAccount") or "unknown"
        by_account[account] = by_account.get(account, 0) + 1
        depth = str(rec.get("depth"))
        by_depth[depth] = by_depth.get(depth, 0) + 1
        if not (rec.get("text") or "").strip():
            empty_text += 1
        if rec.get("rootTreeComplete"):
            tree_complete += 1
        created = rec.get("createdAt")
        if created:
            if earliest is None or created < earliest:
                earliest = created
            if latest is None or created > latest:
                latest = created

    return {
        "extractedAt": provenance["extractedAt"],
        "archiveStore": provenance["archiveStore"],
        "liveStore": provenance["liveStore"],
        "totalDeletedReplies": total,
        "withNonEmptyText": total - empty_text,
        "withEmptyText": empty_text,
        "rootTreeCompleteInLive": tree_complete,
        "rootTreeIncompleteInLive": total - tree_complete,
        "createdAtRange": {"earliest": earliest, "latest": latest},
        "byTrackedAccount": dict(sorted(by_account.items(), key=lambda kv: -kv[1])),
        "byDepth": dict(sorted(by_depth.items(), key=lambda kv: int(kv[0]))),
        "caveat": (
            "Candidate set only. Absence from the live store is not proof of "
            "moderation: the author may have deleted the post, the account may "
            "have been deactivated or suspended, the reply may have fallen out "
            "of a retrievable window, or the live tree may have been incomplete "
            "at comparison time. Filter on rootTreeComplete for stronger "
            "candidates."
        ),
        "note": (
            "A live scrape may be writing to the live store during extraction, "
            "so counts drift slightly between runs. This is expected, not an "
            "error."
        ),
    }


def write_atomic(path, write_body):
    """Write via a temp file in the same directory, then rename."""
    directory = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=directory, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            write_body(handle)
        os.chmod(tmp, 0o644)  # mkstemp defaults to 0600; these are shared datasets
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def extract(archive_path, live_path, out_dir, stamp=None):
    """Run the full extraction. Returns (jsonl_path, summary_path, summary)."""
    now = dt.datetime.now(dt.timezone.utc)
    stamp = stamp or now.strftime("%Y-%m-%d")
    provenance = {
        "archiveStore": os.path.abspath(archive_path),
        "liveStore": os.path.abspath(live_path),
        "extractedAt": now.replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    }

    os.makedirs(out_dir, exist_ok=True)
    jsonl_path = os.path.join(out_dir, "deleted-replies-%s.jsonl" % stamp)
    summary_path = os.path.join(out_dir, "deleted-replies-%s.summary.json" % stamp)

    conn = open_workspace(archive_path, live_path)
    try:
        build_indexes(conn)
        records = list(iter_deleted(conn, provenance))
    finally:
        conn.close()

    def write_jsonl(handle):
        for rec in records:
            handle.write(json.dumps(rec, ensure_ascii=False) + "\n")

    write_atomic(jsonl_path, write_jsonl)

    summary = summarize(records, provenance)

    def write_summary(handle):
        json.dump(summary, handle, ensure_ascii=False, indent=2)
        handle.write("\n")

    write_atomic(summary_path, write_summary)
    return jsonl_path, summary_path, summary


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=(
            "Extract candidate deleted/moderated replies present in an archived "
            "BlueX store but absent from the live one."
        )
    )
    parser.add_argument("--archive", default=DEFAULT_ARCHIVE,
                        help="path to the archived store (read-only)")
    parser.add_argument("--live", default=DEFAULT_LIVE,
                        help="path to the live store (read-only)")
    parser.add_argument("--out-dir", default=DEFAULT_OUT_DIR,
                        help="directory for the dated JSONL + summary outputs")
    parser.add_argument("--date", default=None,
                        help="override the YYYY-MM-DD stamp in the output filenames")
    args = parser.parse_args(argv)

    for path in (args.archive, args.live):
        if not os.path.exists(path):
            parser.error("store not found: %s" % path)

    jsonl_path, summary_path, summary = extract(
        args.archive, args.live, args.out_dir, stamp=args.date
    )

    print("wrote %s" % jsonl_path)
    print("wrote %s" % summary_path)
    print(json.dumps(
        {k: v for k, v in summary.items() if k not in ("caveat", "note")},
        ensure_ascii=False, indent=2,
    ))
    return 0


if __name__ == "__main__":
    sys.exit(main())
