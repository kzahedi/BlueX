#!/usr/bin/env python3
"""Aggregate BlueX incivility scores into weekly per-outlet summaries.

WHY THIS EXISTS
----------------
`score_corpus.py` produced a validated incivility score (`toxicity` head,
AUC 0.946 against moderator `rude` labels — see `tools/benchmark/`) for
every reply in the corpus at the time it ran. That is a pile of per-post
floats; it is not yet a research output. This script turns it into the
project's first one: incivility over time, per tracked outlet, at weekly
granularity — the shape every downstream question ("did outlet X get
ruder after event Y") actually needs.

THE TRAP THIS MUST NEVER FALL INTO — READ BEFORE CHANGING ANYTHING
--------------------------------------------------------------------
This is an incivility measure, NOT a hate measure. The same `toxicity`
head that separates moderator-labelled `rude` posts from random replies at
AUC 0.946 rates `rude` posts as MORE toxic than moderator-labelled `hate`
posts 80% of the time (hate-vs-rude AUC **0.198** — worse than a coin
flip, and in the wrong direction; see
`docs/superpowers/notes/2026-08-11-nltagger-sentiment-does-not-detect-hate.md`
and its sibling finding, and `TODO.md`'s dissociation table). A weekly
"incivility went up" chart from this script must never be read, captioned,
or repurposed as "hate went up" — those are different axes on this corpus,
and conflating them is exactly the mistake this project's own benchmark
work exists to prevent.

`share_over_050` uses 0.50 as an illustrative threshold on the model's raw
sigmoid output. It has NOT been calibrated against any ground truth (no
precision/recall curve, no chosen operating point) — it is a convenience
cut, not a validated boundary, and every output says so.

THE OTHER TRAP: SCORING RUNS ARE RESUMABLE AND SPLIT ACROSS FILES
--------------------------------------------------------------------
`score_corpus.py --resume` skips URIs already recorded in a progress file
and only emits records for what it newly scored in *that* run. A single
scoring pass that was interrupted and resumed therefore has its output
split across multiple `incivility-scores-*.jsonl` files, each covering a
disjoint slice of URIs — the newest file alone is NOT the complete scored
set. This script reads every `incivility-scores-*.jsonl` file present,
oldest first, and merges them (last-one-wins on duplicate uri+head lines,
so a rescoring run's fresher number wins over a stale one from an earlier
file). Only the newest `.summary.json` is checked for `"run_status"`,
because it is the one written at the end of the full resumed sequence and
therefore the one that can honestly claim the corpus pass is complete.

WHAT THIS OUTPUT IS NOT
-------------------------
  * NOT a hate signal. See above.
  * NOT a claim that every week has equal coverage. The corpus keeps
    growing (nightly scrape) after any given scoring run finishes; recent
    weeks will have replies that were never scored at all. Those unscored
    replies are counted in `n_replies_total` but are NEVER treated as a
    score of 0 and NEVER folded into `mean_toxicity` / `p50` / `p90` /
    `share_over_050` — those four columns are computed over scored
    replies only. `coverage` (`n_scored / n_replies_total`) is the
    column that makes a low-coverage week visible; a reader who ignores
    it will silently overweight old, fully-scored weeks as if they were
    representative of new ones, or vice versa.
  * NOT calibrated against a clean or complete sample (see score_corpus.py
    and README.md at the scores directory for the precision-vs-recall
    caveat inherited unchanged here).

SAFETY
------
The BlueX store is opened strictly read-only via `file:...?mode=ro`. Never
`?immutable=1` (WAL-blind, has returned zero rows on a populated store).
This script never writes to the store.

Output lands on the external volume `/Volumes/Eregion/bluex-incivility`,
alongside the scores it reads.
"""
import argparse
import csv
import datetime as dt
import glob
import json
import os
import sqlite3
import sys

SCORE_HEAD = "toxicity"
SHARE_THRESHOLD = 0.50

# Core Data stores timestamps as seconds since 2001-01-01T00:00:00Z.
CORE_DATA_EPOCH_OFFSET = 978307200

DEFAULT_STORE_DIR = os.environ.get("BLUEX_STORE_DIR", "/Volumes/Eregion/bluex-data")
DEFAULT_STORE_FILENAME = "default.store"
DEFAULT_SCORES_DIR = "/Volumes/Eregion/bluex-incivility"
DEFAULT_OUT_DIR = "/Volumes/Eregion/bluex-incivility"

REPLIES_QUERY = """
SELECT r.ZURI, r.ZCREATEDAT, ta.ZHANDLE
  FROM ZPOST r
  JOIN ZPOST root ON root.ZURI = r.ZROOTURI AND root.ZISROOTPOST = 1
  JOIN ZTRACKEDACCOUNT ta ON ta.Z_PK = root.ZACCOUNT
 WHERE r.ZISROOTPOST = 0 AND r.ZURI IS NOT NULL AND r.ZCREATEDAT IS NOT NULL
"""

CSV_FIELDS = [
    "outlet", "iso_week", "n_scored", "n_replies_total", "coverage",
    "mean_toxicity", "p50", "p90", "share_over_050",
]


class PartialRunError(Exception):
    """Raised when the newest scores run did not complete."""


def ro_uri(path):
    """Read-only SQLite URI. Deliberately NOT immutable=1 (see module docstring)."""
    return "file:" + os.path.abspath(path) + "?mode=ro"


def now_stamp():
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H%M%SZ")


def now_iso():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def coredata_to_unix(value):
    """Core Data timestamp (seconds since 2001-01-01Z) -> Unix seconds."""
    return float(value) + CORE_DATA_EPOCH_OFFSET


def iso_week(unix_ts):
    """Unix seconds -> ISO week string 'YYYY-Www' using the ISO year, not the
    calendar year (e.g. 2024-12-30 is a Monday in ISO week 2025-W01)."""
    moment = dt.datetime.fromtimestamp(unix_ts, dt.timezone.utc)
    iso_year, iso_week_num, _ = moment.isocalendar()
    return "%04d-W%02d" % (iso_year, iso_week_num)


# --------------------------------------------------------------------------
# Score file discovery + loading
# --------------------------------------------------------------------------

def find_score_files(scores_dir):
    """All incivility-scores-*.jsonl files, oldest first (ISO timestamps in
    the filename sort correctly as plain strings)."""
    return sorted(glob.glob(os.path.join(scores_dir, "incivility-scores-*.jsonl")))


def find_newest_summary(scores_dir):
    """Path to the newest incivility-scores-*.summary.json, or None."""
    paths = sorted(glob.glob(os.path.join(scores_dir, "incivility-scores-*.summary.json")))
    return paths[-1] if paths else None


def load_summary(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def check_run_complete(summary):
    """Raise PartialRunError unless summary declares run_status == 'complete'."""
    status = summary.get("run_status")
    if status != "complete":
        raise PartialRunError(
            "newest scoring run has run_status=%r, not 'complete' — refusing "
            "to aggregate a partial run (prevalence numbers from an "
            "incomplete pass are not trustworthy)" % (status,)
        )


def load_scores(score_paths, head=SCORE_HEAD):
    """Stream every jsonl file (given oldest-first) and return uri -> score
    for the given head only. `identity_attack` lines are read and discarded
    (this script measures incivility, never hate — see module docstring).

    Duplicate uri+head lines (either within one file, or the same uri
    scored again in a later file) resolve last-one-wins: the last line
    encountered, in file order then line order, is kept. This is a
    deliberate, documented choice — not the only defensible one — made
    because a later record is either a genuine rescoring (newer weights or
    a bugfix) or a harmless resume-overlap duplicate, and in both cases the
    later value is at least as trustworthy as the earlier one.
    """
    scores = {}
    for path in score_paths:
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                record = json.loads(line)
                if record.get("head") != head:
                    continue
                scores[record["uri"]] = float(record["score"])
    return scores


def scores_model_identity(score_paths, head=SCORE_HEAD):
    """Return (model_id, model_revision) from the first matching-head record
    found, or (None, None) if there are none. Used only to echo reproducibility
    metadata into the outputs."""
    for path in score_paths:
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                record = json.loads(line)
                if record.get("head") == head:
                    return record.get("model_id"), record.get("model_revision")
    return None, None


# --------------------------------------------------------------------------
# Store access
# --------------------------------------------------------------------------

def fetch_replies(store_path):
    """Return [(uri, unix_created_at, outlet_handle), ...] for every reply
    whose root post is attributable to a tracked outlet. Replies whose root
    row is missing, isn't marked as a root, or has no matching tracked
    account are silently excluded from outlet attribution (there is no
    outlet to bucket them under) but that exclusion is the join itself
    doing its job, not a hidden score-suppression step.
    """
    conn = sqlite3.connect(ro_uri(store_path), uri=True)
    try:
        rows = conn.execute(REPLIES_QUERY).fetchall()
    finally:
        conn.close()
    return [(uri, coredata_to_unix(created), handle) for uri, created, handle in rows]


# --------------------------------------------------------------------------
# Aggregation
# --------------------------------------------------------------------------

def percentile(values, p):
    """Linear-interpolation percentile (numpy's default 'linear' method) over
    a possibly-unsorted list. `values` must be non-empty."""
    ordered = sorted(values)
    n = len(ordered)
    if n == 1:
        return ordered[0]
    idx = p * (n - 1)
    lo = int(idx)
    hi = min(lo + 1, n - 1)
    frac = idx - lo
    return ordered[lo] + (ordered[hi] - ordered[lo]) * frac


def aggregate(replies, scores, share_threshold=SHARE_THRESHOLD):
    """replies: [(uri, unix_ts, outlet), ...]; scores: uri -> toxicity score.

    Returns {(outlet, iso_week): stats_dict}, one entry per bucket that has
    at least one reply (scored or not). Unscored replies increment
    n_replies_total but are never added to the scored-value list used for
    mean/p50/p90/share_over_050 — see module docstring.
    """
    buckets = {}
    for uri, unix_ts, outlet in replies:
        week = iso_week(unix_ts)
        key = (outlet, week)
        bucket = buckets.setdefault(key, {"n_replies_total": 0, "scored_values": []})
        bucket["n_replies_total"] += 1
        if uri in scores:
            bucket["scored_values"].append(scores[uri])

    result = {}
    for key, bucket in buckets.items():
        values = bucket["scored_values"]
        n_scored = len(values)
        n_total = bucket["n_replies_total"]
        stats = {
            "n_scored": n_scored,
            "n_replies_total": n_total,
            "coverage": (n_scored / n_total) if n_total else None,
        }
        if n_scored:
            stats["mean_toxicity"] = sum(values) / n_scored
            stats["p50"] = percentile(values, 0.50)
            stats["p90"] = percentile(values, 0.90)
            stats["share_over_050"] = sum(1 for v in values if v > share_threshold) / n_scored
        else:
            stats["mean_toxicity"] = None
            stats["p50"] = None
            stats["p90"] = None
            stats["share_over_050"] = None
        result[key] = stats
    return result


def rows_from_aggregate(agg):
    """Sorted [(outlet, iso_week, stats), ...] rows, outlet then week."""
    return [(outlet, week, stats) for (outlet, week), stats in sorted(agg.items())]


# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------

def fmt(value, digits=4):
    if value is None:
        return ""
    if isinstance(value, float):
        return "%.*f" % (digits, value)
    return str(value)


def write_csv(rows, path):
    with open(path, "w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(CSV_FIELDS)
        for outlet, week, stats in rows:
            writer.writerow([
                outlet, week, stats["n_scored"], stats["n_replies_total"],
                fmt(stats["coverage"]), fmt(stats["mean_toxicity"]),
                fmt(stats["p50"]), fmt(stats["p90"]), fmt(stats["share_over_050"]),
            ])


HONESTY_HEADER = """\
> **This measures incivility, not hate.** The `toxicity` head used here
> separates moderator-labelled `rude` posts from random replies at AUC
> 0.946 — a strong, validated incivility detector. The SAME head rates
> `rude` posts as MORE toxic than moderator-labelled `hate` posts 80% of
> the time (hate-vs-rude AUC **0.198**, worse than chance and in the wrong
> direction). Incivility and hate are anti-correlated on this corpus. See
> `docs/superpowers/notes/2026-08-11-nltagger-sentiment-does-not-detect-hate.md`
> (sibling finding) and `TODO.md`'s dissociation table. A rise in this
> table's numbers must never be reported or captioned as "more hate".
>
> **`share_over_050` is an arbitrary illustrative threshold** on the raw
> sigmoid output, pending calibration against a validated operating point.
> It is a convenience cut, not a decision boundary.
>
> **Coverage is not uniform.** The corpus keeps growing after any scoring
> run finishes. Weeks with `coverage < 1.0` had replies that were never
> scored; those replies are counted in `n_replies_total` but are NEVER
> treated as score 0 and are excluded from `mean_toxicity` / `p50` / `p90`
> / `share_over_050`. Recent weeks will show low coverage — that is
> expected, not a bug, and must not be read as "recent weeks are less
> uncivil."
"""


def write_markdown(rows, meta, path):
    lines = []
    lines.append("# BlueX weekly incivility aggregation")
    lines.append("")
    lines.append(HONESTY_HEADER)
    lines.append("")
    lines.append("## Reproducibility")
    lines.append("")
    lines.append("- Generated: `%s`" % meta["generated_at"])
    lines.append("- Model: `%s` (revision `%s`)" % (meta["model_id"], meta["model_revision"]))
    lines.append("- Score head: `%s`" % meta["head"])
    lines.append("- Score files read (oldest first): %s"
                  % ", ".join(os.path.basename(p) for p in meta["score_files"]))
    lines.append("- Newest scores summary: `%s` (`run_status: %s`)"
                  % (os.path.basename(meta["summary_path"]), meta["run_status"]))
    lines.append("- Store: `%s`" % meta["store_path"])
    lines.append("- Duplicate uri+head lines across/within files: last-one-wins.")
    lines.append("")
    lines.append("## Summary")
    lines.append("")
    n_scored_total = sum(s["n_scored"] for _, _, s in rows)
    n_replies_total = sum(s["n_replies_total"] for _, _, s in rows)
    outlets = sorted({outlet for outlet, _, _ in rows})
    lines.append("- Outlets: %d" % len(outlets))
    lines.append("- (outlet, ISO week) buckets: %d" % len(rows))
    lines.append("- Total replies (store): %d" % n_replies_total)
    lines.append("- Total scored replies: %d" % n_scored_total)
    if n_replies_total:
        lines.append("- Overall coverage: %.4f" % (n_scored_total / n_replies_total))
    lines.append("")
    lines.append("## Per (outlet, ISO week)")
    lines.append("")
    lines.append("| " + " | ".join(CSV_FIELDS) + " |")
    lines.append("|" + "---|" * len(CSV_FIELDS))
    for outlet, week, stats in rows:
        lines.append("| " + " | ".join([
            outlet, week, str(stats["n_scored"]), str(stats["n_replies_total"]),
            fmt(stats["coverage"]), fmt(stats["mean_toxicity"]),
            fmt(stats["p50"]), fmt(stats["p90"]), fmt(stats["share_over_050"]),
        ]) + " |")
    lines.append("")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines))


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def default_store_path(store_dir):
    return os.path.join(store_dir, DEFAULT_STORE_FILENAME)


def run(scores_dir, store_path, out_dir, share_threshold=SHARE_THRESHOLD, stamp=None):
    summary_path = find_newest_summary(scores_dir)
    if summary_path is None:
        raise PartialRunError(
            "no incivility-scores-*.summary.json found in %s" % scores_dir
        )
    summary = load_summary(summary_path)
    check_run_complete(summary)

    score_paths = find_score_files(scores_dir)
    if not score_paths:
        raise PartialRunError("no incivility-scores-*.jsonl found in %s" % scores_dir)

    scores = load_scores(score_paths)
    model_id, model_revision = scores_model_identity(score_paths)
    if model_id is None:
        model_id = summary.get("model_id")
        model_revision = summary.get("model_revision")

    replies = fetch_replies(store_path)
    agg = aggregate(replies, scores, share_threshold=share_threshold)
    rows = rows_from_aggregate(agg)

    stamp = stamp or now_stamp()
    os.makedirs(out_dir, exist_ok=True)
    csv_path = os.path.join(out_dir, "incivility-weekly-%s.csv" % stamp)
    md_path = os.path.join(out_dir, "incivility-weekly-%s.md" % stamp)

    meta = {
        "generated_at": now_iso(),
        "model_id": model_id,
        "model_revision": model_revision,
        "head": SCORE_HEAD,
        "score_files": score_paths,
        "summary_path": summary_path,
        "run_status": summary.get("run_status"),
        "store_path": store_path,
    }
    write_csv(rows, csv_path)
    write_markdown(rows, meta, md_path)
    return csv_path, md_path, rows, meta


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Aggregate BlueX incivility scores into weekly per-outlet summaries."
    )
    parser.add_argument("--scores-dir", default=DEFAULT_SCORES_DIR,
                         help="Directory holding incivility-scores-*.jsonl / .summary.json")
    parser.add_argument("--store", default=None,
                         help="Path to the BlueX SwiftData store (default: %s)"
                         % default_store_path(DEFAULT_STORE_DIR))
    parser.add_argument("--out", default=DEFAULT_OUT_DIR, help="Output directory")
    parser.add_argument("--share-threshold", type=float, default=SHARE_THRESHOLD)
    args = parser.parse_args(argv)

    store_path = args.store or default_store_path(DEFAULT_STORE_DIR)

    try:
        csv_path, md_path, rows, meta = run(
            args.scores_dir, store_path, args.out, share_threshold=args.share_threshold,
        )
    except PartialRunError as exc:
        print("ERROR: %s" % exc, file=sys.stderr)
        return 1

    print("Wrote %s (%d rows)" % (csv_path, len(rows)))
    print("Wrote %s" % md_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
