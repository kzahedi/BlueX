#!/usr/bin/env python3
"""Incivility x structure: the first BlueX findings that need no human labels.

WHY THIS EXISTS
----------------
The corpus has 2.1M+ scored replies (`toxicity` head from `score_corpus.py`,
validated at AUC 0.946 against moderator `rude` labels) and zero human hate
labels. `docs/superpowers/specs/2026-08-22-pre-label-analysis-and-consensus-
labelling.md` sec.2 P1 lists three questions this signal can already answer
without waiting for Stage 0 labelling:

  A1 -- is incivility concentrated in a small number of accounts (author-level
       modelling vs post-level)?
  A2 -- does incivility escalate down a reply chain (parent uncivil -> child
       more likely uncivil), and does that vary by depth/outlet? This is the
       mechanism question from Garland et al. 2020 ("Impact and dynamics of
       hate and counter speech online"), answerable with incivility alone.
  A3 -- does incivility predict Bluesky's own moderation action?

THE TRAP THIS MUST NEVER FALL INTO -- READ BEFORE CHANGING ANYTHING
--------------------------------------------------------------------
This is an incivility measure, NOT a hate measure. The `toxicity` head
separates moderator-labelled `rude` posts from random replies at AUC 0.946,
but rates `rude` posts as MORE toxic than moderator-labelled `hate` posts 80%
of the time (hate-vs-rude AUC **0.198** -- worse than a coin flip, and in the
wrong direction; see
`docs/superpowers/notes/2026-08-11-nltagger-sentiment-does-not-detect-hate.md`
and `TODO.md`'s dissociation table). Concentration of INCIVILITY in A1 does
NOT license any claim about hate. Every output below says so.

`TOXICITY_THRESHOLD` (0.50) is an arbitrary, illustrative cut on the raw
sigmoid score -- a convenience threshold, not a calibrated decision boundary.

THE OTHER TRAP: SCORING RUNS ARE RESUMABLE AND SPLIT ACROSS FILES
--------------------------------------------------------------------
A previous mistake in this project used only the newest
`incivility-scores-*.jsonl` file and silently dropped 60% of the data. This
script reads and merges EVERY `incivility-scores-*.jsonl` file present
(oldest first, last-one-wins on duplicate uri+head), exactly like
`tools/incivility/aggregate_weekly.py` does, and prints/asserts the merged
distinct-URI count.

THE LABEL TRAP: `neg: true` MEANS RETRACTED, NOT ACTIVE
--------------------------------------------------------------------
~77% of account labels in a real sweep are negated retractions; treating a
negated record as an active label caused a 100x error in this project
before (see `/Volumes/Eregion/bluex-labels/README.md`). This script filters
`neg: true` records out before any label is counted as "active."

WHAT ROOT POSTS MEAN FOR A2
--------------------------------------------------------------------
`score_corpus.py` only scores replies (`ZISROOTPOST = 0`); root/outlet posts
are never scored. A depth-1 reply's parent is the root post, so its
"parent civil/uncivil" status is always unknown (never available) -- those
rows correctly contribute zero to the parent-conditional counts, but still
contribute to the base rate (which only needs the child to be scored).

SAFETY
------
Store opened strictly read-only via `file:...?mode=ro` (never
`?immutable=1` -- WAL-blind, has returned zero rows on a populated store).
This script never writes to the store, and never touches
`/Volumes/Eregion/bluex-data/social/` or `/Volumes/Eregion/bluex-data/predictions/`.
JSONL files are streamed line by line, never fully materialized as text.
"""
import argparse
import csv
import datetime as dt
import glob
import json
import math
import os
import sqlite3
import sys

SCORE_HEAD = "toxicity"
TOXICITY_THRESHOLD = 0.50
MIN_SCORED_REPLIES_FOR_MEAN_RANK = 10
HATE_RELEVANT_LABELS = frozenset({"intolerant", "threat", "extremist", "intolerant-race"})
RUDE_LABEL = "rude"

AUC_HATE_VS_RUDE = "0.198"
AUC_RUDE_VS_RANDOM = "0.946"

# Core Data stores timestamps as seconds since 2001-01-01T00:00:00Z.
CORE_DATA_EPOCH_OFFSET = 978307200

DEFAULT_STORE_PATH = "/Volumes/Eregion/bluex-data/default.store"
DEFAULT_SCORES_DIR = "/Volumes/Eregion/bluex-incivility"
DEFAULT_LABELS_DIR = "/Volumes/Eregion/bluex-labels"
DEFAULT_OUT_DIR = "/Volumes/Eregion/bluex-data/analysis/"


class CountMismatchError(Exception):
    """An analysis's reported counts don't reconcile against the actual
    scored-post join it was built from. Refuses output by default."""


# --------------------------------------------------------------------------
# Small shared utilities
# --------------------------------------------------------------------------

def ro_uri(path):
    """Read-only SQLite URI. Deliberately NOT immutable=1 (see module docstring)."""
    return "file:" + os.path.abspath(path) + "?mode=ro"


def now_iso():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def now_stamp():
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H%M%SZ")


def coredata_to_unix(value):
    """Core Data timestamp (seconds since 2001-01-01Z) -> Unix seconds."""
    return float(value) + CORE_DATA_EPOCH_OFFSET


def parse_iso8601(text):
    """Parse an ISO-8601 timestamp (with or without fractional seconds,
    'Z' suffix) into Unix seconds. Returns None if unparseable."""
    if not text:
        return None
    value = text.strip()
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    try:
        return dt.datetime.fromisoformat(value).timestamp()
    except ValueError:
        return None


def depth_bucket(depth):
    """1, 2, 3, or '4+' for depth >= 4. depth is expected to be an int
    (ZPOST.ZDEPTH); depths of 0 (root posts themselves) never appear here
    because only replies (ZISROOTPOST=0) are fed into this function."""
    if depth is None:
        return "unknown"
    if depth >= 4:
        return "4+"
    return str(depth)


def wilson_ci(k, n, z=1.96):
    """Wilson score interval for a binomial proportion. Verbatim algebra
    from tools/labelling/base_rate.py -- do not "simplify" it."""
    if n == 0:
        return (0.0, 0.0)
    p = k / n
    denom = 1 + z * z / n
    centre = (p + z * z / (2 * n)) / denom
    half = (z / denom) * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))
    return (max(0.0, centre - half), min(1.0, centre + half))


def gini(values):
    """Gini coefficient of a non-negative list of values (e.g. per-author
    incivility mass). 0 = perfect equality, ~1 = maximal concentration.
    Uses the standard discrete-population formula (mean absolute difference
    / (2 * mean)); returns 0.0 for an empty list or an all-zero list rather
    than raising or returning NaN."""
    n = len(values)
    if n == 0:
        return 0.0
    total = sum(values)
    if total == 0:
        return 0.0
    ordered = sorted(values)
    cum = 0.0
    weighted_sum = 0.0
    for i, v in enumerate(ordered, start=1):
        weighted_sum += i * v
    # Standard formula: G = (2 * sum(i * x_i) / (n * sum(x))) - (n + 1) / n
    return (2.0 * weighted_sum) / (n * total) - (n + 1.0) / n


def assert_reconciliation(computed, expected, label, allow_mismatch=False):
    """Refuse (raise CountMismatchError) unless computed == expected, for a
    named analysis. Downgrades to a printed warning when allow_mismatch is
    True. Returns (computed, expected) either way."""
    if computed != expected:
        message = (
            "%s reconciliation FAILED: computed count %d != expected %d "
            "(difference %d) -- refusing to write output." % (
                label, computed, expected, computed - expected,
            )
        )
        if allow_mismatch:
            print("WARNING: %s (continuing: --allow-count-mismatch)" % message, file=sys.stderr)
        else:
            raise CountMismatchError(message)
    return computed, expected


# --------------------------------------------------------------------------
# Score file discovery + loading (mirrors tools/incivility/aggregate_weekly.py)
# --------------------------------------------------------------------------

def find_score_files(scores_dir):
    """All incivility-scores-*.jsonl files, oldest first (ISO timestamps in
    the filename sort correctly as plain strings)."""
    return sorted(glob.glob(os.path.join(scores_dir, "incivility-scores-*.jsonl")))


def load_scores(score_paths, head=SCORE_HEAD):
    """Stream every jsonl file (oldest-first) and return uri -> score for the
    given head only. Duplicate uri+head lines resolve last-one-wins across
    files, exactly as tools/incivility/aggregate_weekly.py does."""
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
    found, or (None, None) if there are none."""
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
# Label file discovery + loading
# --------------------------------------------------------------------------

def find_label_files(labels_dir):
    """All label-harvest-posts-*.jsonl files, oldest first."""
    return sorted(glob.glob(os.path.join(labels_dir, "label-harvest-posts-*.jsonl")))


def load_active_post_labels(label_paths):
    """Stream every label-harvest-posts-*.jsonl file (oldest first) and
    return uri -> [{"val": ..., "cts": ...}, ...] for labels whose LATEST
    record for that (uri, val) pair is active (neg is falsy). `subject`
    (the post URI) is only considered when subject_type == 'post'.

    A label can be observed active in an early sweep and later retracted
    (`neg: true`) in a subsequent sweep -- the same value can appear twice
    for the same uri across files/lines. Last-one-wins per (uri, val),
    exactly like score merging: the record read last (in file order, files
    processed oldest-first) determines whether that label is currently
    active. This is required so a retraction is not shadowed by an earlier
    active record for the same value; see module docstring / the
    bluex-labels/README.md 100x-overstatement warning.
    """
    latest = {}
    for path in label_paths:
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                record = json.loads(line)
                if record.get("subject_type") != "post":
                    continue
                key = (record["subject"], record.get("val"))
                latest[key] = record

    active = {}
    for (uri, val), record in latest.items():
        if record.get("neg"):
            continue
        active.setdefault(uri, []).append({
            "val": val,
            "cts": record.get("cts"),
        })
    return active


# --------------------------------------------------------------------------
# Store access
# --------------------------------------------------------------------------

REPLY_ROWS_QUERY = """
SELECT r.ZURI, r.ZAUTHORDID, r.ZPARENTURI, r.ZDEPTH, r.ZCREATEDAT, ta.ZHANDLE
  FROM ZPOST r
  LEFT JOIN ZPOST root ON root.ZURI = r.ZROOTURI AND root.ZISROOTPOST = 1
  LEFT JOIN ZTRACKEDACCOUNT ta ON ta.Z_PK = root.ZACCOUNT
 WHERE r.ZISROOTPOST = 0 AND r.ZURI IS NOT NULL
"""


def fetch_reply_rows(store_path):
    """Return [{"uri", "author_did", "parent_uri", "depth", "created_unix",
    "outlet"}, ...] for every reply in the store. `outlet` is None when the
    reply's root isn't attributable to a tracked account -- that row is
    still included (A1 doesn't need an outlet; A2 buckets it under an
    explicit 'unknown' outlet rather than dropping it silently).
    """
    conn = sqlite3.connect(ro_uri(store_path), uri=True)
    try:
        rows = conn.execute(REPLY_ROWS_QUERY).fetchall()
    finally:
        conn.close()
    result = []
    for uri, author_did, parent_uri, depth, created, outlet in rows:
        result.append({
            "uri": uri,
            "author_did": author_did,
            "parent_uri": parent_uri,
            "depth": depth if depth is not None else 0,
            "created_unix": coredata_to_unix(created) if created is not None else None,
            "outlet": outlet if outlet is not None else "unknown",
        })
    return result


# --------------------------------------------------------------------------
# A1 -- author concentration
# --------------------------------------------------------------------------

def compute_author_stats(replies, scores, threshold=TOXICITY_THRESHOLD):
    """replies: [{"uri", "author_did", ...}, ...]; scores: uri -> score.

    Returns author_did -> {"reply_count", "n_scored", "mean_toxicity",
    "max_toxicity", "n_above_threshold", "incivility_mass"}. Authors with
    zero scored replies get None for mean/max (never 0.0) and mass 0.0
    (an empty sum is legitimately 0, unlike a mean/max of nothing).
    """
    stats = {}
    for reply in replies:
        author = reply["author_did"]
        row = stats.setdefault(author, {
            "reply_count": 0, "n_scored": 0, "_values": [],
        })
        row["reply_count"] += 1
        score = scores.get(reply["uri"])
        if score is not None:
            row["n_scored"] += 1
            row["_values"].append(score)

    result = {}
    for author, row in stats.items():
        values = row["_values"]
        n_scored = row["n_scored"]
        result[author] = {
            "reply_count": row["reply_count"],
            "n_scored": n_scored,
            "mean_toxicity": (sum(values) / n_scored) if n_scored else None,
            "max_toxicity": max(values) if values else None,
            "n_above_threshold": sum(1 for v in values if v > threshold),
            "incivility_mass": sum(values),
        }
    return result


def top_share(pairs, fraction):
    """pairs: [(rank_key, mass), ...] already meant to be ranked by the
    caller (sorted desc by whatever criterion). Returns the share of total
    mass held by the top `fraction` of entries (e.g. 0.01 for top 1%),
    always taking at least 1 entry if pairs is non-empty. Returns None if
    pairs is empty or total mass is 0."""
    n = len(pairs)
    if n == 0:
        return None
    total_mass = sum(m for _, m in pairs)
    if total_mass == 0:
        return None
    k = max(1, int(round(n * fraction)))
    top_mass = sum(m for _, m in pairs[:k])
    return top_mass / total_mass


def compute_a1(replies, scores, threshold=TOXICITY_THRESHOLD,
               min_scored_for_mean_rank=MIN_SCORED_REPLIES_FOR_MEAN_RANK):
    """Returns (rows, summary). `rows` is a list of per-author dicts
    (author_did + the compute_author_stats fields) sorted by reply_count
    descending. `summary` carries gini, top-1%/10% mass shares by volume
    rank and by mean-score rank (restricted to authors with
    >= min_scored_for_mean_rank scored replies), and null-accounting."""
    stats = compute_author_stats(replies, scores, threshold=threshold)

    rows = []
    for author, row in stats.items():
        entry = {"author_did": author}
        entry.update(row)
        rows.append(entry)
    rows.sort(key=lambda r: r["reply_count"], reverse=True)

    mass_values = [r["incivility_mass"] for r in rows if r["n_scored"] > 0]
    gini_coefficient = gini(mass_values)

    by_volume = sorted(rows, key=lambda r: r["reply_count"], reverse=True)
    volume_pairs = [(r["author_did"], r["incivility_mass"]) for r in by_volume]
    top1_share_volume = top_share(volume_pairs, 0.01)
    top10_share_volume = top_share(volume_pairs, 0.10)

    eligible = [r for r in rows if r["n_scored"] >= min_scored_for_mean_rank]
    eligible_sorted = sorted(eligible, key=lambda r: r["mean_toxicity"], reverse=True)
    mean_rank_pairs = [(r["author_did"], r["incivility_mass"]) for r in eligible_sorted]
    top1_share_mean = top_share(mean_rank_pairs, 0.01)
    top10_share_mean = top_share(mean_rank_pairs, 0.10)

    n_authors_no_score = sum(1 for r in rows if r["n_scored"] == 0)
    n_replies_no_score = sum(r["reply_count"] - r["n_scored"] for r in rows)

    summary = {
        "n_authors": len(rows),
        "n_replies": sum(r["reply_count"] for r in rows),
        "n_authors_no_score": n_authors_no_score,
        "n_replies_no_score": n_replies_no_score,
        "gini": gini_coefficient,
        "top1pct_share_by_volume": top1_share_volume,
        "top10pct_share_by_volume": top10_share_volume,
        "n_eligible_for_mean_rank": len(eligible),
        "top1pct_share_by_mean_score": top1_share_mean,
        "top10pct_share_by_mean_score": top10_share_mean,
        "threshold": threshold,
        "min_scored_for_mean_rank": min_scored_for_mean_rank,
    }
    return rows, summary


# --------------------------------------------------------------------------
# A2 -- escalation dynamics
# --------------------------------------------------------------------------

def compute_escalation(replies, scores, threshold=TOXICITY_THRESHOLD):
    """replies: [{"uri", "parent_uri", "depth", "outlet"}, ...]; scores:
    uri -> score.

    Returns a list of rows, one per (outlet, depth_bucket) cell that has at
    least one scored child, PLUS aggregate rows with outlet='ALL' (across
    outlets, per depth bucket), depth_bucket='ALL' (across depths, per
    outlet), and outlet='ALL'/depth_bucket='ALL' (grand total). Each row:
      n_children_scored, n_base_uncivil, base_rate, base_rate_ci,
      n_parent_uncivil, n_child_uncivil_given_parent_uncivil,
      p_child_uncivil_given_parent_uncivil, ci_given_parent_uncivil,
      n_parent_civil, n_child_uncivil_given_parent_civil,
      p_child_uncivil_given_parent_civil, ci_given_parent_civil,
      small_n (True if n_children_scored < 100 -- reported, not averaged away).

    Depth-1 rows' parent is always the (never-scored) root post, so
    n_parent_uncivil and n_parent_civil are always 0 there by construction
    -- not a bug, see module docstring.
    """
    cells = {}

    def cell(outlet, bucket):
        key = (outlet, bucket)
        return cells.setdefault(key, {
            "n_children_scored": 0, "n_base_uncivil": 0,
            "n_parent_uncivil": 0, "n_child_uncivil_given_parent_uncivil": 0,
            "n_parent_civil": 0, "n_child_uncivil_given_parent_civil": 0,
        })

    for reply in replies:
        child_score = scores.get(reply["uri"])
        if child_score is None:
            continue
        outlet = reply["outlet"]
        bucket = depth_bucket(reply["depth"])
        child_uncivil = child_score > threshold
        parent_score = scores.get(reply["parent_uri"])

        for key_outlet in (outlet, "ALL"):
            for key_bucket in (bucket, "ALL"):
                c = cell(key_outlet, key_bucket)
                c["n_children_scored"] += 1
                if child_uncivil:
                    c["n_base_uncivil"] += 1
                if parent_score is not None:
                    if parent_score > threshold:
                        c["n_parent_uncivil"] += 1
                        if child_uncivil:
                            c["n_child_uncivil_given_parent_uncivil"] += 1
                    else:
                        c["n_parent_civil"] += 1
                        if child_uncivil:
                            c["n_child_uncivil_given_parent_civil"] += 1

    rows = []
    for (outlet, bucket), c in cells.items():
        n = c["n_children_scored"]
        base_lo, base_hi = wilson_ci(c["n_base_uncivil"], n)
        n_pu = c["n_parent_uncivil"]
        n_pc = c["n_parent_civil"]
        k_pu = c["n_child_uncivil_given_parent_uncivil"]
        k_pc = c["n_child_uncivil_given_parent_civil"]
        pu_lo, pu_hi = wilson_ci(k_pu, n_pu)
        pc_lo, pc_hi = wilson_ci(k_pc, n_pc)
        rows.append({
            "outlet": outlet,
            "depth_bucket": bucket,
            "n_children_scored": n,
            "n_base_uncivil": c["n_base_uncivil"],
            "base_rate": (c["n_base_uncivil"] / n) if n else None,
            "base_rate_ci_lo": base_lo,
            "base_rate_ci_hi": base_hi,
            "n_parent_uncivil": n_pu,
            "n_child_uncivil_given_parent_uncivil": k_pu,
            "p_child_uncivil_given_parent_uncivil": (k_pu / n_pu) if n_pu else None,
            "ci_given_parent_uncivil_lo": pu_lo,
            "ci_given_parent_uncivil_hi": pu_hi,
            "n_parent_civil": n_pc,
            "n_child_uncivil_given_parent_civil": k_pc,
            "p_child_uncivil_given_parent_civil": (k_pc / n_pc) if n_pc else None,
            "ci_given_parent_civil_lo": pc_lo,
            "ci_given_parent_civil_hi": pc_hi,
            "small_n": n < 100,
        })
    rows.sort(key=lambda r: (r["outlet"], r["depth_bucket"]))
    return rows


# --------------------------------------------------------------------------
# A3 -- moderation coverage by toxicity decile
# --------------------------------------------------------------------------

def compute_moderation_coverage(scores, active_labels, created_at, n_deciles=10):
    """scores: uri -> score (scored replies only); active_labels: uri ->
    [{"val","cts"}, ...] (active only, see load_active_post_labels);
    created_at: uri -> unix seconds (reply creation time, for latency).

    Deciles are QUANTILE-based (equal population per bucket, decile 1 =
    lowest scores .. decile n_deciles = highest), computed over the scored
    population -- not fixed 0.0-0.1 score-value bins, since the score
    distribution is heavily skewed toward 0 and fixed bins would leave most
    deciles nearly empty. Every scored post lands in exactly one decile;
    posts with no score at all (unscored replies, or root posts which are
    never scored) never enter this table -- there is no decile for them.

    Returns one row per decile: n_posts, n_any_active_label,
    coverage/wilson CI, n_hate_relevant_label + its coverage/CI,
    n_rude_label + its coverage/CI, and median_latency_days (None if no
    labelled post in that decile has a parseable cts and created_at pair).
    """
    ordered = sorted(scores.items(), key=lambda kv: kv[1])
    n = len(ordered)
    deciles = [[] for _ in range(n_deciles)]
    for i, (uri, score) in enumerate(ordered):
        idx = min(n_deciles - 1, (i * n_deciles) // n) if n else 0
        deciles[idx].append(uri)

    rows = []
    for i, uris in enumerate(deciles):
        n_posts = len(uris)
        n_any = 0
        n_hate = 0
        n_rude = 0
        latencies = []
        for uri in uris:
            labels = active_labels.get(uri)
            if not labels:
                continue
            n_any += 1
            vals = {rec["val"] for rec in labels}
            if vals & HATE_RELEVANT_LABELS:
                n_hate += 1
            if RUDE_LABEL in vals:
                n_rude += 1
            post_created = created_at.get(uri)
            if post_created is not None:
                for rec in labels:
                    label_ts = parse_iso8601(rec.get("cts"))
                    if label_ts is not None:
                        latencies.append((label_ts - post_created) / 86400.0)

        any_lo, any_hi = wilson_ci(n_any, n_posts)
        hate_lo, hate_hi = wilson_ci(n_hate, n_posts)
        rude_lo, rude_hi = wilson_ci(n_rude, n_posts)
        latencies.sort()
        median_latency = None
        if latencies:
            mid = len(latencies) // 2
            if len(latencies) % 2:
                median_latency = latencies[mid]
            else:
                median_latency = (latencies[mid - 1] + latencies[mid]) / 2.0

        rows.append({
            "decile": i + 1,
            "n_posts": n_posts,
            "n_any_active_label": n_any,
            "coverage_any": (n_any / n_posts) if n_posts else None,
            "coverage_any_ci_lo": any_lo, "coverage_any_ci_hi": any_hi,
            "n_hate_relevant_label": n_hate,
            "coverage_hate": (n_hate / n_posts) if n_posts else None,
            "coverage_hate_ci_lo": hate_lo, "coverage_hate_ci_hi": hate_hi,
            "n_rude_label": n_rude,
            "coverage_rude": (n_rude / n_posts) if n_posts else None,
            "coverage_rude_ci_lo": rude_lo, "coverage_rude_ci_hi": rude_hi,
            "median_latency_days": median_latency,
        })
    return rows


# --------------------------------------------------------------------------
# CSV / Markdown output
# --------------------------------------------------------------------------

def csv_honesty_comment_lines(meta):
    """`#`-prefixed comment lines carrying the honesty header: model id +
    revision, that the head measures INCIVILITY not hate (with the 0.198 /
    0.946 numbers), the threshold used (stated as illustrative), the number
    of posts scored vs unscored, and the run timestamp. Present in every
    CSV this script writes -- not only in the Markdown twin."""
    return [
        "# BlueX incivility x structure analysis.",
        "# This measures INCIVILITY, NOT HATE. The toxicity head separates",
        "# moderator-labelled 'rude' posts from random replies at AUC %s" % AUC_RUDE_VS_RANDOM,
        "# (validated against moderator rude labels) but rates 'rude' posts as",
        "# MORE toxic than moderator-labelled 'hate' posts 80% of the time",
        "# (hate-vs-rude AUC %s -- worse than chance, wrong direction)." % AUC_HATE_VS_RUDE,
        "# Incivility and hate are anti-correlated on this corpus; concentration",
        "# or escalation of INCIVILITY below must never be read as a claim about",
        "# hate. See docs/superpowers/notes/2026-08-11-nltagger-sentiment-does-not-detect-hate.md",
        "# and TODO.md's dissociation table.",
        "# The toxicity threshold used here (%.2f) is an ARBITRARY ILLUSTRATIVE" % meta["threshold"],
        "# THRESHOLD on the raw sigmoid score, not a calibrated decision boundary.",
        "# Posts scored: %s. Posts unscored (never treated as score 0): %s." % (
            meta.get("n_scored"), meta.get("n_unscored"),
        ),
        "# model_id=%s model_revision=%s" % (meta.get("model_id"), meta.get("model_revision")),
        "# generated_at=%s" % meta.get("generated_at"),
    ]


def write_csv_with_header(path, fieldnames, rows, meta):
    with open(path, "w", newline="", encoding="utf-8") as handle:
        for line in csv_honesty_comment_lines(meta):
            handle.write(line + "\n")
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow({k: ("" if row.get(k) is None else row.get(k)) for k in fieldnames})


A1_FIELDS = ["author_did", "reply_count", "n_scored", "mean_toxicity",
             "max_toxicity", "n_above_threshold", "incivility_mass"]
A2_FIELDS = ["outlet", "depth_bucket", "n_children_scored", "n_base_uncivil",
             "base_rate", "base_rate_ci_lo", "base_rate_ci_hi",
             "n_parent_uncivil", "n_child_uncivil_given_parent_uncivil",
             "p_child_uncivil_given_parent_uncivil", "ci_given_parent_uncivil_lo",
             "ci_given_parent_uncivil_hi", "n_parent_civil",
             "n_child_uncivil_given_parent_civil", "p_child_uncivil_given_parent_civil",
             "ci_given_parent_civil_lo", "ci_given_parent_civil_hi", "small_n"]
A3_FIELDS = ["decile", "n_posts", "n_any_active_label", "coverage_any",
             "coverage_any_ci_lo", "coverage_any_ci_hi", "n_hate_relevant_label",
             "coverage_hate", "coverage_hate_ci_lo", "coverage_hate_ci_hi",
             "n_rude_label", "coverage_rude", "coverage_rude_ci_lo",
             "coverage_rude_ci_hi", "median_latency_days"]

HONESTY_HEADER_MD = """\
> **This measures incivility, not hate.** The `toxicity` head used here
> separates moderator-labelled `rude` posts from random replies at AUC
> {auc_rude} but rates `rude` posts as MORE toxic than moderator-labelled
> `hate` posts 80% of the time (hate-vs-rude AUC **{auc_hate}**, worse than
> chance and in the wrong direction). Incivility and hate are
> anti-correlated on this corpus. None of A1/A2/A3 below license any claim
> about hate -- concentration or escalation of incivility is not evidence
> of concentration or escalation of hate.
>
> **The {threshold:.2f} threshold is an arbitrary illustrative cut** on the
> raw sigmoid score, not a calibrated decision boundary.
>
> **Moderation labels (A3) record what was reported and actioned, not
> ground truth about content.** Absence of a label is the overwhelmingly
> common case and reflects that most content is never reviewed, not that
> it was reviewed and passed.
"""


def write_markdown_summary(path, meta, a1_summary, a2_rows, a3_rows):
    lines = []
    lines.append("# BlueX incivility x structure analysis")
    lines.append("")
    lines.append(HONESTY_HEADER_MD.format(
        auc_rude=AUC_RUDE_VS_RANDOM, auc_hate=AUC_HATE_VS_RUDE, threshold=meta["threshold"],
    ))
    lines.append("")
    lines.append("## Reproducibility")
    lines.append("")
    lines.append("- Generated: `%s`" % meta["generated_at"])
    lines.append("- Model: `%s` (revision `%s`)" % (meta.get("model_id"), meta.get("model_revision")))
    lines.append("- Score head: `%s`" % SCORE_HEAD)
    lines.append("- Threshold: `%.2f` (illustrative, uncalibrated)" % meta["threshold"])
    lines.append("- Posts scored: %s; posts unscored: %s" % (meta.get("n_scored"), meta.get("n_unscored")))
    lines.append("")

    lines.append("## A1 -- author concentration")
    lines.append("")
    lines.append("- Authors: %d; replies: %d" % (a1_summary["n_authors"], a1_summary["n_replies"]))
    lines.append("- Authors with zero scored replies: %d" % a1_summary["n_authors_no_score"])
    lines.append("- Replies with no score at all: %d" % a1_summary["n_replies_no_score"])
    lines.append("- Gini coefficient of incivility mass across authors: %.4f" % a1_summary["gini"])
    lines.append("- Top 1%% of authors by reply volume produce %s of total incivility mass" % fmt_pct(a1_summary["top1pct_share_by_volume"]))
    lines.append("- Top 10%% of authors by reply volume produce %s of total incivility mass" % fmt_pct(a1_summary["top10pct_share_by_volume"]))
    lines.append(
        "- Among authors with >= %d scored replies (n=%d), top 1%% by mean "
        "score hold %s and top 10%% hold %s of that subset's incivility mass"
        % (a1_summary["min_scored_for_mean_rank"], a1_summary["n_eligible_for_mean_rank"],
           fmt_pct(a1_summary["top1pct_share_by_mean_score"]),
           fmt_pct(a1_summary["top10pct_share_by_mean_score"]))
    )
    lines.append("")
    lines.append(
        "**Interpretation:** if incivility mass is concentrated in a small "
        "share of authors, author-level detection is likely more powerful "
        "than post-level detection (the structure exploited by prior "
        "Reconquista-style work). This says nothing about where HATE is "
        "concentrated -- the toxicity head is anti-correlated with hate "
        "(hate-vs-rude AUC %s)." % AUC_HATE_VS_RUDE
    )
    lines.append("")

    lines.append("## A2 -- escalation dynamics")
    lines.append("")
    lines.append(
        "P(child uncivil | parent uncivil) vs P(child uncivil | parent civil) "
        "vs base rate, by reply depth and outlet. Depth-1 rows' parent is the "
        "root post, which is never scored (`score_corpus.py` only scores "
        "replies) -- their parent-conditional counts are structurally zero, "
        "not a data gap. Cells with n < 100 are flagged `small_n=True`, not "
        "silently averaged away."
    )
    lines.append("")
    lines.append("| outlet | depth | n_scored | base_rate | p(uncivil|parent uncivil) | p(uncivil|parent civil) | small_n |")
    lines.append("|---|---|---|---|---|---|---|")
    for row in a2_rows:
        lines.append("| %s | %s | %d | %s | %s | %s | %s |" % (
            row["outlet"], row["depth_bucket"], row["n_children_scored"],
            fmt_pct(row["base_rate"]),
            fmt_ci(row["p_child_uncivil_given_parent_uncivil"], row["ci_given_parent_uncivil_lo"], row["ci_given_parent_uncivil_hi"]),
            fmt_ci(row["p_child_uncivil_given_parent_civil"], row["ci_given_parent_civil_lo"], row["ci_given_parent_civil_hi"]),
            row["small_n"],
        ))
    lines.append("")
    lines.append(
        "**Interpretation:** this is the Garland et al. 2020 escalation "
        "mechanism question, answerable with incivility alone. A materially "
        "higher p(child uncivil | parent uncivil) than the base rate is "
        "evidence of contagion in INCIVILITY within reply chains -- it is "
        "not evidence about hate."
    )
    lines.append("")

    lines.append("## A3 -- does incivility predict moderation?")
    lines.append("")
    lines.append(
        "Active post-level moderation labels joined to toxicity deciles "
        "(decile 1 = lowest scores, decile %d = highest, quantile-based over "
        "the scored population). `neg: true` (retracted) labels are excluded."
        % len(a3_rows)
    )
    lines.append("")
    lines.append("| decile | n_posts | any-label coverage | hate-relevant coverage | rude coverage | median latency (days) |")
    lines.append("|---|---|---|---|---|---|")
    for row in a3_rows:
        lines.append("| %d | %d | %s | %s | %s | %s |" % (
            row["decile"], row["n_posts"],
            fmt_ci(row["coverage_any"], row["coverage_any_ci_lo"], row["coverage_any_ci_hi"]),
            fmt_ci(row["coverage_hate"], row["coverage_hate_ci_lo"], row["coverage_hate_ci_hi"]),
            fmt_ci(row["coverage_rude"], row["coverage_rude_ci_lo"], row["coverage_rude_ci_hi"]),
            ("%.1f" % row["median_latency_days"]) if row["median_latency_days"] is not None else "n/a",
        ))
    lines.append("")
    lines.append(
        "**Interpretation:** this measures Bluesky's own moderation "
        "coverage against our incivility signal -- a finding about "
        "moderation practice, not about ground truth. Moderation labels "
        "record what was reported and actioned, never what is objectively "
        "true about the content."
    )
    lines.append("")

    with open(path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines))


def fmt_pct(value):
    if value is None:
        return "n/a"
    return "%.2f%%" % (value * 100.0)


def fmt_ci(point, lo, hi):
    if point is None:
        return "n/a"
    return "%.2f%% [%.2f%%, %.2f%%]" % (point * 100.0, lo * 100.0, hi * 100.0)


# --------------------------------------------------------------------------
# Top-level run
# --------------------------------------------------------------------------

def run(store_path, scores_dir, labels_dir, out_dir, threshold=TOXICITY_THRESHOLD,
        allow_count_mismatch=False):
    score_paths = find_score_files(scores_dir)
    if not score_paths:
        raise RuntimeError("no incivility-scores-*.jsonl found in %s" % scores_dir)
    scores = load_scores(score_paths)
    print("Merged distinct scored URIs (head=%s): %d" % (SCORE_HEAD, len(scores)))
    model_id, model_revision = scores_model_identity(score_paths)

    label_paths = find_label_files(labels_dir)
    active_labels = load_active_post_labels(label_paths)

    replies = fetch_reply_rows(store_path)
    replies_by_uri = {r["uri"]: r for r in replies}
    scores_among_replies = {uri: v for uri, v in scores.items() if uri in replies_by_uri}

    n_scored = len(scores_among_replies)
    n_unscored = len(replies) - n_scored

    meta = {
        "model_id": model_id,
        "model_revision": model_revision,
        "threshold": threshold,
        "n_scored": n_scored,
        "n_unscored": n_unscored,
        "generated_at": now_iso(),
    }

    # --- A1 ---
    a1_rows, a1_summary = compute_a1(replies, scores_among_replies, threshold=threshold)
    a1_computed = sum(r["n_scored"] for r in a1_rows)
    assert_reconciliation(a1_computed, n_scored, "A1", allow_mismatch=allow_count_mismatch)

    # --- A2 ---
    a2_rows = compute_escalation(replies, scores_among_replies, threshold=threshold)
    a2_leaf_rows = [r for r in a2_rows if r["outlet"] != "ALL" and r["depth_bucket"] != "ALL"]
    a2_computed = sum(r["n_children_scored"] for r in a2_leaf_rows)
    assert_reconciliation(a2_computed, n_scored, "A2", allow_mismatch=allow_count_mismatch)

    # --- A3 ---
    created_at = {r["uri"]: r["created_unix"] for r in replies if r["created_unix"] is not None}
    a3_rows = compute_moderation_coverage(scores_among_replies, active_labels, created_at)
    a3_computed = sum(r["n_posts"] for r in a3_rows)
    assert_reconciliation(a3_computed, n_scored, "A3", allow_mismatch=allow_count_mismatch)

    os.makedirs(out_dir, exist_ok=True)
    a1_path = os.path.join(out_dir, "a1_author_incivility.csv")
    a2_path = os.path.join(out_dir, "a2_escalation.csv")
    a3_path = os.path.join(out_dir, "a3_moderation_coverage.csv")
    md_path = os.path.join(out_dir, "incivility_structure_summary.md")

    write_csv_with_header(a1_path, A1_FIELDS, a1_rows, meta)
    write_csv_with_header(a2_path, A2_FIELDS, a2_rows, meta)
    write_csv_with_header(a3_path, A3_FIELDS, a3_rows, meta)
    write_markdown_summary(md_path, meta, a1_summary, a2_rows, a3_rows)

    return {
        "a1_path": a1_path, "a2_path": a2_path, "a3_path": a3_path, "md_path": md_path,
        "a1_summary": a1_summary, "a2_rows": a2_rows, "a3_rows": a3_rows,
        "meta": meta,
    }


def print_headline_summary(result):
    meta = result["meta"]
    a1 = result["a1_summary"]
    print("")
    print("=== HEADLINE NUMBERS ===")
    print("Posts scored: %d, unscored: %d" % (meta["n_scored"], meta["n_unscored"]))
    print("A1: %d authors, %d replies, gini=%.4f, top1%%-by-volume mass share=%s, "
          "top10%%-by-volume mass share=%s" % (
              a1["n_authors"], a1["n_replies"], a1["gini"],
              fmt_pct(a1["top1pct_share_by_volume"]), fmt_pct(a1["top10pct_share_by_volume"]),
          ))
    print("A1: authors with zero scored replies=%d, replies with no score=%d" % (
        a1["n_authors_no_score"], a1["n_replies_no_score"],
    ))
    a2_total = next((r for r in result["a2_rows"] if r["outlet"] == "ALL" and r["depth_bucket"] == "ALL"), None)
    if a2_total:
        print("A2 (overall): base_rate=%s, p(uncivil|parent uncivil)=%s, p(uncivil|parent civil)=%s" % (
            fmt_pct(a2_total["base_rate"]),
            fmt_ci(a2_total["p_child_uncivil_given_parent_uncivil"], a2_total["ci_given_parent_uncivil_lo"], a2_total["ci_given_parent_uncivil_hi"]),
            fmt_ci(a2_total["p_child_uncivil_given_parent_civil"], a2_total["ci_given_parent_civil_lo"], a2_total["ci_given_parent_civil_hi"]),
        ))
    a3_rows = result["a3_rows"]
    if a3_rows:
        top_decile = a3_rows[-1]
        bottom_decile = a3_rows[0]
        print("A3: top decile any-label coverage=%s (n=%d); bottom decile=%s (n=%d)" % (
            fmt_pct(top_decile["coverage_any"]), top_decile["n_posts"],
            fmt_pct(bottom_decile["coverage_any"]), bottom_decile["n_posts"],
        ))


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Incivility x structure: author concentration, escalation "
                     "dynamics, moderation coverage -- needs no human labels."
    )
    parser.add_argument("--store", default=DEFAULT_STORE_PATH)
    parser.add_argument("--scores-dir", default=DEFAULT_SCORES_DIR)
    parser.add_argument("--labels-dir", default=DEFAULT_LABELS_DIR)
    parser.add_argument("--out-dir", default=DEFAULT_OUT_DIR)
    parser.add_argument("--threshold", type=float, default=TOXICITY_THRESHOLD)
    parser.add_argument("--allow-count-mismatch", action="store_true")
    args = parser.parse_args(argv)

    try:
        result = run(args.store, args.scores_dir, args.labels_dir, args.out_dir,
                      threshold=args.threshold, allow_count_mismatch=args.allow_count_mismatch)
    except CountMismatchError as exc:
        print("ERROR: %s" % exc, file=sys.stderr)
        return 1

    print("Wrote %s" % result["a1_path"])
    print("Wrote %s" % result["a2_path"])
    print("Wrote %s" % result["a3_path"])
    print("Wrote %s" % result["md_path"])
    print_headline_summary(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
