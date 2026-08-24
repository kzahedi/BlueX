#!/usr/bin/env python3
"""Stratified labelling frame-file generator.

WHY THIS EXISTS
----------------
docs/superpowers/specs/2026-08-24-stratified-labelling-frame-design.md S2:
the labelling app must NEVER see a committee score. `LabellingContext` has
no score fields, and that blindness guarantee must not come to rest on
"nobody added a field" -- it must be structural. This tool is where that
structure lives: it reads committee.db (Python-side, never shipped to the
app), decides *which* URIs to show under *which* stratum, and writes a
frame file that carries a URI list and stratum bookkeeping ONLY. No score,
percentile, or ranking value for any URI appears anywhere in the file.

STRATA
------
All eight strata are defined on the COMPARABLE columns
(mean_pct_full/spread_pct_full, defined only where n_members == 3) or on a
single member's own percentile column (tox_pct/tfidf_pct/d2v_pct) -- never
on the variable-membership mean_pct/spread_pct (see score_committee.py's
MEAN_PCT_CAVEAT for why: 70.4% of mean_pct's top 0.1% band is posts missing
the toxicity member, not an "all three agree" conjunction).
`validate_stratum_definition` refuses at build time if a bare mean_pct/
spread_pct ever creeps into a definition or its SQL predicate.

POPULATION SIZE VS. SAMPLE SIZE
---------------------------------
Every stratum's `population_size` is the TRUE size of that stratum in the
whole corpus (computed BEFORE excluding already-labelled URIs or sampling)
-- the Horvitz-Thompson estimator in the design doc needs N_h, not n_h.
`uris` is a seeded random subsample of the stratum, drawn AFTER excluding
already-labelled URIs (so the app never re-shows something already
labelled) -- but that exclusion does not change the reported
`population_size`, which is a fact about the corpus, not about what has
been sampled.

EXCLUDING ALREADY-LABELLED URIs
---------------------------------
Preferred: `--exclude-file` (plain-text, one URI per line, or a JSON array
of URIs). Fallback: `read_labelled_uris_from_store`, an ISOLATED, read-only
function that joins ZANNOTATION.ZPOST -> ZPOST.Z_PK and selects ONLY
ZPOST.ZURI for rows where ZANNOTATION.ZSTAGE = 'human'. It reads NO label
value (no ZSPEECHCLASS, ZSEVERITY, ZCONFIDENCE, ZRAWRESPONSE, etc.) --
verified by test_build_frame.py greping this function's own source. The
store is opened strictly read-only (`?mode=ro`, never `?immutable=1`) and
is never written to.

SAFETY
------
This tool never writes to /Volumes/Eregion/bluex-data/default.store and
never touches /Volumes/Eregion/bluex-data/social/. The frame file it
produces is written wherever `--out` points (intended:
/Volumes/Eregion/bluex-data/committee/) -- never into this git repo.
"""
import argparse
import datetime as dt
import hashlib
import json
import os
import random
import re
import sqlite3
import sys

COMMITTEE_MEMBERS = ["incivility_toxicity", "tfidf_lr", "doc2vec_lr"]

DEFAULT_DB_PATH = "/Volumes/Eregion/bluex-data/committee/committee.db"
DEFAULT_STORE_PATH = "/Volumes/Eregion/bluex-data/default.store"
DEFAULT_OUT_DIR = "/Volumes/Eregion/bluex-data/committee"

DEFAULT_N_PER_STRATUM = {
    "mean_full_top_0.1": 25,
    "tox_top_1": 25,
    "tfidf_top_1": 25,
    "d2v_top_1": 25,
    "spread_full_top_1": 25,
    "tox_missing": 15,
    "mid": 15,
    "bottom": 15,
}

# A bare mean_pct/spread_pct (not mean_pct_full/spread_pct_full) must never
# appear in a stratum definition or SQL predicate -- see module docstring.
_BARE_MEAN_OR_SPREAD_PCT = re.compile(r"(?<!_full)\b(mean_pct|spread_pct)\b(?!_full)")


def now_iso():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def ro_uri(path):
    """Read-only SQLite URI. Deliberately NOT immutable=1 (see prior tools'
    module docstrings in this project -- WAL-blind, has silently returned
    zero rows on a populated store elsewhere)."""
    return "file:" + os.path.abspath(path) + "?mode=ro"


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# --------------------------------------------------------------------------
# Threshold computation
# --------------------------------------------------------------------------

def percentile(conn, column, q):
    """q in [0, 100]. Linear-interpolation percentile over the non-NULL
    values of `column` in the scores table. Returns None if there are no
    non-NULL values (reported honestly by callers, never faked as 0)."""
    import numpy as np
    rows = conn.execute("SELECT %s FROM scores WHERE %s IS NOT NULL" % (column, column)).fetchall()
    values = [r[0] for r in rows]
    if not values:
        return None
    return float(np.percentile(np.array(values, dtype=float), q))


def compute_thresholds(conn):
    """All percentile thresholds the eight strata are built from, computed
    once from the corpus and returned so they can be substituted verbatim
    into each stratum's `definition` string."""
    return {
        "mean_full_p999": percentile(conn, "mean_pct_full", 99.9),
        "mean_full_p99": percentile(conn, "mean_pct_full", 99.0),
        "mean_full_p25": percentile(conn, "mean_pct_full", 25.0),
        "tox_p99": percentile(conn, "tox_pct", 99.0),
        "tfidf_p99": percentile(conn, "tfidf_pct", 99.0),
        "d2v_p99": percentile(conn, "d2v_pct", 99.0),
        "spread_full_p99": percentile(conn, "spread_pct_full", 99.0),
    }


# --------------------------------------------------------------------------
# Stratum specs
# --------------------------------------------------------------------------

def validate_stratum_definition(stratum_id, definition_or_sql):
    """Refuses (raises ValueError) if a bare mean_pct/spread_pct (as opposed
    to mean_pct_full/spread_pct_full) appears -- the measured reason
    mean_pct is unusable for stratification (score_committee.py's
    MEAN_PCT_CAVEAT / the 70.4% missing-member skew)."""
    if _BARE_MEAN_OR_SPREAD_PCT.search(definition_or_sql):
        raise ValueError(
            "stratum %r must not be defined on bare mean_pct/spread_pct "
            "(variable-membership, not comparable across posts -- use "
            "mean_pct_full/spread_pct_full instead): %r" % (stratum_id, definition_or_sql)
        )
    return True


def build_strata_specs(thresholds):
    """Returns the eight stratum specs: id, definition (human-readable,
    verbatim thresholds substituted), sql_where (the SQL predicate used
    against committee.db's `scores` table), default_n.
    """

    def fmt(x):
        return "%.4f" % x if x is not None else "NULL"

    specs = [
        {
            "id": "mean_full_top_0.1",
            "definition": "n_members=3 AND mean_pct_full >= %s" % fmt(thresholds["mean_full_p999"]),
            "sql_where": "n_members = 3 AND mean_pct_full >= %s" % fmt(thresholds["mean_full_p999"]),
            "default_n": DEFAULT_N_PER_STRATUM["mean_full_top_0.1"],
        },
        {
            "id": "tox_top_1",
            "definition": "tox_pct >= %s" % fmt(thresholds["tox_p99"]),
            "sql_where": "tox_pct >= %s" % fmt(thresholds["tox_p99"]),
            "default_n": DEFAULT_N_PER_STRATUM["tox_top_1"],
        },
        {
            "id": "tfidf_top_1",
            "definition": "tfidf_pct >= %s" % fmt(thresholds["tfidf_p99"]),
            "sql_where": "tfidf_pct >= %s" % fmt(thresholds["tfidf_p99"]),
            "default_n": DEFAULT_N_PER_STRATUM["tfidf_top_1"],
        },
        {
            "id": "d2v_top_1",
            "definition": "d2v_pct >= %s" % fmt(thresholds["d2v_p99"]),
            "sql_where": "d2v_pct >= %s" % fmt(thresholds["d2v_p99"]),
            "default_n": DEFAULT_N_PER_STRATUM["d2v_top_1"],
        },
        {
            "id": "spread_full_top_1",
            "definition": "n_members=3 AND spread_pct_full >= %s" % fmt(thresholds["spread_full_p99"]),
            "sql_where": "n_members = 3 AND spread_pct_full >= %s" % fmt(thresholds["spread_full_p99"]),
            "default_n": DEFAULT_N_PER_STRATUM["spread_full_top_1"],
        },
        {
            "id": "tox_missing",
            "definition": "tox_pct IS NULL",
            "sql_where": "tox_pct IS NULL",
            "default_n": DEFAULT_N_PER_STRATUM["tox_missing"],
        },
        {
            "id": "mid",
            "definition": "mean_pct_full BETWEEN %s AND %s" % (
                fmt(thresholds["mean_full_p25"]), fmt(thresholds["mean_full_p99"])),
            "sql_where": "mean_pct_full BETWEEN %s AND %s" % (
                fmt(thresholds["mean_full_p25"]), fmt(thresholds["mean_full_p99"])),
            "default_n": DEFAULT_N_PER_STRATUM["mid"],
        },
        {
            "id": "bottom",
            "definition": "mean_pct_full < %s" % fmt(thresholds["mean_full_p25"]),
            "sql_where": "mean_pct_full < %s" % fmt(thresholds["mean_full_p25"]),
            "default_n": DEFAULT_N_PER_STRATUM["bottom"],
        },
    ]
    for s in specs:
        validate_stratum_definition(s["id"], s["definition"])
        validate_stratum_definition(s["id"], s["sql_where"])
    return specs


# --------------------------------------------------------------------------
# Population / candidate pool
# --------------------------------------------------------------------------

def population_size(conn, sql_where):
    row = conn.execute("SELECT COUNT(*) FROM scores WHERE %s" % sql_where).fetchone()
    return row[0]


def candidate_uris(conn, sql_where):
    """Every URI matching the predicate, in stable (uri-sorted) order so
    seeded sampling is reproducible regardless of SQLite's row order."""
    rows = conn.execute("SELECT uri FROM scores WHERE %s" % sql_where).fetchall()
    return sorted(r[0] for r in rows)


# --------------------------------------------------------------------------
# Exclusion of already-labelled URIs
# --------------------------------------------------------------------------

def load_exclude_file(path):
    """Accepts either a JSON array of URI strings, or a plain-text file
    with one URI per line (blank lines ignored)."""
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()
    stripped = content.strip()
    if stripped.startswith("["):
        data = json.loads(stripped)
        return {str(u) for u in data}
    return {line.strip() for line in content.splitlines() if line.strip()}


def read_labelled_uris_from_store(store_path):
    """ISOLATED, READ-ONLY: returns the set of URIs (at:// strings) of
    every post carrying a human annotation. Reads ZANNOTATION.ZPOST (join
    key) and ZANNOTATION.ZSTAGE (filter, not a label value) plus
    ZPOST.ZURI ONLY -- no other column of ZANNOTATION is read here (in
    particular, none of the columns that carry the actual human judgement),
    and none may be added to this function; test_build_frame.py greps this
    function's own source for those column names and fails the build if
    any appear. The store is opened strictly read-only; this function
    never writes to it.
    """
    conn = sqlite3.connect(ro_uri(store_path), uri=True)
    try:
        cur = conn.execute(
            "SELECT DISTINCT ZPOST.ZURI FROM ZANNOTATION "
            "JOIN ZPOST ON ZANNOTATION.ZPOST = ZPOST.Z_PK "
            "WHERE ZANNOTATION.ZSTAGE = 'human'"
        )
        return {row[0] for row in cur.fetchall() if row[0] is not None}
    finally:
        conn.close()


# --------------------------------------------------------------------------
# Seeded sampling
# --------------------------------------------------------------------------

def sample_stratum(pool_uris_sorted, n, seed, stratum_id):
    """Deterministic seeded sample: a fresh RNG derived from (seed,
    stratum_id) so re-running with the same seed reproduces the same draw
    per stratum regardless of other strata's sizes, and different seeds
    diverge. `pool_uris_sorted` must already be sorted (stable input) --
    the RNG is the only source of randomness."""
    rng = random.Random("%s::%s" % (seed, stratum_id))
    if n >= len(pool_uris_sorted):
        return list(pool_uris_sorted)
    return rng.sample(pool_uris_sorted, n)


# --------------------------------------------------------------------------
# Frame assembly
# --------------------------------------------------------------------------

def build_frame(db_path, seed, n_per_stratum, exclude_uris, store_path=None):
    """Builds the full frame dict (not yet written to disk). `n_per_stratum`
    overrides DEFAULT_N_PER_STRATUM per-id; missing ids fall back to the
    default. `exclude_uris` is a set of URIs to never sample (already
    labelled)."""
    conn = sqlite3.connect(db_path)
    try:
        thresholds = compute_thresholds(conn)
        specs = build_strata_specs(thresholds)

        total_row = conn.execute("SELECT COUNT(*) FROM scores").fetchone()
        population_total = total_row[0]

        strata_out = []
        for spec in specs:
            n = n_per_stratum.get(spec["id"], spec["default_n"])
            pop = population_size(conn, spec["sql_where"])
            pool = candidate_uris(conn, spec["sql_where"])
            pool = [u for u in pool if u not in exclude_uris]
            sampled = sample_stratum(pool, n, seed, spec["id"])
            strata_out.append({
                "id": spec["id"],
                "definition": spec["definition"],
                "population_size": pop,
                "uris": sampled,
            })
    finally:
        conn.close()

    db_sha = sha256_file(db_path) if os.path.exists(db_path) else None

    frame = {
        "frame_kind": "stratified",
        "created_at": now_iso(),
        "committee": {
            "db_sha256": db_sha,
            "members": list(COMMITTEE_MEMBERS),
        },
        "population_total": population_total,
        "seed": seed,
        "strata": strata_out,
    }
    return frame


def render_summary(frame):
    lines = ["stratified frame -- population_total=%d, seed=%s" %
             (frame["population_total"], frame["seed"])]
    lines.append("%-20s %12s %8s %10s" % ("stratum", "population", "n", "fraction"))
    for s in frame["strata"]:
        pop = s["population_size"]
        n = len(s["uris"])
        frac = (n / pop) if pop else 0.0
        lines.append("%-20s %12d %8d %9.4f%%" % (s["id"], pop, n, frac * 100.0))
    return "\n".join(lines)


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def parse_n_per_stratum_args(pairs):
    """pairs: list of 'stratum_id=n' strings from --n-per-stratum, repeatable."""
    out = {}
    for p in pairs or []:
        if "=" not in p:
            raise argparse.ArgumentTypeError("expected stratum_id=n, got %r" % p)
        sid, n = p.split("=", 1)
        out[sid] = int(n)
    return out


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--db", default=DEFAULT_DB_PATH)
    parser.add_argument("--store", default=DEFAULT_STORE_PATH,
                         help="only read if --exclude-file is not given")
    parser.add_argument("--out", default=None,
                         help="output frame file path; default is a timestamped "
                              "file under %s" % DEFAULT_OUT_DIR)
    parser.add_argument("--seed", type=int, required=True)
    parser.add_argument("--exclude-file", default=None)
    parser.add_argument("--n-per-stratum", action="append", default=[],
                         help="stratum_id=n, repeatable")
    args = parser.parse_args(argv)

    n_per_stratum = parse_n_per_stratum_args(args.n_per_stratum)

    if args.exclude_file:
        exclude_uris = load_exclude_file(args.exclude_file)
        exclude_source = args.exclude_file
    elif os.path.exists(args.store):
        exclude_uris = read_labelled_uris_from_store(args.store)
        exclude_source = "store:%s (URIs only, no label values read)" % args.store
    else:
        exclude_uris = set()
        exclude_source = "none"

    frame = build_frame(args.db, args.seed, n_per_stratum, exclude_uris, store_path=args.store)
    frame["provenance"] = {
        "exclude_source": exclude_source,
        "n_excluded_uris": len(exclude_uris),
    }

    out_path = args.out or os.path.join(
        DEFAULT_OUT_DIR, "frame-%s.json" % now_iso().replace(":", "").replace("-", ""))
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(frame, f, indent=2, sort_keys=False)
        f.write("\n")

    print(render_summary(frame))
    print("wrote %s" % out_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
