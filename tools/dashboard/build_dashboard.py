#!/usr/bin/env python3
"""Local, self-contained BlueX programme status dashboard.

WHY THIS EXISTS
----------------
The programme now spans several independent stores (the Bluesky corpus in
default.store, the Telegram corpus in social/telegram.db, the committee
scores in committee/committee.db, and a handful of job-health log/heartbeat
files) with no single view across them. This script reads all of them
READ-ONLY and renders ONE self-contained HTML file: inline CSS, inline SVG
charts, no external requests of any kind (no CDN, no fonts, no images), so
it renders correctly opened directly via file://.

THIS STAYS LOCAL. It is never uploaded, published, or shared -- the corpus
includes a deliberately-private far-right channel list kept out of GitHub
on purpose, so channel-level detail must not leave this machine. This
script has no upload/share/publish code path, on purpose.

BLINDNESS RULE
---------------
This page shows AGGREGATES ONLY -- counts, rates, correlations, band sizes.
It never renders a per-post score or a per-post label. The user is
actively annotating; a page that let them look up an individual post's
committee score (or its human label) would breach the structural
blindness the labelling design depends on
(docs/superpowers/specs/2026-08-24-stratified-labelling-frame-design.md
S2 -- "the app never sees a score"). test_build_dashboard.py asserts this
directly by scanning the rendered HTML for post URIs / raw per-post score
values.

SAFETY
------
Every store is opened strictly read-only via `file:...?mode=ro` -- never
`?immutable=1` (WAL-blind; has silently returned zero rows on a populated
store elsewhere in this project). This script never writes to any store,
and never touches anything under
`/Volumes/Eregion/bluex-data/social/` beyond a read.

DEGRADATION
-----------
Every section is independent. A missing or unreadable source degrades that
one section to an honest "unavailable: <reason>" panel -- it never renders
as a zero and never crashes the rest of the page.

DETERMINISM
------------
Given the same inputs, `render_html` produces byte-identical output (no
wall-clock time baked into ids or ordering). The one exception is the
"generated at" stamp, which is passed in explicitly by the caller
(`main` uses the real current time; tests pass a fixed value).

TIMESTAMPS
----------
Core Data dates (`ZCREATEDAT` etc. in default.store) are seconds since
2001-01-01 UTC -- converted here via CORE_DATA_EPOCH_OFFSET. telegram.db's
`fetched_at`/`date`/`added_at` columns are UTC ISO-8601 strings. Log
timestamps (continuous.log, watchdog.log, telegram.log) are local time
(the log lines themselves say e.g. "CEST"). Every section that displays a
timestamp says which it is.
"""
import argparse
import datetime as dt
import glob
import html as html_mod
import json
import math
import os
import sqlite3
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_HERE, "..", "labelling"))
sys.path.insert(0, os.path.join(_HERE, "..", "analysis"))

import base_rate  # noqa: E402 -- reused verbatim: wilson_ci, decode_string_array,
                   # normalize_uuid, column_map, table_exists, compute_report

CORE_DATA_EPOCH_OFFSET = 978307200  # seconds between 1970-01-01 and 2001-01-01, UTC

DEFAULT_STORE = "/Volumes/Eregion/bluex-data/default.store"
DEFAULT_TELEGRAM_DB = "/Volumes/Eregion/bluex-data/social/telegram.db"
DEFAULT_COMMITTEE_DB = "/Volumes/Eregion/bluex-data/committee/committee.db"
DEFAULT_COMMITTEE_DIR = "/Volumes/Eregion/bluex-data/committee"
DEFAULT_EMBEDDINGS_META = "/Volumes/Eregion/bluex-data/embeddings/doc2vec-final.meta.json"
DEFAULT_PREREG_DIR = os.path.join(_HERE, "..", "..", "docs", "prereg")
DEFAULT_LOG_DIR = os.path.expanduser("~/Library/Logs/BlueX")
DEFAULT_TELEGRAM_HEARTBEAT = "/Volumes/Eregion/bluex-data/social/telegram-heartbeat.json"
DEFAULT_LAST_RUN_JSON = os.path.expanduser("~/Library/Logs/BlueX/last-run.json")
DEFAULT_OUT = "/Volumes/Eregion/bluex-data/dashboard/bluex-status.html"

# Known-accepted conditions, documented in TODO.md 2026-08-21 and the
# telegram collector's own lock/VPN guards. A pass matching one of these is
# rendered as an accepted condition, not an alarm.
ACCEPTED_FAILURE_MARKERS = ("5xx", "http 5xx")
ACCEPTED_HEARTBEAT_SKIP_VALUES = ("locked", "no-vpn")
ACCEPTED_LOG_LINE_MARKERS = ("already running", "no-vpn", "locked")


# --------------------------------------------------------------------------
# Small shared utilities
# --------------------------------------------------------------------------

def ro_uri(path):
    """Read-only SQLite URI. Deliberately NOT immutable=1 (see module docstring)."""
    return "file:" + os.path.abspath(path) + "?mode=ro"


def now_iso():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def coredata_to_unix(value):
    return float(value) + CORE_DATA_EPOCH_OFFSET


def unavailable(reason):
    return {"status": "unavailable", "reason": str(reason)}


def esc(text):
    return html_mod.escape("" if text is None else str(text), quote=True)


def open_ro(path):
    """Open a SQLite file strictly read-only. Raises FileNotFoundError with
    a clean message if the path doesn't exist -- sqlite3 itself would
    otherwise raise an opaque "unable to open database file" for that
    case, which is harder to turn into an honest reason string."""
    if not os.path.exists(path):
        raise FileNotFoundError("no such file: %s" % path)
    return sqlite3.connect(ro_uri(path), uri=True)


# --------------------------------------------------------------------------
# Acquisition -- Bluesky
# --------------------------------------------------------------------------

def read_bluesky_acquisition(store_path):
    """Total posts, roots, per-outlet counts, weekly post counts (last 16
    weeks). Degrades to an unavailable panel on any missing/unreadable
    store or missing expected tables/columns."""
    try:
        conn = open_ro(store_path)
    except (FileNotFoundError, sqlite3.Error) as exc:
        return unavailable(exc)
    try:
        if not base_rate.table_exists(conn, "ZPOST"):
            return unavailable("ZPOST table not found in %s" % store_path)

        total_posts = conn.execute("SELECT COUNT(*) FROM ZPOST").fetchone()[0]
        root_posts = conn.execute(
            "SELECT COUNT(*) FROM ZPOST WHERE ZISROOTPOST = 1"
        ).fetchone()[0]
        reply_posts = total_posts - root_posts

        has_accounts = base_rate.table_exists(conn, "ZTRACKEDACCOUNT")
        per_outlet = []
        if has_accounts:
            own_rows = conn.execute(
                "SELECT ta.ZHANDLE, COUNT(*) FROM ZPOST p "
                "JOIN ZTRACKEDACCOUNT ta ON ta.Z_PK = p.ZACCOUNT "
                "WHERE p.ZISROOTPOST = 1 GROUP BY ta.ZHANDLE"
            ).fetchall()
            own_by_handle = {h: n for h, n in own_rows}

            reply_rows = conn.execute(
                "SELECT ta.ZHANDLE, COUNT(*) FROM ZPOST r "
                "JOIN ZPOST root ON root.ZURI = r.ZROOTURI AND root.ZISROOTPOST = 1 "
                "JOIN ZTRACKEDACCOUNT ta ON ta.Z_PK = root.ZACCOUNT "
                "WHERE r.ZISROOTPOST = 0 GROUP BY ta.ZHANDLE"
            ).fetchall()
            replies_by_handle = {h: n for h, n in reply_rows}

            handles = sorted(set(own_by_handle) | set(replies_by_handle))
            for handle in handles:
                per_outlet.append({
                    "handle": handle,
                    "own_posts": own_by_handle.get(handle, 0),
                    "replies_received": replies_by_handle.get(handle, 0),
                })

        week_rows = conn.execute(
            "SELECT strftime('%Y-%W', datetime(ZCREATEDAT + ?, 'unixepoch')) AS wk, "
            "COUNT(*) FROM ZPOST WHERE ZCREATEDAT IS NOT NULL GROUP BY wk ORDER BY wk",
            (CORE_DATA_EPOCH_OFFSET,),
        ).fetchall()
        weekly = [{"week": wk, "count": n} for wk, n in week_rows if wk is not None]
        weekly_last16 = weekly[-16:]

        return {
            "status": "ok",
            "total_posts": total_posts,
            "root_posts": root_posts,
            "reply_posts": reply_posts,
            "per_outlet": per_outlet,
            "weekly_last16": weekly_last16,
            "source": store_path,
        }
    finally:
        conn.close()


# --------------------------------------------------------------------------
# Acquisition -- Telegram
# --------------------------------------------------------------------------

def read_telegram_acquisition(db_path):
    try:
        conn = open_ro(db_path)
    except (FileNotFoundError, sqlite3.Error) as exc:
        return unavailable(exc)
    try:
        for table in ("channels", "messages", "candidates"):
            if not base_rate.table_exists(conn, table):
                return unavailable("%s table not found in %s" % (table, db_path))

        n_messages = conn.execute("SELECT COUNT(*) FROM messages").fetchone()[0]
        n_channels = conn.execute("SELECT COUNT(*) FROM channels").fetchone()[0]
        n_approved = conn.execute(
            "SELECT COUNT(*) FROM channels WHERE status = 'approved'"
        ).fetchone()[0]
        n_backfill_complete = conn.execute(
            "SELECT COUNT(*) FROM channels WHERE backfill_complete_at IS NOT NULL"
        ).fetchone()[0]
        n_empty = conn.execute(
            "SELECT COUNT(*) FROM channels c WHERE NOT EXISTS "
            "(SELECT 1 FROM messages m WHERE m.channel = c.username)"
        ).fetchone()[0]

        top_channels_rows = conn.execute(
            "SELECT channel, COUNT(*) AS n FROM messages GROUP BY channel "
            "ORDER BY n DESC LIMIT 10"
        ).fetchall()
        top_channels = [{"channel": c, "count": n} for c, n in top_channels_rows]

        n_forward_edges = conn.execute(
            "SELECT COUNT(*) FROM messages WHERE fwd_from_channel IS NOT NULL"
        ).fetchone()[0]
        n_forward_sources = conn.execute(
            "SELECT COUNT(DISTINCT fwd_from_channel) FROM messages "
            "WHERE fwd_from_channel IS NOT NULL"
        ).fetchone()[0]

        n_pending_over_threshold = conn.execute(
            "SELECT COUNT(*) FROM candidates WHERE status = 'pending' "
            "AND forward_evidence_count >= 3"
        ).fetchone()[0]
        n_pending_total = conn.execute(
            "SELECT COUNT(*) FROM candidates WHERE status = 'pending'"
        ).fetchone()[0]

        n_coverage_days = None
        if base_rate.table_exists(conn, "coverage"):
            n_coverage_days = conn.execute("SELECT COUNT(*) FROM coverage").fetchone()[0]

        return {
            "status": "ok",
            "n_messages": n_messages,
            "n_channels": n_channels,
            "n_approved": n_approved,
            "n_backfill_complete": n_backfill_complete,
            "n_empty_channels": n_empty,
            "top_channels": top_channels,
            "n_forward_edges": n_forward_edges,
            "n_forward_sources": n_forward_sources,
            "n_pending_candidates": n_pending_total,
            "n_pending_over_threshold": n_pending_over_threshold,
            "n_coverage_days": n_coverage_days,
            "source": db_path,
        }
    finally:
        conn.close()


# --------------------------------------------------------------------------
# Collection health -- job logs / heartbeats
# --------------------------------------------------------------------------

def _read_lines(path):
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        return [line.rstrip("\n") for line in handle if line.strip()]


def classify_continuous_line(line):
    """A single continuous.log line -> ("ok"|"failed_accepted"|"failed", line)."""
    lower = line.lower()
    if "pass ok" in lower:
        return "ok"
    if "pass failed" in lower:
        if any(marker in lower for marker in ACCEPTED_FAILURE_MARKERS):
            return "failed_accepted"
        return "failed"
    return "other"


def read_continuous_log(path):
    if not os.path.exists(path):
        return unavailable("no such file: %s" % path)
    try:
        lines = _read_lines(path)
    except OSError as exc:
        return unavailable(exc)
    counts = {"ok": 0, "failed_accepted": 0, "failed": 0, "other": 0}
    for line in lines:
        counts[classify_continuous_line(line)] += 1
    return {
        "status": "ok",
        "n_pass_ok": counts["ok"],
        "n_pass_failed_accepted": counts["failed_accepted"],
        "n_pass_failed": counts["failed"],
        "last_line": lines[-1] if lines else None,
        "source": path,
    }


def read_last_line_log(path, label):
    if not os.path.exists(path):
        return unavailable("no such file: %s" % path)
    try:
        lines = _read_lines(path)
    except OSError as exc:
        return unavailable(exc)
    return {
        "status": "ok",
        "last_line": lines[-1] if lines else None,
        "source": path,
        "label": label,
    }


def read_telegram_log(path):
    if not os.path.exists(path):
        return unavailable("no such file: %s" % path)
    try:
        lines = _read_lines(path)
    except OSError as exc:
        return unavailable(exc)
    last_line = lines[-1] if lines else None
    accepted = False
    if last_line is not None:
        lower = last_line.lower()
        accepted = any(marker in lower for marker in ACCEPTED_LOG_LINE_MARKERS)
    return {
        "status": "ok",
        "last_line": last_line,
        "accepted_condition": accepted,
        "source": path,
    }


def read_json_file(path):
    if not os.path.exists(path):
        return unavailable("no such file: %s" % path)
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError) as exc:
        return unavailable(exc)
    return {"status": "ok", "data": data, "source": path}


def read_telegram_heartbeat(path):
    result = read_json_file(path)
    if result["status"] != "ok":
        return result
    data = result["data"]
    skipped = data.get("skipped") if isinstance(data, dict) else None
    accepted_skip = skipped in ACCEPTED_HEARTBEAT_SKIP_VALUES
    result["accepted_skip"] = accepted_skip
    result["skipped"] = skipped
    return result


def read_collection_health(log_dir, telegram_heartbeat_path, last_run_json_path):
    return {
        "continuous_log": read_continuous_log(os.path.join(log_dir, "continuous.log")),
        "watchdog_log": read_last_line_log(os.path.join(log_dir, "watchdog.log"), "watchdog"),
        "telegram_log": read_telegram_log(os.path.join(log_dir, "telegram.log")),
        "telegram_heartbeat": read_telegram_heartbeat(telegram_heartbeat_path),
        "continuous_last_run": read_json_file(last_run_json_path),
    }


# --------------------------------------------------------------------------
# Labelling
# --------------------------------------------------------------------------

def read_labelling(store_path):
    if not os.path.exists(store_path):
        return unavailable("no such file: %s" % store_path)

    try:
        base_rate_report = base_rate.compute_report(store_path)
    except base_rate.SchemaNotReady as exc:
        base_rate_report = {"run_status": "schema_not_ready", "message": str(exc)}
    except sqlite3.Error as exc:
        return unavailable(exc)

    try:
        conn = open_ro(store_path)
    except (FileNotFoundError, sqlite3.Error) as exc:
        return unavailable(exc)
    try:
        by_class = {}
        n_skip_rows = 0
        if base_rate.table_exists(conn, "ZANNOTATION"):
            cols = base_rate.column_map(conn, "ZANNOTATION")
            if "ZSPEECHCLASS" in cols and "ZSTAGE" in cols:
                rows = conn.execute(
                    "SELECT %s, COUNT(*) FROM ZANNOTATION WHERE %s = 'human' "
                    "GROUP BY %s" % (cols["ZSPEECHCLASS"], cols["ZSTAGE"], cols["ZSPEECHCLASS"])
                ).fetchall()
                by_class = {(c if c is not None else "unlabelled"): n for c, n in rows}
        total_human = sum(by_class.values())

        batches = []
        batches_available = base_rate.table_exists(conn, "ZLABELBATCH")
        if batches_available:
            bcols = base_rate.column_map(conn, "ZLABELBATCH")
            select = []
            for want in ("ZID", "ZPASSNUMBER", "ZFRAMEJSON", "ZDRAWNURIS",
                         "ZLABELLEDURIS", "ZSKIPPEDURIS", "ZCREATEDAT", "ZCOMPLETEDAT"):
                select.append(bcols.get(want))
            if all(select[:2]):  # need at least ZID, ZPASSNUMBER to be meaningful
                rows = conn.execute(
                    "SELECT %s FROM ZLABELBATCH" %
                    ", ".join(c if c else "NULL" for c in select)
                ).fetchall()
                for row in rows:
                    zid, pass_number, frame_json, drawn, labelled, skipped, created, completed = row
                    kind = None
                    if frame_json:
                        try:
                            parsed = json.loads(frame_json)
                            kind = parsed.get("kind") if isinstance(parsed, dict) else None
                        except (ValueError, TypeError):
                            kind = None
                    drawn_list = base_rate.decode_string_array(drawn)
                    labelled_list = base_rate.decode_string_array(labelled)
                    skipped_list = base_rate.decode_string_array(skipped)
                    n_drawn = len(drawn_list) if drawn_list is not None else None
                    n_labelled = len(labelled_list) if labelled_list is not None else None
                    n_skipped = len(skipped_list) if skipped_list is not None else None
                    n_remaining = None
                    if n_drawn is not None and n_labelled is not None and n_skipped is not None:
                        n_remaining = n_drawn - n_labelled - n_skipped
                    batches.append({
                        "id": base_rate.normalize_uuid(zid),
                        "pass_number": pass_number,
                        "kind": kind,
                        "n_drawn": n_drawn,
                        "n_labelled": n_labelled,
                        "n_skipped": n_skipped,
                        "n_remaining": n_remaining,
                    })
                    n_skip_rows += n_skipped or 0
    finally:
        conn.close()

    return {
        "status": "ok",
        "human_labels_by_class": by_class,
        "total_human_labels": total_human,
        "batches": batches,
        "base_rate": base_rate_report,
        "source": store_path,
    }


# --------------------------------------------------------------------------
# Committee
# --------------------------------------------------------------------------

def _spearman(conn, col_a, col_b):
    rows = conn.execute(
        "SELECT %s, %s FROM scores WHERE %s IS NOT NULL AND %s IS NOT NULL"
        % (col_a, col_b, col_a, col_b)
    ).fetchall()
    n = len(rows)
    if n < 2:
        return None, n
    try:
        from scipy.stats import spearmanr
    except ImportError:
        return None, n
    xs = [r[0] for r in rows]
    ys = [r[1] for r in rows]
    rho, _p = spearmanr(xs, ys)
    if rho is None or (isinstance(rho, float) and rho != rho):
        return None, n
    return float(rho), n


def _verdict(rho):
    if rho is None:
        return "n/a"
    a = abs(rho)
    if a > 0.9:
        return "redundant"
    if a > 0.6:
        return "correlated"
    return "decorrelated"


def read_committee(db_path):
    try:
        conn = open_ro(db_path)
    except (FileNotFoundError, sqlite3.Error) as exc:
        return unavailable(exc)
    try:
        if not base_rate.table_exists(conn, "scores"):
            return unavailable("scores table not found in %s" % db_path)

        total_rows = conn.execute("SELECT COUNT(*) FROM scores").fetchone()[0]

        n_members_rows = conn.execute(
            "SELECT n_members, COUNT(*) FROM scores GROUP BY n_members ORDER BY n_members"
        ).fetchall()
        n_members_split = {int(n) if n is not None else -1: c for n, c in n_members_rows}

        availability = {}
        for member, col in (("incivility_toxicity", "tox_pct"),
                             ("tfidf_lr", "tfidf_pct"),
                             ("doc2vec_lr", "d2v_pct")):
            n_present = conn.execute(
                "SELECT COUNT(*) FROM scores WHERE %s IS NOT NULL" % col
            ).fetchone()[0]
            availability[member] = {"n_present": n_present, "n_total": total_rows}

        pairs = [("tox_pct", "tfidf_pct", "incivility_toxicity", "tfidf_lr"),
                 ("tox_pct", "d2v_pct", "incivility_toxicity", "doc2vec_lr"),
                 ("tfidf_pct", "d2v_pct", "tfidf_lr", "doc2vec_lr")]
        spearman = []
        for col_a, col_b, name_a, name_b in pairs:
            rho, n = _spearman(conn, col_a, col_b)
            spearman.append({
                "a": name_a, "b": name_b, "rho": rho, "n": n,
                "verdict": _verdict(rho),
            })

        n_with_mean = conn.execute(
            "SELECT COUNT(*) FROM scores WHERE mean_pct IS NOT NULL"
        ).fetchone()[0]
        band_sizes = {}
        skew = {}
        n_tox_missing_total = conn.execute(
            "SELECT COUNT(*) FROM scores WHERE tox IS NULL"
        ).fetchone()[0]
        overall_missing_share = (
            n_tox_missing_total / total_rows if total_rows else None
        )
        for label, fraction in (("top_1_pct", 0.01), ("top_0.1_pct", 0.001)):
            k = max(1, int(round(n_with_mean * fraction))) if n_with_mean else 0
            band_sizes[label] = k
            if k:
                band_rows = conn.execute(
                    "SELECT tox FROM scores WHERE mean_pct IS NOT NULL "
                    "ORDER BY mean_pct DESC LIMIT ?", (k,)
                ).fetchall()
                band_missing = sum(1 for (t,) in band_rows if t is None)
                skew[label] = {
                    "n_band": len(band_rows),
                    "n_tox_missing_in_band": band_missing,
                    "share_missing_in_band": band_missing / len(band_rows) if band_rows else None,
                }
            else:
                skew[label] = {"n_band": 0, "n_tox_missing_in_band": 0, "share_missing_in_band": None}

        return {
            "status": "ok",
            "total_rows": total_rows,
            "n_members_split": n_members_split,
            "availability": availability,
            "spearman": spearman,
            "band_sizes": band_sizes,
            "overall_tox_missing_share": overall_missing_share,
            "missing_member_skew": skew,
            "source": db_path,
        }
    finally:
        conn.close()


def find_newest_frame_file(committee_dir):
    if not os.path.isdir(committee_dir):
        return None
    candidates = sorted(glob.glob(os.path.join(committee_dir, "*frame*.json")))
    return candidates[-1] if candidates else None


def read_frame(committee_dir):
    path = find_newest_frame_file(committee_dir)
    if path is None:
        return {"status": "unavailable", "reason": "no frame file present yet in %s" % committee_dir}
    result = read_json_file(path)
    if result["status"] != "ok":
        return result
    data = result["data"]
    strata = []
    for stratum in data.get("strata", []) if isinstance(data, dict) else []:
        strata.append({
            "id": stratum.get("id"),
            "definition": stratum.get("definition"),
            "population_size": stratum.get("population_size"),
            "sampled_n": len(stratum.get("uris", [])) if isinstance(stratum.get("uris"), list) else None,
        })
    return {
        "status": "ok",
        "population_total": data.get("population_total") if isinstance(data, dict) else None,
        "strata": strata,
        "source": path,
    }


# --------------------------------------------------------------------------
# Model artefacts
# --------------------------------------------------------------------------

def read_doc2vec_meta(path):
    result = read_json_file(path)
    if result["status"] != "ok":
        return result
    data = result["data"]
    return {
        "status": "ok",
        "corpus_row_count": data.get("corpus_row_count"),
        "vocabulary_size": data.get("vocabulary_size"),
        "wall_time_seconds": data.get("wall_time_seconds"),
        "source": path,
    }


def find_sealed_manifests(prereg_dir):
    if not os.path.isdir(prereg_dir):
        return []
    return sorted(glob.glob(os.path.join(prereg_dir, "sealed-stage0-*.json")))


def read_sealed_manifests(prereg_dir):
    paths = find_sealed_manifests(prereg_dir)
    if not paths:
        return {"status": "unavailable", "reason": "no sealed-stage0-*.json manifests found in %s" % prereg_dir}
    manifests = []
    for path in paths:
        result = read_json_file(path)
        if result["status"] != "ok":
            manifests.append({"source": path, "error": result["reason"]})
            continue
        data = result["data"]
        record_count = None
        if isinstance(data, dict):
            record_count = (
                data.get("n_records")
                or data.get("record_count")
                or data.get("row_count")
                or data.get("n_posts")
                or data.get("n_sealed")
            )
        manifests.append({
            "source": path,
            "created_at": data.get("created_at") if isinstance(data, dict) else None,
            "record_count": record_count,
        })
    return {"status": "ok", "manifests": manifests}


# --------------------------------------------------------------------------
# SVG chart (hand-rolled, no JS)
# --------------------------------------------------------------------------

def bar_chart_svg(values, labels, width=640, height=140, bar_color="#3b6fa0"):
    """values: list of numbers; labels: same-length list of short strings
    (only the first/last are drawn to keep it legible). Deterministic
    output for the same inputs -- no randomness, no wall clock."""
    if not values:
        return "<svg width=\"%d\" height=\"%d\"></svg>" % (width, height)
    n = len(values)
    max_v = max(values) or 1
    pad_left, pad_right, pad_top, pad_bottom = 8, 8, 8, 20
    plot_w = width - pad_left - pad_right
    plot_h = height - pad_top - pad_bottom
    bar_w = plot_w / n
    parts = [
        '<svg width="%d" height="%d" viewBox="0 0 %d %d" '
        'xmlns="http://www.w3.org/2000/svg" role="img">' % (width, height, width, height)
    ]
    for i, v in enumerate(values):
        h = (v / max_v) * plot_h if max_v else 0
        x = pad_left + i * bar_w
        y = pad_top + (plot_h - h)
        parts.append(
            '<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" fill="%s">'
            '<title>%s: %s</title></rect>'
            % (x + 0.5, y, max(bar_w - 1.0, 0.5), h, bar_color,
               esc(labels[i] if i < len(labels) else str(i)), esc(v))
        )
    if labels:
        parts.append(
            '<text x="%d" y="%d" font-size="10" fill="currentColor">%s</text>'
            % (pad_left, height - 4, esc(labels[0]))
        )
        parts.append(
            '<text x="%d" y="%d" font-size="10" fill="currentColor" text-anchor="end">%s</text>'
            % (width - pad_right, height - 4, esc(labels[-1]))
        )
    parts.append("</svg>")
    return "".join(parts)


# --------------------------------------------------------------------------
# HTML rendering
# --------------------------------------------------------------------------

CSS = """
body { font-family: -apple-system, Helvetica, Arial, sans-serif; margin: 2rem;
       background: #f7f7f8; color: #1a1a1a; }
h1 { font-size: 1.4rem; }
h2 { font-size: 1.1rem; margin-top: 2rem; border-bottom: 1px solid #ccc; padding-bottom: 0.25rem; }
section { background: #fff; border: 1px solid #ddd; border-radius: 6px; padding: 1rem 1.25rem;
          margin-bottom: 1.25rem; }
table { border-collapse: collapse; width: 100%; margin: 0.5rem 0; font-size: 0.9rem; }
th, td { border: 1px solid #ddd; padding: 0.3rem 0.5rem; text-align: left; }
.unavailable { color: #7a1f1f; background: #fdecea; border: 1px solid #f3c2c2;
               border-radius: 4px; padding: 0.5rem 0.75rem; }
.accepted { color: #1f5e1f; background: #eaf7ea; border: 1px solid #c2e6c2;
            border-radius: 4px; padding: 0.25rem 0.5rem; display: inline-block; }
.caption { color: #666; font-size: 0.8rem; }
.caveats { background: #fff8e6; border: 1px solid #f0deae; }
.stamp { color: #888; font-size: 0.8rem; }
"""


def _fmt(value):
    if value is None:
        return "n/a"
    if isinstance(value, float):
        return "%.4f" % value
    return str(value)


def render_unavailable(title, panel):
    return "<section><h2>%s</h2><p class=\"unavailable\">unavailable: %s</p></section>" % (
        esc(title), esc(panel["reason"])
    )


def render_bluesky_section(data):
    if data["status"] != "ok":
        return render_unavailable("Acquisition -- Bluesky", data)
    rows = "".join(
        "<tr><td>%s</td><td>%d</td><td>%d</td></tr>" % (esc(r["handle"]), r["own_posts"], r["replies_received"])
        for r in data["per_outlet"]
    )
    weekly = data["weekly_last16"]
    chart = bar_chart_svg([w["count"] for w in weekly], [w["week"] for w in weekly])
    return (
        "<section><h2>Acquisition -- Bluesky</h2>"
        "<p title=\"source: %s\">Total posts: <b>%d</b> &nbsp; "
        "Roots: <b>%d</b> &nbsp; Replies: <b>%d</b></p>"
        "<table><tr><th>Outlet</th><th>Own posts</th><th>Replies received</th></tr>%s</table>"
        "<p class=\"caption\">Posts per week, last %d weeks (ISO year-week, local SQLite strftime).</p>%s"
        "</section>"
    ) % (esc(data["source"]), data["total_posts"], data["root_posts"], data["reply_posts"],
         rows, len(weekly), chart)


def render_telegram_section(data):
    if data["status"] != "ok":
        return render_unavailable("Acquisition -- Telegram", data)
    top_rows = "".join(
        "<tr><td>%s</td><td>%d</td></tr>" % (esc(r["channel"]), r["count"])
        for r in data["top_channels"]
    )
    return (
        "<section><h2>Acquisition -- Telegram</h2>"
        "<p title=\"source: %s\">Messages: <b>%d</b> &nbsp; Channels: <b>%d</b> "
        "(approved: %d, backfill complete: %d, genuinely empty: %d)</p>"
        "<p>Forward edges: <b>%d</b> from <b>%d</b> distinct source channels. "
        "Pending candidates: <b>%d</b> (>=3 forward-evidence: <b>%d</b>).</p>"
        "<table><tr><th>Top channel</th><th>Messages</th></tr>%s</table>"
        "<p class=\"caption\">fetched_at / date / added_at in telegram.db are UTC.</p>"
        "</section>"
    ) % (esc(data["source"]), data["n_messages"], data["n_channels"], data["n_approved"],
         data["n_backfill_complete"], data["n_empty_channels"], data["n_forward_edges"],
         data["n_forward_sources"], data["n_pending_candidates"], data["n_pending_over_threshold"],
         top_rows)


def render_health_section(health):
    parts = ["<section><h2>Collection health</h2>",
             "<p class=\"caption\">Log timestamps are local time (as written by the jobs themselves).</p>"]

    cl = health["continuous_log"]
    if cl["status"] != "ok":
        parts.append("<p class=\"unavailable\">continuous.log unavailable: %s</p>" % esc(cl["reason"]))
    else:
        parts.append(
            "<p title=\"source: %s\">continuous.log: pass ok=<b>%d</b>, "
            "pass FAILED (accepted -- documented VPN/5xx)=<b>%d</b>, "
            "pass FAILED (other)=<b>%d</b><br>last line: %s</p>"
            % (esc(cl["source"]), cl["n_pass_ok"], cl["n_pass_failed_accepted"],
               cl["n_pass_failed"], esc(cl["last_line"]))
        )

    wd = health["watchdog_log"]
    if wd["status"] != "ok":
        parts.append("<p class=\"unavailable\">watchdog.log unavailable: %s</p>" % esc(wd["reason"]))
    else:
        parts.append("<p title=\"source: %s\">watchdog last verdict: %s</p>" % (esc(wd["source"]), esc(wd["last_line"])))

    tl = health["telegram_log"]
    if tl["status"] != "ok":
        parts.append("<p class=\"unavailable\">telegram.log unavailable: %s</p>" % esc(tl["reason"]))
    else:
        badge = "<span class=\"accepted\">accepted condition</span>" if tl["accepted_condition"] else ""
        parts.append("<p title=\"source: %s\">telegram.log last line: %s %s</p>" % (esc(tl["source"]), esc(tl["last_line"]), badge))

    hb = health["telegram_heartbeat"]
    if hb["status"] != "ok":
        parts.append("<p class=\"unavailable\">telegram heartbeat unavailable: %s</p>" % esc(hb["reason"]))
    else:
        if hb.get("accepted_skip"):
            parts.append(
                "<p title=\"source: %s\">telegram heartbeat: <span class=\"accepted\">skipped (%s) -- expected, not a fault</span></p>"
                % (esc(hb["source"]), esc(hb["skipped"]))
            )
        else:
            parts.append("<p title=\"source: %s\">telegram heartbeat: %s</p>" % (esc(hb["source"]), esc(json.dumps(hb["data"], sort_keys=True))))

    cr = health["continuous_last_run"]
    if cr["status"] != "ok":
        parts.append("<p class=\"unavailable\">continuous agent last-run unavailable: %s</p>" % esc(cr["reason"]))
    else:
        parts.append("<p title=\"source: %s\">continuous agent last run: %s</p>" % (esc(cr["source"]), esc(json.dumps(cr["data"], sort_keys=True))))

    parts.append("</section>")
    return "".join(parts)


def render_labelling_section(data):
    if data["status"] != "ok":
        return render_unavailable("Labelling", data)
    by_class_rows = "".join(
        "<tr><td>%s</td><td>%d</td></tr>" % (esc(c), n) for c, n in sorted(data["human_labels_by_class"].items())
    )
    batch_rows = "".join(
        "<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>" % (
            esc(b["id"]), esc(b["pass_number"]), esc(b["kind"]),
            esc(b["n_labelled"]), esc(b["n_skipped"]), esc(b["n_remaining"]),
        )
        for b in data["batches"]
    )
    br = data["base_rate"]
    if br.get("run_status") == "ok":
        p_hat = br["included_by_class"].get("hate", 0) / br["n_included"] if br["n_included"] else None
        lo, hi = br["wilson_ci"]
        base_rate_html = (
            "<p>Uniform-random pass-1 base rate: hate = <b>%.2f%%</b> "
            "(n=%d, 95%% Wilson CI [%.2f%%, %.2f%%])</p>"
            "<p class=\"caption\">Only pass-1 labels drawn from a uniformRandom sampling frame "
            "feed this estimate -- see tools/labelling/base_rate.py.</p>"
        ) % (p_hat * 100, br["n_included"], lo * 100, hi * 100)
    else:
        base_rate_html = "<p class=\"unavailable\">base rate: %s</p>" % esc(br.get("message", br.get("run_status")))

    return (
        "<section><h2>Labelling</h2>"
        "<p title=\"source: %s\">Total human labels: <b>%d</b></p>"
        "<table><tr><th>Class</th><th>Count</th></tr>%s</table>"
        "<table><tr><th>Batch</th><th>Pass</th><th>Frame kind</th><th>Labelled</th><th>Skipped</th><th>Remaining</th></tr>%s</table>"
        "%s</section>"
    ) % (esc(data["source"]), data["total_human_labels"], by_class_rows, batch_rows, base_rate_html)


def render_committee_section(data):
    if data["status"] != "ok":
        return render_unavailable("Committee", data)
    n_members_rows = "".join(
        "<tr><td>%s</td><td>%d</td></tr>" % (esc(k), v) for k, v in sorted(data["n_members_split"].items())
    )
    avail_rows = "".join(
        "<tr><td>%s</td><td>%d / %d</td></tr>" % (esc(m), a["n_present"], a["n_total"])
        for m, a in data["availability"].items()
    )
    spearman_rows = "".join(
        "<tr><td>%s vs %s</td><td>%s</td><td>%d</td><td>%s</td></tr>" % (
            esc(s["a"]), esc(s["b"]), _fmt(s["rho"]), s["n"], esc(s["verdict"])
        )
        for s in data["spearman"]
    )
    band_rows = "".join(
        "<tr><td>%s</td><td>%d</td></tr>" % (esc(k), v) for k, v in data["band_sizes"].items()
    )
    skew_rows = "".join(
        "<tr><td>%s</td><td>%s</td></tr>" % (esc(k), _fmt(v["share_missing_in_band"]))
        for k, v in data["missing_member_skew"].items()
    )
    return (
        "<section><h2>Committee</h2>"
        "<p title=\"source: %s\">Rows: <b>%d</b></p>"
        "<table><tr><th>n_members</th><th>rows</th></tr>%s</table>"
        "<table><tr><th>member</th><th>percentile available</th></tr>%s</table>"
        "<table><tr><th>pair</th><th>Spearman rho</th><th>n</th><th>verdict</th></tr>%s</table>"
        "<table><tr><th>band</th><th>size</th></tr>%s</table>"
        "<p>Overall share of posts missing the toxicity member: <b>%s</b>. "
        "Share missing in top mean_pct bands (the measured skew):</p>"
        "<table><tr><th>band</th><th>share missing toxicity member</th></tr>%s</table>"
        "</section>"
    ) % (esc(data["source"]), data["total_rows"], n_members_rows, avail_rows, spearman_rows,
         band_rows, _fmt(data["overall_tox_missing_share"]), skew_rows)


CAVEATS_HTML = """
<section class="caveats"><h2>Caveats</h2>
<ul>
<li>The toxicity committee member measures <b>incivility, not hate</b>:
hate-vs-rude AUC 0.198 (worse than chance, wrong direction), rude-vs-random
AUC 0.946.</li>
<li>The supervised members (tfidf_lr, doc2vec_lr) answer "given hate or
rude, which?" and are weak on random (uncurated) text: AUC 0.61-0.68 in
prior diagnostics.</li>
<li>Moderation labels record what was <b>reported and actioned</b>, not
ground truth.</li>
<li>Committee strata are hypotheses about where hate concentrates; their
enrichment against genuine hate has <b>not yet been measured</b>.</li>
</ul>
</section>
"""


def render_model_artifacts_section(doc2vec, sealed):
    parts = ["<section><h2>Model artefacts</h2>"]
    if doc2vec["status"] != "ok":
        parts.append("<p class=\"unavailable\">doc2vec meta unavailable: %s</p>" % esc(doc2vec["reason"]))
    else:
        wall_time = doc2vec["wall_time_seconds"]
        wall_time_str = "%.1f" % wall_time if isinstance(wall_time, (int, float)) else esc(wall_time)
        parts.append(
            "<p title=\"source: %s\">doc2vec: corpus rows=<b>%s</b>, vocab=<b>%s</b>, wall time=<b>%s s</b></p>"
            % (esc(doc2vec["source"]), esc(doc2vec["corpus_row_count"]),
               esc(doc2vec["vocabulary_size"]), wall_time_str)
        )
    if sealed["status"] != "ok":
        parts.append("<p class=\"unavailable\">sealed Stage 0 manifests unavailable: %s</p>" % esc(sealed["reason"]))
    else:
        rows = "".join(
            "<tr><td>%s</td><td>%s</td><td>%s</td></tr>" % (esc(m["source"]), esc(m.get("created_at")), esc(m.get("record_count")))
            for m in sealed["manifests"]
        )
        parts.append("<table><tr><th>manifest</th><th>created_at (UTC)</th><th>records</th></tr>%s</table>" % rows)
    parts.append("</section>")
    return "".join(parts)


def render_html(sections, generated_at):
    """sections: dict with keys bluesky, telegram, health, labelling,
    committee, doc2vec, sealed. Deterministic for identical inputs and
    generated_at."""
    body = [
        "<h1>BlueX programme status</h1>",
        "<p class=\"stamp\">Generated at %s (UTC). This page is local-only "
        "and shows aggregates only -- never a per-post score or label.</p>" % esc(generated_at),
        render_bluesky_section(sections["bluesky"]),
        render_telegram_section(sections["telegram"]),
        render_health_section(sections["health"]),
        render_labelling_section(sections["labelling"]),
        render_committee_section(sections["committee"]),
        render_model_artifacts_section(sections["doc2vec"], sections["sealed"]),
        CAVEATS_HTML,
    ]
    return (
        "<!doctype html><html><head><meta charset=\"utf-8\">"
        "<title>BlueX status</title><style>%s</style></head><body>%s</body></html>"
    ) % (CSS, "".join(body))


# --------------------------------------------------------------------------
# CLI orchestration
# --------------------------------------------------------------------------

def build_sections(store, telegram_db, committee_db, committee_dir,
                    log_dir, telegram_heartbeat, last_run_json,
                    doc2vec_meta, prereg_dir):
    return {
        "bluesky": read_bluesky_acquisition(store),
        "telegram": read_telegram_acquisition(telegram_db),
        "health": read_collection_health(log_dir, telegram_heartbeat, last_run_json),
        "labelling": read_labelling(store),
        "committee": read_committee(committee_db),
        "frame": read_frame(committee_dir),
        "doc2vec": read_doc2vec_meta(doc2vec_meta),
        "sealed": read_sealed_manifests(prereg_dir),
    }


def summarize(sections):
    lines = []
    bl = sections["bluesky"]
    if bl["status"] == "ok":
        lines.append("Bluesky: %d posts (%d roots)" % (bl["total_posts"], bl["root_posts"]))
    else:
        lines.append("Bluesky: unavailable (%s)" % bl["reason"])
    tg = sections["telegram"]
    if tg["status"] == "ok":
        lines.append("Telegram: %d messages, %d channels" % (tg["n_messages"], tg["n_channels"]))
    else:
        lines.append("Telegram: unavailable (%s)" % tg["reason"])
    lb = sections["labelling"]
    if lb["status"] == "ok":
        lines.append("Labelling: %d human labels" % lb["total_human_labels"])
    else:
        lines.append("Labelling: unavailable (%s)" % lb["reason"])
    cm = sections["committee"]
    if cm["status"] == "ok":
        lines.append("Committee: %d rows" % cm["total_rows"])
    else:
        lines.append("Committee: unavailable (%s)" % cm["reason"])
    return "; ".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--store", default=DEFAULT_STORE)
    parser.add_argument("--telegram-db", default=DEFAULT_TELEGRAM_DB)
    parser.add_argument("--committee-db", default=DEFAULT_COMMITTEE_DB)
    parser.add_argument("--committee-dir", default=DEFAULT_COMMITTEE_DIR)
    parser.add_argument("--log-dir", default=DEFAULT_LOG_DIR)
    parser.add_argument("--telegram-heartbeat", default=DEFAULT_TELEGRAM_HEARTBEAT)
    parser.add_argument("--last-run-json", default=DEFAULT_LAST_RUN_JSON)
    parser.add_argument("--doc2vec-meta", default=DEFAULT_EMBEDDINGS_META)
    parser.add_argument("--prereg-dir", default=DEFAULT_PREREG_DIR)
    parser.add_argument("--out", default=DEFAULT_OUT)
    args = parser.parse_args(argv)

    sections = build_sections(
        args.store, args.telegram_db, args.committee_db, args.committee_dir,
        args.log_dir, args.telegram_heartbeat, args.last_run_json,
        args.doc2vec_meta, args.prereg_dir,
    )
    generated_at = now_iso()
    page = render_html(sections, generated_at)

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as handle:
        handle.write(page)

    print("wrote %s" % args.out)
    print(summarize(sections))
    return 0


if __name__ == "__main__":
    sys.exit(main())
