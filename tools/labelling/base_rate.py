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
import plistlib
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


def decode_string_array(value):
    """Decode a `[String]` column value (e.g. `LabelBatch.skippedURIs`) into a
    Python list, or `None` if it cannot be interpreted at all -- never raises,
    mirroring `normalize_uuid`'s "corrupt/foreign value must not crash the
    reader" discipline.

    `None` in the store means "empty array" (the empty case is also SwiftData's
    default for `skippedURIs`), so `None` in -> `[]` out, distinct from a value
    present but undecodable, which returns `None` so the caller can tell the
    difference between "no skips" and "could not read this".

    This tool has NOT been able to observe empirically how SwiftData encodes a
    bare `[String]` column in this store (same caveat as `normalize_uuid` for
    UUID columns). Two encodings are tried: UTF-8 JSON (a plain JSON array of
    strings -- the most likely TEXT-column form) and, for BLOB values that
    aren't valid JSON, a binary property list (the array form Core Data's
    transformable attributes typically use).
    """
    if value is None:
        return []
    if isinstance(value, str):
        try:
            decoded = json.loads(value)
        except (ValueError, TypeError):
            return None
        return decoded if isinstance(decoded, list) else None
    if isinstance(value, (bytes, bytearray)):
        raw = bytes(value)
        try:
            decoded = json.loads(raw.decode("utf-8"))
            return decoded if isinstance(decoded, list) else None
        except (ValueError, TypeError, UnicodeDecodeError):
            pass
        try:
            decoded = plistlib.loads(raw)
            return list(decoded) if isinstance(decoded, list) else None
        except Exception:
            return None
    return None


def fetch_human_annotations(conn):
    """Return (rows, flags). Each row is a dict: pk, speech_class,
    batch_id_raw (None if column absent or value is NULL),
    annotation_pass_number (None if column absent or value is NULL),
    definition_version (int -- which `LabellingDefinitions.version` this label
    was judged against; `0` when the column is absent OR the stored value is
    NULL, mirroring the Swift `Annotation.definitionVersion` default so a
    pre-existing row is always treated as a v0 label, never silently folded
    into whatever the current version happens to be).

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
    has_definition_version = "ZDEFINITIONVERSION" in cols

    select_cols = ["Z_PK", cols["ZSPEECHCLASS"]]
    if has_batch_id:
        select_cols.append(cols["ZBATCHID"])
    if has_pass_number:
        select_cols.append(cols["ZPASSNUMBER"])
    if has_definition_version:
        select_cols.append(cols["ZDEFINITIONVERSION"])

    query = "SELECT %s FROM ZANNOTATION WHERE %s = 'human'" % (
        ", ".join(select_cols), cols["ZSTAGE"],
    )
    rows = conn.execute(query).fetchall()

    results = []
    for row in rows:
        i = 2
        batch_id_raw = None
        annotation_pass_number = None
        definition_version = 0
        if has_batch_id:
            batch_id_raw = row[i]
            i += 1
        if has_pass_number:
            annotation_pass_number = row[i]
            i += 1
        if has_definition_version:
            raw_version = row[i]
            definition_version = raw_version if raw_version is not None else 0
            i += 1
        results.append({
            "pk": row[0],
            "speech_class": row[1],
            "batch_id_raw": batch_id_raw,
            "annotation_pass_number": annotation_pass_number,
            "definition_version": definition_version,
        })

    flags = {
        "has_batch_id_column": has_batch_id,
        "has_pass_number_column": has_pass_number,
        "has_definition_version_column": has_definition_version,
    }
    return results, flags


def fetch_batches(conn):
    """Return (batches, meta). `batches` maps normalized UUID string ->
    {"kind": str|None, "pass_number": int|None, "skipped_count": int|None,
    "stratum_id": str|None, "population_size": int|None}. The last two are
    only ever non-None for a `kind == "stratified"` batch -- pulled straight
    from the frame JSON's `stratumID`/`populationSize` keys (the exact Swift
    property names `SamplingFrame` encodes to; this script never renames or
    snake_cases them).
    `skipped_count` is `None` when `ZSKIPPEDURIS` is absent from the store
    (pre-migration) or its value couldn't be decoded for that row -- callers
    must not treat `None` as zero.

    `meta` is a dict with a `"status"` key distinguishing the two distinct
    ways this can be unusable -- collapsing them was a real finding (a
    typo'd column name here, or genuine schema drift, would otherwise
    masquerade as "store not migrated yet" and send a debugger to launch
    the app pointlessly):
      - "ok": table found with all needed columns; `batches` is populated.
      - "missing_table": ZLABELBATCH does not exist at all -- the store
        has not been migrated onto the schema that declares it.
      - "missing_columns": ZLABELBATCH exists but is missing one or more
        of the columns this script needs. `meta["missing"]` lists the
        missing (expected) column names; `meta["found"]` lists the columns
        actually present, mirroring the ZANNOTATION discovery path above.
    """
    needed = ("ZID", "ZFRAMEJSON", "ZPASSNUMBER")

    if not table_exists(conn, "ZLABELBATCH"):
        return {}, {"status": "missing_table", "has_skipped_column": False}

    cols = column_map(conn, "ZLABELBATCH")
    missing = [c for c in needed if c not in cols]
    if missing:
        return {}, {"status": "missing_columns", "missing": missing, "found": sorted(cols),
                     "has_skipped_column": "ZSKIPPEDURIS" in cols}

    has_skipped_column = "ZSKIPPEDURIS" in cols
    select_cols = [cols["ZID"], cols["ZFRAMEJSON"], cols["ZPASSNUMBER"]]
    if has_skipped_column:
        select_cols.append(cols["ZSKIPPEDURIS"])

    rows = conn.execute("SELECT %s FROM ZLABELBATCH" % ", ".join(select_cols)).fetchall()

    batches = {}
    for row in rows:
        zid_raw, frame_json, pass_number = row[0], row[1], row[2]
        norm = normalize_uuid(zid_raw)
        if norm is None:
            continue
        kind = None
        stratum_id = None
        population_size = None
        if frame_json:
            try:
                frame = json.loads(frame_json)
                if isinstance(frame, dict):
                    kind = frame.get("kind")
                    stratum_id = frame.get("stratumID")
                    population_size = frame.get("populationSize")
            except (ValueError, TypeError):
                kind = None
        skipped_count = None
        if has_skipped_column:
            decoded = decode_string_array(row[3])
            skipped_count = len(decoded) if decoded is not None else None
        batches[norm] = {
            "kind": kind, "pass_number": pass_number, "skipped_count": skipped_count,
            "stratum_id": stratum_id, "population_size": population_size,
        }
    return batches, {"status": "ok", "has_skipped_column": has_skipped_column}


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
        pass_label = batch["pass_number"] if batch["pass_number"] is not None else "unknown"
        return ("excluded", "pass_%s" % pass_label, speech_class)

    return ("included", None, speech_class)


def count_skipped(batches):
    """Sum `skipped_count` over exactly the batches that are in scope for the
    estimate -- `kind == "uniformRandom"` and `pass_number == 1`, the same
    two conditions `classify_label` uses to decide inclusion. A skip is not
    an annotation, so it never appears in `annotations`/`build_report` at
    all; this is the only place skipped URIs are counted, kept deliberately
    parallel to the label-inclusion rule so "how many were skipped from the
    SAME sample the estimate is drawn from" is unambiguous.

    A batch whose `skipped_count` is `None` (column absent or that row's
    value undecodable) contributes 0 -- silently undercounting is safer here
    than crashing, but see `schema_notes` for whether that undercount is
    actually happening.
    """
    total = 0
    for batch in batches.values():
        if batch.get("kind") != "uniformRandom" or batch.get("pass_number") != 1:
            continue
        total += batch.get("skipped_count") or 0
    return total


def build_report(annotations, batches, batches_available):
    """Turn classified labels into the counts + exclusion breakdown the
    report needs. Returns a dict; does no printing, no math beyond counting.

    `by_definition_version` breaks the SAME included labels down by
    `definitionVersion` (`{version: {"included_by_class": {...},
    "included_other_class": int}}`) -- the pooled top-level counts above are
    kept for backward compatibility (e.g. the stratified estimator's uniform
    baseline) and for the common case of a single version in play, but
    `compute_report` uses `by_definition_version` as the authoritative source
    whenever more than one version is present, precisely so those pooled
    numbers are never mistaken for an estimate spanning definitions that
    disagree with each other.
    """
    included_by_class = {c: 0 for c in SPEECH_CLASSES}
    included_other = 0
    excluded_by_reason = {}
    excluded_total = 0
    by_definition_version = {}

    for annotation in annotations:
        bucket, reason, speech_class = classify_label(annotation, batches, batches_available)
        if bucket == "included":
            if speech_class in included_by_class:
                included_by_class[speech_class] += 1
            else:
                included_other += 1

            version = annotation.get("definition_version", 0)
            version_entry = by_definition_version.setdefault(
                version, {"included_by_class": {c: 0 for c in SPEECH_CLASSES}, "included_other_class": 0}
            )
            if speech_class in version_entry["included_by_class"]:
                version_entry["included_by_class"][speech_class] += 1
            else:
                version_entry["included_other_class"] += 1
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
        "by_definition_version": by_definition_version,
    }


# --------------------------------------------------------------------------
# Stratified weighted prevalence estimator (a SEPARATE analysis from the
# uniform-random one above -- see the design doc's §5: the two must never be
# pooled, and this section never touches `uniformRandom` labels for anything
# but the enrichment-factor baseline, computed via the SAME `build_report`
# uniform-only logic so it is, by construction, identical to what
# `compute_report` reports on its own.)
# --------------------------------------------------------------------------

def stratum_universe(batches):
    """stratum_id -> population_size, for every DISTINCT stratified, pass-1
    batch found -- this is the source of truth for which strata exist, so a
    stratum with population but zero labels still appears (with n=0), rather
    than only strata that happen to have at least one annotation."""
    universe = {}
    for batch in batches.values():
        if batch.get("kind") != "stratified" or batch.get("pass_number") != 1:
            continue
        stratum_id = batch.get("stratum_id")
        if not stratum_id:
            continue
        universe.setdefault(stratum_id, batch.get("population_size"))
    return universe


def classify_stratified_label(annotation, batches):
    """Mirror of `classify_label`, but for the stratified side: only
    `kind == "stratified"`, pass-1 labels are in scope. Returns
    (bucket, reason, speech_class, stratum_id)."""
    speech_class = annotation["speech_class"]
    batch_id_raw = annotation["batch_id_raw"]
    if batch_id_raw is None:
        return ("excluded", "no_batch_id", speech_class, None)
    norm = normalize_uuid(batch_id_raw)
    if norm is None:
        return ("excluded", "unparseable_batch_id", speech_class, None)
    batch = batches.get(norm)
    if batch is None:
        return ("excluded", "orphan_no_matching_batch", speech_class, None)
    kind = batch.get("kind")
    if kind != "stratified":
        return ("excluded", "non_stratified_frame:%s" % (kind or "undecodable"),
                 speech_class, None)
    if batch.get("pass_number") != 1:
        pass_label = batch.get("pass_number") if batch.get("pass_number") is not None else "unknown"
        return ("excluded", "pass_%s" % pass_label, speech_class, None)
    stratum_id = batch.get("stratum_id")
    if not stratum_id:
        return ("excluded", "missing_stratum_id", speech_class, None)
    return ("included", None, speech_class, stratum_id)


def compute_stratified_report(store_path):
    """Weighted stratified prevalence estimate p_hat = sum_h (N_h/N)*(k_h/n_h)
    over `stratified`, pass-1 human labels ONLY, plus per-stratum Wilson CIs
    and enrichment factors against the uniform-random baseline (computed via
    `compute_report`'s own `build_report`, untouched by anything here).

    A stratum with population but n_h == 0 is EXCLUDED from the weighted
    estimate and its own N_h excluded from the denominator -- never silently
    treated as p_h = 0, which would drag the estimate toward zero for a
    stratum nobody has looked at yet. It is still reported, by name, under
    `excluded_zero_n_strata`, so "nothing labelled here" is visible rather
    than quietly missing from the table.
    """
    conn = sqlite3.connect(ro_uri(store_path), uri=True)
    try:
        annotations, flags = fetch_human_annotations(conn)
        batches, batches_meta = fetch_batches(conn)
    finally:
        conn.close()

    batches_available = batches_meta["status"] == "ok"

    schema_notes = []
    if batches_meta["status"] == "missing_table":
        schema_notes.append(
            "ZLABELBATCH does not exist -- the store has not been migrated; "
            "launch the BlueX app once, then re-run this script."
        )
    elif batches_meta["status"] == "missing_columns":
        schema_notes.append(
            "ZLABELBATCH exists but is missing expected column(s): %s "
            "(columns actually found: %s)." % (batches_meta["missing"], batches_meta["found"])
        )

    universe = stratum_universe(batches) if batches_available else {}

    strata = {sid: {"N": pop_size, "n": 0, "k": 0} for sid, pop_size in universe.items()}
    excluded_total = 0
    excluded_by_reason = {}

    if batches_available:
        for annotation in annotations:
            bucket, reason, speech_class, stratum_id = classify_stratified_label(annotation, batches)
            if bucket == "excluded":
                excluded_total += 1
                excluded_by_reason[reason] = excluded_by_reason.get(reason, 0) + 1
                continue
            strata[stratum_id]["n"] += 1
            if speech_class == "hate":
                strata[stratum_id]["k"] += 1

    report = {
        "generated_at": now_iso(),
        "store": os.path.abspath(store_path),
        "schema_notes": schema_notes,
        "n_excluded": excluded_total,
        "excluded_by_reason": excluded_by_reason,
    }

    if not universe:
        report["run_status"] = "no_data"
        report["message"] = (
            "No stratified batches found in this store. Import a committee "
            "frame file in the app, label some of it, then re-run this script."
        )
        return report

    excluded_zero_n = sorted(sid for sid, s in strata.items() if s["n"] == 0)
    included = {sid: s for sid, s in strata.items() if s["n"] > 0}

    # Uniform-random baseline, via the EXACT SAME logic `compute_report` uses --
    # this analysis never re-derives it, so it can never drift from the number
    # `compute_report` reports on its own.
    uniform_breakdown = build_report(annotations, batches, batches_available)
    uniform_n = uniform_breakdown["n_included"]
    uniform_k = uniform_breakdown["included_by_class"].get("hate", 0)
    uniform_hate_rate = (uniform_k / uniform_n) if uniform_n > 0 else None

    if not included:
        report["run_status"] = "no_data"
        report["excluded_zero_n_strata"] = excluded_zero_n
        report["uniform_hate_rate"] = uniform_hate_rate
        report["uniform_n"] = uniform_n
        report["message"] = (
            "Stratified batches exist but none has a single label yet -- "
            "every stratum is in excluded_zero_n_strata. No estimate can "
            "honestly be reported from n=0 in every stratum."
        )
        return report

    n_total = sum(s["N"] for s in included.values() if s["N"] is not None)

    rows = []
    p_hat = 0.0
    variance = 0.0
    for stratum_id in sorted(included):
        s = included[stratum_id]
        n_h, k_h, big_n = s["n"], s["k"], s["N"]
        p_h = k_h / n_h
        weight = (big_n / n_total) if (big_n is not None and n_total) else 0.0
        p_hat += weight * p_h
        variance += (weight ** 2) * (p_h * (1 - p_h) / n_h)
        wilson_lo, wilson_hi = wilson_ci(k_h, n_h)
        enrichment = (p_h / uniform_hate_rate) if uniform_hate_rate else None
        rows.append({
            "stratum_id": stratum_id, "N": big_n, "n": n_h, "k": k_h,
            "p": p_h, "weight": weight,
            "wilson_ci": (wilson_lo, wilson_hi), "enrichment": enrichment,
        })

    se = math.sqrt(variance)
    ci_lo = max(0.0, p_hat - 1.96 * se)
    ci_hi = min(1.0, p_hat + 1.96 * se)

    report.update({
        "run_status": "ok",
        "strata": rows,
        "excluded_zero_n_strata": excluded_zero_n,
        "n_total_population_included": n_total,
        "hate_prevalence": p_hat,
        "variance": variance,
        "ci": (ci_lo, ci_hi),
        "uniform_hate_rate": uniform_hate_rate,
        "uniform_n": uniform_n,
    })
    return report


def render_stratified_report_text(report, store_path):
    lines = []
    lines.append("BlueX stratified weighted prevalence report")
    lines.append("store: %s" % store_path)
    lines.append("generated_at: %s" % report["generated_at"])
    lines.append("")
    if report["schema_notes"]:
        lines.append("Schema notes:")
        for note in report["schema_notes"]:
            lines.append("  - %s" % note)
        lines.append("")

    if report["run_status"] != "ok":
        lines.append("RESULT: no stratified estimate computed (%s)." % report["run_status"])
        lines.append(report["message"])
        return "\n".join(lines)

    if report["excluded_zero_n_strata"]:
        lines.append("Strata with a population but ZERO labels so far (excluded, not "
                      "treated as p=0):")
        for sid in report["excluded_zero_n_strata"]:
            lines.append("  - %s" % sid)
        lines.append("")

    lines.append("Per-stratum table (N_h, n_h, k_h, p_h, weight, Wilson 95%% CI, "
                  "enrichment vs. uniform baseline):")
    for row in report["strata"]:
        wilson_lo, wilson_hi = row["wilson_ci"]
        enrichment_str = ("%.2fx" % row["enrichment"]) if row["enrichment"] is not None \
            else "undefined (no uniform baseline)"
        lines.append(
            "  %-20s N=%-8d n=%-4d k=%-4d p=%s  weight=%s  Wilson=[%s, %s]  enrichment=%s"
            % (row["stratum_id"], row["N"], row["n"], row["k"], format_pct(row["p"]),
               format_pct(row["weight"]), format_pct(wilson_lo), format_pct(wilson_hi),
               enrichment_str)
        )
    lines.append("")

    lines.append("Uniform-random baseline (unchanged by anything in this report, computed "
                  "identically to base_rate.py's own uniformRandom-only estimate):")
    if report["uniform_hate_rate"] is not None:
        lines.append("  p_uniform = %s (n=%d)" % (format_pct(report["uniform_hate_rate"]),
                                                    report["uniform_n"]))
    else:
        lines.append("  no uniform-random pass-1 labels found yet -- enrichment factors "
                      "above are undefined until Stage 0 has at least one label.")
    lines.append("")

    lo, hi = report["ci"]
    lines.append("Stratified weighted estimate: p_hat = %s" % format_pct(report["hate_prevalence"]))
    lines.append("95%% normal-approximation CI: [%s, %s]" % (format_pct(lo), format_pct(hi)))
    lines.append("")
    lines.append(
        "This estimate and the uniform-random estimate are DIFFERENT analyses over "
        "DIFFERENT (non-overlapping) label sets -- they should agree within their "
        "intervals; if they do not, that disagreement is itself a finding about the "
        "stratum weights, and must be reported, not smoothed over."
    )
    if report["n_excluded"]:
        lines.append("")
        lines.append("Excluded labels (counted, not dropped): %d" % report["n_excluded"])
        for reason, count in sorted(report["excluded_by_reason"].items()):
            lines.append("  - %s: %d" % (reason, count))
    return "\n".join(lines)


def run_stratified(store_path, out_dir):
    report = compute_stratified_report(store_path)

    os.makedirs(out_dir, exist_ok=True)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H%M%SZ")
    json_path = os.path.join(out_dir, "stratified-estimate-%s.json" % stamp)

    def write_json(handle):
        json.dump(report, handle, ensure_ascii=False, indent=2)
        handle.write("\n")

    write_atomic(json_path, write_json)

    text = render_stratified_report_text(report, store_path)
    return json_path, report, text


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

    n_skipped = report.get("n_skipped", 0)
    item_word = "item" if n_skipped == 1 else "items"
    lines.append(
        "%d %s skipped (excluded from the estimate) -- skip rate %s of items offered "
        "from this sample." % (n_skipped, item_word, format_pct(report.get("skip_rate", 0.0)))
    )
    lines.append(
        "Caveat: skips are not annotations, so they are correctly excluded from "
        "both the numerator and denominator above -- but heavy skipping of "
        "ambiguous items biases the estimate toward the decidable subset, since "
        "whatever made an item hard enough to set aside is exactly what is missing "
        "from the prevalence figure below."
    )
    lines.append("")

    if report["run_status"] != "ok":
        lines.append("RESULT: no base rate computed (%s)." % report["run_status"])
        lines.append(report["message"])
        return "\n".join(lines)

    if report.get("definition_version_note"):
        # Multiple definitionVersions in the eligible sample -- refuse to pool
        # them into one number; report each version's own estimate instead.
        lines.append("NOTE: %s" % report["definition_version_note"])
        lines.append("")
        for version in report["definition_versions"]:
            v = report["by_definition_version"][version]
            lines.append("definitionVersion %d (n=%d, k=%d):" % (version, v["n"], v["hate_count"]))
            if v["hate_prevalence"] is None:
                lines.append("  no eligible labels under this version.")
                continue
            v_lo, v_hi = v["wilson_ci"]
            lines.append("  Hate prevalence: %s" % format_pct(v["hate_prevalence"]))
            lines.append("  95%% Wilson CI: [%s, %s]" % (format_pct(v_lo), format_pct(v_hi)))
            lines.append(
                "  FP/TP at point estimate: %s" % format_fp_tp(v["fp_per_tp_point"])
            )
            lines.append("")
        lines.append(
            "These estimates are NEVER pooled into a single figure across "
            "definitionVersions -- a definition change is expected to move "
            "the prevalence, and averaging over it would hide exactly the "
            "thing this report exists to show."
        )
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
        batches, batches_meta = fetch_batches(conn)
    finally:
        conn.close()

    batches_available = batches_meta["status"] == "ok"

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
    if batches_meta["status"] == "missing_table":
        schema_notes.append(
            "ZLABELBATCH does not exist -- the store has not been migrated; "
            "launch the BlueX app once (so SwiftData applies the lightweight "
            "migration that creates this table), then re-run this script. "
            "Every human label is excluded as no_label_batch_table until then."
        )
    elif batches_meta["status"] == "missing_columns":
        schema_notes.append(
            "ZLABELBATCH exists but is missing expected column(s): %s "
            "(columns actually found: %s). This is schema drift, not a "
            "pending migration -- do not assume launching the app will fix "
            "it; check what created/altered this table. Every human label is "
            "excluded as no_label_batch_table until this is resolved."
            % (batches_meta["missing"], batches_meta["found"])
        )
    if batches_available and not batches_meta.get("has_skipped_column", False):
        schema_notes.append(
            "ZLABELBATCH has no ZSKIPPEDURIS column yet -- skipped items cannot be "
            "counted on this store until it is migrated (skippedURIs was added "
            "alongside the skip-persistence fix); n_skipped is reported as 0, which "
            "may undercount actual skips rather than reflect that none happened."
        )
    if not schema_notes:
        schema_notes.append("ZANNOTATION/ZLABELBATCH schema found as expected; no migration gaps detected.")

    breakdown = build_report(annotations, batches, batches_available)
    n_skipped = count_skipped(batches) if batches_available else 0

    n = breakdown["n_included"]
    skip_denominator = n + n_skipped
    skip_rate = (n_skipped / skip_denominator) if skip_denominator > 0 else 0.0
    report = {
        "generated_at": now_iso(),
        "store": os.path.abspath(store_path),
        "schema_notes": schema_notes,
        "n_included": n,
        "included_by_class": breakdown["included_by_class"],
        "included_other_class": breakdown["included_other_class"],
        "n_excluded": breakdown["n_excluded"],
        "excluded_by_reason": breakdown["excluded_by_reason"],
        "n_skipped": n_skipped,
        "skip_rate": skip_rate,
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

    # Per-definitionVersion estimate, computed for EVERY version present
    # regardless of how many there are -- the multi-version branch below
    # decides whether this replaces or merely supplements the pooled numbers.
    by_definition_version = {}
    for version, entry in breakdown["by_definition_version"].items():
        v_by_class = entry["included_by_class"]
        v_n = sum(v_by_class.values()) + entry["included_other_class"]
        v_k = v_by_class.get("hate", 0)
        v_p = (v_k / v_n) if v_n > 0 else None
        v_lo, v_hi = wilson_ci(v_k, v_n)
        by_definition_version[version] = {
            "n": v_n,
            "included_by_class": v_by_class,
            "hate_count": v_k,
            "hate_prevalence": v_p,
            "wilson_ci": (v_lo, v_hi),
            "fp_per_tp_point": fp_per_tp(v_p),
            "fp_per_tp_lower": fp_per_tp(v_lo),
            "fp_per_tp_upper": fp_per_tp(v_hi),
        }

    versions_present = sorted(by_definition_version.keys())
    report["definition_versions"] = versions_present
    report["by_definition_version"] = by_definition_version

    if len(versions_present) > 1:
        # Refuse to pool: no single top-level hate_prevalence/wilson_ci is
        # computed at all when the included sample spans more than one
        # definitionVersion -- see `by_definition_version` for each version's
        # own, separately-computed estimate.
        report["run_status"] = "ok"
        report["definition_version_note"] = (
            "%d distinct definitionVersion values are present among the %d "
            "eligible labels (versions: %s). Estimates for different "
            "definitionVersions are NEVER pooled -- see by_definition_version "
            "for each version's own n/hate_prevalence/wilson_ci, computed "
            "separately." % (len(versions_present), n, versions_present)
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
    parser.add_argument("--stratified", action="store_true",
                         help="Report the stratified weighted prevalence estimate "
                              "(stratified, pass-1 labels only) instead of the "
                              "uniform-random Stage 0 report. The two are separate "
                              "analyses and are never pooled.")
    args = parser.parse_args(argv)

    store_dir = args.store or DEFAULT_STORE_DIR
    store_path = store_dir if store_dir.endswith(".store") else default_store_path(store_dir)

    if not os.path.exists(store_path):
        parser.error("store not found: %s" % store_path)

    if args.stratified:
        json_path, report, text = run_stratified(store_path, args.out)
        print(text)
        print("")
        print("wrote %s" % json_path)
        return 0 if report["run_status"] == "ok" else 1

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
