#!/usr/bin/env python3
"""Stage 0 base-rate report: the number that can falsify this project's premise.

WHY THIS EXISTS
----------------
The project's whole hate-classification architecture (an abstention-heavy
pipeline tuned to a tau=0.9 operating point: 5% of neutral content classified,
88% recall on hate) is only worth building if hate is rare enough that the
false-positive/true-positive ratio it implies is tolerable. Nobody has
measured that rate on this corpus from an unbiased sample — every count so
far (moderator labels, LLM annotations) is drawn from a filtered or
self-selected pool. Stage 0 of the labelling plan closes that gap: a human
labels a UNIFORM RANDOM sample of ~300 posts, and this script turns those
labels into a prevalence estimate with a confidence interval, plus the
FP/TP ratio that estimate implies at the tau=0.9 operating point. If that
ratio is intolerable, the abstention architecture needs to change before any
more effort goes into it — which is why this script's exclusion rules matter
more than its features: an estimate contaminated by filtered-frame or
second-pass labels is not a base rate, it is theater.

WHAT THIS IS NOT
-----------------
  * NOT a general labelling-progress dashboard. It reports exactly one
    number (prevalence + CI) and the counts needed to audit it.
  * NOT a classifier evaluation. It never touches model-produced annotations
    (`ZSTAGE` != 'human') and makes no claim about recall/precision of any
    detector.
  * NOT tolerant of scope creep in its sample. Only annotations whose batch's
    sampling frame has `kind == "uniformRandom"` AND whose batch's
    `passNumber == 1` enter the estimate. Every other human label found is
    counted and listed with its exclusion reason, never silently dropped —
    the sampling-frame discipline made machine-checkable.
  * NOT a tool that manufactures a result from no data. Zero eligible labels
    is reported as a clear, non-zero-exit failure, never as "p = 0%".

SCHEMA FACTS (verified empirically against the live store on 2026-08-15;
do not re-derive without re-checking, the app/store may have moved since)
-----------------------------------------------------------------------------
  * `ZANNOTATION` carries `ZSTAGE`, `ZSPEECHCLASS` today. As of 2026-08-15
    the live store on disk (`/Volumes/Eregion/bluex-data/default.store`) does
    NOT yet have the `ZANNOTATORID` / `ZBATCHID` / `ZTIMETODECIDESECONDS` /
    `ZPASSNUMBER` columns, and has NO `ZLABELBATCH` table at all — even
    though `LabelBatch` and the new `Annotation` fields are committed in
    `BlueX/Data/` (see `LabelBatch.swift`, `Annotation.swift`,
    `BlueXSchema.swift`). SwiftData applies a lightweight migration only when
    an app/CLI process opens the store; nothing has opened this store with
    the new schema yet. This script therefore DISCOVERS columns/tables at
    runtime via `PRAGMA table_info` / `sqlite_master` rather than assuming
    them, and reports a clear "schema not migrated yet" condition instead of
    crashing on `no such column`.
  * `ZLABELBATCH.ZFRAMEJSON` is a JSON blob whose `kind` key is
    `"uniformRandom"` or `"filtered"` (contract documented on
    `LabelBatch.frameJSON` in Swift). Only `kind` is read here; `dateFrom`/
    `dateTo` inside it are Core Data epoch (seconds since 2001-01-01) but
    this script never needs them.
  * UUID join: `Annotation.batchID` (Swift `UUID?`) must match
    `LabelBatch.id` (Swift `UUID`) stored as `ZLABELBATCH.ZID`. This script
    has NOT been able to observe empirically how SwiftData encodes a bare
    `UUID` column in this store (no existing table in the live schema has one
    to sample, and running the app to find out is out of scope / against
    this task's constraints). `normalize_uuid()` below therefore accepts
    EITHER a 16-byte BLOB or a TEXT value (with or without dashes) and
    normalizes both to a canonical lowercase-with-dashes string, so the join
    works whichever encoding SwiftData turns out to use. Tests exercise both.

SAFETY
------
The store is opened strictly read-only via `file:...?mode=ro`. Never
`?immutable=1` (WAL-blind; has returned zero rows on a populated store). A
corpus scrape (nightly, 03:31) may be writing to the store while this runs;
that is expected, not an error. This script never writes to the store.

Output lands under `/Volumes/Eregion/bluex-labelling/` (external volume, a
new directory distinct from the live store's own `/Volumes/Eregion/bluex-data`).
"""
import argparse
import datetime as dt
import json
import math
import os
import sqlite3
import sys
import tempfile
import uuid as uuid_module

DEFAULT_STORE_DIR = os.environ.get("BLUEX_STORE_DIR", "/Volumes/Eregion/bluex-data")
DEFAULT_STORE_FILENAME = "default.store"
DEFAULT_OUT_DIR = "/Volumes/Eregion/bluex-labelling"

SPEECH_CLASSES = ("hate", "counter", "neutral")

# The prior work's tau=0.9 operating point (see proposal): at that threshold,
# 5% of neutral content gets classified, and recall on hate is 88%.
OPERATING_POINT_NEUTRAL_CLASSIFIED_RATE = 0.05
OPERATING_POINT_HATE_RECALL = 0.88


class SchemaNotReady(Exception):
    """The store is missing a table/column this script needs. Not a bug in
    this script -- it means the schema migration for the labelling feature
    has not been applied to this store yet (see module docstring)."""


# --------------------------------------------------------------------------
# Pure math -- Wilson CI and the FP/TP decision rule
# --------------------------------------------------------------------------

def wilson_ci(k: int, n: int, z: float = 1.96) -> tuple:
    """Wilson score interval for a binomial proportion. Verbatim from the
    Stage 0 spec (task-6-brief.md) -- do not "simplify" the algebra."""
    if n == 0:
        return (0.0, 0.0)
    p = k / n
    denom = 1 + z * z / n
    centre = (p + z * z / (2 * n)) / denom
    half = (z / denom) * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))
    return (max(0.0, centre - half), min(1.0, centre + half))


def fp_per_tp(p, classified_rate=OPERATING_POINT_NEUTRAL_CLASSIFIED_RATE,
              recall=OPERATING_POINT_HATE_RECALL):
    """False-positives-per-true-positive implied by prevalence `p` at the
    tau=0.9 operating point: FP/TP = (classified_rate * (1-p)) / (recall * p).

    Returns None when p <= 0 -- the ratio is undefined (division by zero)
    when there is no hate to have a true positive about.
    """
    if p is None or p <= 0:
        return None
    return (classified_rate * (1 - p)) / (recall * p)


# --------------------------------------------------------------------------
# Store access
# --------------------------------------------------------------------------

def ro_uri(path):
    """Read-only SQLite URI. Deliberately NOT immutable=1 (see module docstring)."""
    return "file:" + os.path.abspath(path) + "?mode=ro"


def now_iso():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def default_store_path(store_dir):
    return os.path.join(store_dir, DEFAULT_STORE_FILENAME)


def table_exists(conn, name):
    row = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name=?", (name,)
    ).fetchone()
    return row is not None


def column_map(conn, table):
    """Uppercased-column-name -> actual stored name, for a table that exists.
    Empty dict if the table itself doesn't exist."""
    if not table_exists(conn, table):
        return {}
    rows = conn.execute("PRAGMA table_info(%s)" % table).fetchall()
    return {row[1].upper(): row[1] for row in rows}


def normalize_uuid(value):
    """Normalize a UUID stored as either a 16-byte BLOB or a TEXT value
    (dashed or bare hex) to a canonical lowercase-dashed string. Returns
    None if `value` cannot be interpreted as a UUID (never raises -- a
    corrupt/foreign value must not crash the reader, it becomes an
    unparseable-batch-id exclusion instead)."""
    if value is None:
        return None
    if isinstance(value, (bytes, bytearray)):
        raw = bytes(value)
        if len(raw) == 16:
            return str(uuid_module.UUID(bytes=raw))
        try:
            return str(uuid_module.UUID(raw.decode("ascii")))
        except (UnicodeDecodeError, ValueError):
            return None
    if isinstance(value, str):
        try:
            return str(uuid_module.UUID(value))
        except ValueError:
            return None
    return None


def fetch_human_annotations(conn):
    """Return (rows, flags). Each row is a dict: pk, speech_class,
    batch_id_raw (None if column absent or value is NULL),
    annotation_pass_number (None if column absent or value is NULL).

    `flags` records which optional columns were actually found, so the
    caller can report a "schema not migrated yet" condition distinctly from
    "zero human labels".
    """
    cols = column_map(conn, "ZANNOTATION")
    if not cols:
        raise SchemaNotReady("ZANNOTATION table not found in this store")
    if "ZSPEECHCLASS" not in cols or "ZSTAGE" not in cols:
        raise SchemaNotReady(
            "ZANNOTATION is missing ZSPEECHCLASS/ZSTAGE (found: %s)" % sorted(cols)
        )

    has_batch_id = "ZBATCHID" in cols
    has_pass_number = "ZPASSNUMBER" in cols

    select_cols = ["Z_PK", cols["ZSPEECHCLASS"]]
    if has_batch_id:
        select_cols.append(cols["ZBATCHID"])
    if has_pass_number:
        select_cols.append(cols["ZPASSNUMBER"])

    query = "SELECT %s FROM ZANNOTATION WHERE %s = 'human'" % (
        ", ".join(select_cols), cols["ZSTAGE"],
    )
    rows = conn.execute(query).fetchall()

    results = []
    for row in rows:
        i = 2
        batch_id_raw = None
        annotation_pass_number = None
        if has_batch_id:
            batch_id_raw = row[i]
            i += 1
        if has_pass_number:
            annotation_pass_number = row[i]
            i += 1
        results.append({
            "pk": row[0],
            "speech_class": row[1],
            "batch_id_raw": batch_id_raw,
            "annotation_pass_number": annotation_pass_number,
        })

    flags = {
        "has_batch_id_column": has_batch_id,
        "has_pass_number_column": has_pass_number,
    }
    return results, flags


def fetch_batches(conn):
    """Return (batches, available). `batches` maps normalized UUID string ->
    {"kind": str|None, "pass_number": int|None}. `available` is False when
    ZLABELBATCH doesn't exist, or exists without the columns this script
    needs -- either way every human label becomes an exclusion, not a crash.
    """
    cols = column_map(conn, "ZLABELBATCH")
    needed = ("ZID", "ZFRAMEJSON", "ZPASSNUMBER")
    if not cols or not all(c in cols for c in needed):
        return {}, False

    rows = conn.execute(
        "SELECT %s, %s, %s FROM ZLABELBATCH" % (cols["ZID"], cols["ZFRAMEJSON"], cols["ZPASSNUMBER"])
    ).fetchall()

    batches = {}
    for zid_raw, frame_json, pass_number in rows:
        norm = normalize_uuid(zid_raw)
        if norm is None:
            continue
        kind = None
        if frame_json:
            try:
                frame = json.loads(frame_json)
                kind = frame.get("kind") if isinstance(frame, dict) else None
            except (ValueError, TypeError):
                kind = None
        batches[norm] = {"kind": kind, "pass_number": pass_number}
    return batches, True


# --------------------------------------------------------------------------
# Classification: which labels enter the estimate, which are excluded (why)
# --------------------------------------------------------------------------

def classify_label(annotation, batches, batches_available):
    """Return (bucket, reason, speech_class). bucket is "included" or
    "excluded"; reason is None for included labels, else a short machine
    stable string explaining the exclusion."""
    speech_class = annotation["speech_class"]
    batch_id_raw = annotation["batch_id_raw"]

    if not batches_available:
        return ("excluded", "no_label_batch_table", speech_class)
    if batch_id_raw is None:
        return ("excluded", "no_batch_id", speech_class)

    norm = normalize_uuid(batch_id_raw)
    if norm is None:
        return ("excluded", "unparseable_batch_id", speech_class)

    batch = batches.get(norm)
    if batch is None:
        return ("excluded", "orphan_no_matching_batch", speech_class)

    kind = batch["kind"]
    if kind != "uniformRandom":
        return ("excluded", "non_uniform_frame:%s" % (kind or "undecodable"), speech_class)

    if batch["pass_number"] != 1:
        return ("excluded", "pass_%s" % batch["pass_number"], speech_class)

    return ("included", None, speech_class)


def build_report(annotations, batches, batches_available):
    """Turn classified labels into the counts + exclusion breakdown the
    report needs. Returns a dict; does no printing, no math beyond counting."""
    included_by_class = {c: 0 for c in SPEECH_CLASSES}
    included_other = 0
    excluded_by_reason = {}
    excluded_total = 0

    for annotation in annotations:
        bucket, reason, speech_class = classify_label(annotation, batches, batches_available)
        if bucket == "included":
            if speech_class in included_by_class:
                included_by_class[speech_class] += 1
            else:
                included_other += 1
        else:
            excluded_total += 1
            excluded_by_reason[reason] = excluded_by_reason.get(reason, 0) + 1

    n = sum(included_by_class.values()) + included_other
    return {
        "n_included": n,
        "included_by_class": included_by_class,
        "included_other_class": included_other,
        "n_excluded": excluded_total,
        "excluded_by_reason": excluded_by_reason,
    }


# --------------------------------------------------------------------------
# Output plumbing
# --------------------------------------------------------------------------

def write_atomic(path, write_body):
    directory = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=directory, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            write_body(handle)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


README_TEXT = """# BlueX Stage 0 base-rate reports

This directory holds timestamped Stage 0 base-rate reports produced by
`tools/labelling/base_rate.py`. Each report answers exactly one question:
among human labels drawn from a UNIFORM RANDOM sample (pass 1 only), what
fraction is hate, with a 95%% Wilson confidence interval, and what does that
prevalence imply for the false-positives-per-true-positive ratio at the
prior work's tau=0.9 operating point (5%% of neutral content classified, 88%%
recall on hate)?

## The exclusion rule that makes this honest

Only human labels (`ZANNOTATION` where `ZSTAGE='human'`) whose batch
(`ZLABELBATCH`, joined by `batchID`) has a sampling frame with
`kind == "uniformRandom"` AND `passNumber == 1` enter the estimate. Every
other human label found -- filtered-frame batches, second-pass batches,
labels with no resolvable batch at all -- is counted and listed under
`excluded_by_reason` in the report, never silently dropped. A base rate
computed from a filtered or self-selected sample is not a base rate; the
whole point of this script is to make that discipline machine-checkable
instead of a promise.

## Reading `run_status`

`"ok"` means at least one uniform-random pass-1 label was found and the
prevalence figure is meaningful. `"no_data"` means zero such labels were
found (e.g. before Stage 0 labelling has happened, or if the store's schema
for `ZLABELBATCH`/the new `Annotation` columns hasn't been migrated onto
this store yet -- see `schema_notes` in the report). A base rate is never
reported as if it were real when `run_status` is `"no_data"`; the CLI also
exits non-zero in that case.

## How it was generated

```
python3 tools/labelling/base_rate.py [--store PATH] [--out DIR]
```

The store is opened strictly read-only (`file:...?mode=ro`, never
`?immutable=1`) so it is safe to run while a corpus scrape is writing to it.
"""


def write_readme(out_dir):
    path = os.path.join(out_dir, "README.md")
    write_atomic(path, lambda handle: handle.write(README_TEXT))
    return path


def format_pct(x):
    return "%.2f%%" % (x * 100.0)


def format_fp_tp(value):
    if value is None:
        return "undefined (no hate observed)"
    return "%.2f" % value


def render_report_text(report, store_path):
    lines = []
    lines.append("BlueX Stage 0 base-rate report")
    lines.append("store: %s" % store_path)
    lines.append("generated_at: %s" % report["generated_at"])
    lines.append("")
    lines.append("Schema notes:")
    for note in report["schema_notes"]:
        lines.append("  - %s" % note)
    lines.append("")

    n = report["n_included"]
    by_class = report["included_by_class"]
    lines.append("Eligible sample (uniformRandom, pass 1 only):")
    lines.append("  n = %d" % n)
    lines.append("  hate    = %d" % by_class.get("hate", 0))
    lines.append("  counter = %d" % by_class.get("counter", 0))
    lines.append("  neutral = %d" % by_class.get("neutral", 0))
    if report["included_other_class"]:
        lines.append("  other (unrecognized speechClass) = %d" % report["included_other_class"])
    lines.append("")
    lines.append("Excluded (counted, not dropped): %d" % report["n_excluded"])
    for reason, count in sorted(report["excluded_by_reason"].items()):
        lines.append("  - %s: %d" % (reason, count))
    lines.append("")

    if report["run_status"] != "ok":
        lines.append("RESULT: no base rate computed (%s)." % report["run_status"])
        lines.append(report["message"])
        return "\n".join(lines)

    k = by_class.get("hate", 0)
    p_hat = k / n
    lo, hi = report["wilson_ci"]
    lines.append("Hate prevalence: %s (n=%d, k=%d)" % (format_pct(p_hat), n, k))
    lines.append("95%% Wilson CI: [%s, %s]" % (format_pct(lo), format_pct(hi)))
    lines.append("")
    lines.append(
        "Decision rule at tau=0.9 (prior work's operating point: 5%% of neutral "
        "classified, 88%% recall on hate):"
    )
    lines.append("  FP/TP formula: (0.05 * (1-p)) / (0.88 * p)")
    lines.append("  at point estimate p=%s: FP/TP = %s" % (format_pct(p_hat), format_fp_tp(report["fp_per_tp_point"])))
    lines.append("  at CI lower bound p=%s: FP/TP = %s" % (format_pct(lo), format_fp_tp(report["fp_per_tp_lower"])))
    lines.append("  at CI upper bound p=%s: FP/TP = %s" % (format_pct(hi), format_fp_tp(report["fp_per_tp_upper"])))
    lines.append("")
    lines.append(
        "What this means for the abstention architecture: this many false "
        "positives are implied per true positive the classifier catches at "
        "tau=0.9, given the estimated (and CI-bounded) hate prevalence -- if "
        "that ratio is too high across the CI to be workable, the tau=0.9 "
        "operating point (or the abstention architecture built around it) "
        "needs to change before further investment, not the estimate."
    )
    return "\n".join(lines)


# --------------------------------------------------------------------------
# Top-level run
# --------------------------------------------------------------------------

def compute_report(store_path):
    """Open the store read-only, compute the full report dict. Raises
    SchemaNotReady if ZANNOTATION itself is unusable (missing/malformed)."""
    conn = sqlite3.connect(ro_uri(store_path), uri=True)
    try:
        annotations, flags = fetch_human_annotations(conn)
        batches, batches_available = fetch_batches(conn)
    finally:
        conn.close()

    schema_notes = []
    if not flags["has_batch_id_column"]:
        schema_notes.append(
            "ZANNOTATION has no batchID column yet -- the Task 2 schema "
            "migration has not been applied to this store (no process has "
            "opened it with the new SwiftData model). Every human label is "
            "therefore excluded as no_batch_id."
        )
    if not flags["has_pass_number_column"]:
        schema_notes.append(
            "ZANNOTATION has no passNumber column yet on this annotation "
            "record (informational only -- the batch's own passNumber is "
            "what the exclusion rule uses)."
        )
    if not batches_available:
        schema_notes.append(
            "ZLABELBATCH table not found (or missing expected columns) in "
            "this store -- every human label is excluded as "
            "no_label_batch_table until batches have been drawn and this "
            "store has picked up that schema."
        )
    if not schema_notes:
        schema_notes.append("ZANNOTATION/ZLABELBATCH schema found as expected; no migration gaps detected.")

    breakdown = build_report(annotations, batches, batches_available)

    n = breakdown["n_included"]
    report = {
        "generated_at": now_iso(),
        "store": os.path.abspath(store_path),
        "schema_notes": schema_notes,
        "n_included": n,
        "included_by_class": breakdown["included_by_class"],
        "included_other_class": breakdown["included_other_class"],
        "n_excluded": breakdown["n_excluded"],
        "excluded_by_reason": breakdown["excluded_by_reason"],
    }

    if n == 0:
        report["run_status"] = "no_data"
        report["message"] = (
            "Zero human labels drawn from a uniformRandom, pass-1 batch were "
            "found. This is expected before Stage 0 labelling has happened "
            "(or before the store's labelling schema has been migrated -- "
            "see schema_notes above). No base rate can honestly be reported "
            "from n=0; run Stage 0 labelling in the app, then re-run this "
            "script."
        )
        return report

    k = breakdown["included_by_class"].get("hate", 0)
    p_hat = k / n
    lo, hi = wilson_ci(k, n)
    report.update({
        "run_status": "ok",
        "hate_count": k,
        "hate_prevalence": p_hat,
        "wilson_ci": (lo, hi),
        "fp_per_tp_point": fp_per_tp(p_hat),
        "fp_per_tp_lower": fp_per_tp(lo),
        "fp_per_tp_upper": fp_per_tp(hi),
    })
    return report


def run(store_path, out_dir):
    report = compute_report(store_path)

    os.makedirs(out_dir, exist_ok=True)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H%M%SZ")
    json_path = os.path.join(out_dir, "base-rate-%s.json" % stamp)

    def write_json(handle):
        json.dump(report, handle, ensure_ascii=False, indent=2)
        handle.write("\n")

    write_atomic(json_path, write_json)
    write_readme(out_dir)

    text = render_report_text(report, store_path)
    return json_path, report, text


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Stage 0 base-rate report: hate prevalence + Wilson CI "
                     "from uniform-random, pass-1 human labels only."
    )
    parser.add_argument("--store", default=None,
                         help="path to default.store; defaults to $BLUEX_STORE_DIR "
                              "then /Volumes/Eregion/bluex-data")
    parser.add_argument("--out", default=DEFAULT_OUT_DIR)
    args = parser.parse_args(argv)

    store_dir = args.store or DEFAULT_STORE_DIR
    store_path = store_dir if store_dir.endswith(".store") else default_store_path(store_dir)

    if not os.path.exists(store_path):
        parser.error("store not found: %s" % store_path)

    try:
        json_path, report, text = run(store_path, args.out)
    except SchemaNotReady as exc:
        print("ERROR: %s" % exc, file=sys.stderr)
        return 1

    print(text)
    print("")
    print("wrote %s" % json_path)

    return 0 if report["run_status"] == "ok" else 1


if __name__ == "__main__":
    sys.exit(main())
