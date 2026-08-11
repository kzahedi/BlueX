#!/usr/bin/env python3
"""Build the BlueX hate-detector evaluation set from moderator labels.

WHY THIS EXISTS
----------------
Until the 2026-08-10 moderation-label sweep, this project had zero confirmed
true-positive hate examples, so no detector could be evaluated — only
demonstrated on anecdotes. `tools/labels/harvest_labels.py` fixed that: it
pulled Bluesky's own moderator labels for every post in the corpus. This
script turns that label sweep into a reusable, reproducible evaluation set by
joining label subjects back to `ZPOST.ZTEXT` in the store and drawing a
matched pool of unlabelled controls.

THE CLASS DESIGN — DO NOT COLLAPSE THIS TO TWO CLASSES
--------------------------------------------------------
There are three classes, not two, and the middle one is the point:

  * **positive** — `intolerant`, `threat`, `extremist`, `intolerant-race`.
    A human moderator's judgement that the content discriminates against a
    protected group or threatens someone.
  * **hard_negative** — `rude`. Incivility a moderator actioned, but NOT for
    discrimination or threat. This is the discriminating test: a detector
    that fires on `rude` as readily as on the positive classes is measuring
    rudeness, not hate, and has not earned a place in this project's
    pipeline. Positive-vs-hard_negative AUC must be reported with equal
    prominence to positive-vs-easy_negative, never buried beneath it.
  * **easy_negative** — random replies carrying NO label of any value
    (not just none of the four positive values — `rude`, `spam`, `porn`,
    etc. are all excluded from this pool too, because "no label at all" is
    the honest reading of "easy negative").

Negated labels (`neg: true`, a moderator retraction) are excluded from all
three classes as if the label were never applied.

WHAT THIS DATASET IS NOT
-------------------------
  * NOT a ground truth for hate prevalence. Moderator labels capture what was
    *reported and actioned*, not all hateful content — see the harvester's
    own caveats. A model that scores badly here may be flagging real hate
    nobody reported; this set is a reasonable precision test and a poor
    recall test. Say this every time these numbers are quoted.
  * NOT a complete accounting of `rude`/`spam`/etc. Those pools are capped by
    how many carry non-empty text in the store, not by how many the labeler
    applied.
  * NOT deterministic across store snapshots. Store text can differ run to
    run if content was edited or removed; the easy_negative sample is
    reproducible given the SAME store snapshot and seed, not across snapshots.

SAFETY
------
The store is opened strictly read-only via `file:...?mode=ro`. Never
`?immutable=1` — it is WAL-blind and has previously produced a false zero-row
conclusion in this project. A corpus scrape may be writing to the store while
this runs; that is expected, not an error. This script never writes to
`/Volumes/Eregion/bluex-data` — only to `/Volumes/Eregion/bluex-benchmark`.

REPRODUCIBILITY
----------------
The RNG seed is a CLI flag (default fixed below) and is always recorded in
the `.summary.json`, so a prior eval set can be regenerated exactly given the
same store snapshot, the same label harvest file, and the same seed.
"""
import argparse
import datetime as dt
import glob
import json
import os
import random
import sqlite3
import sys
import tempfile

SUPPORT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "support")
sys.path.insert(0, SUPPORT_DIR)
import nl_score  # noqa: E402

DEFAULT_LABELS_DIR = "/Volumes/Eregion/bluex-labels"
DEFAULT_STORE = "/Volumes/Eregion/bluex-data/default.store"
DEFAULT_OUT_DIR = "/Volumes/Eregion/bluex-benchmark"
DEFAULT_CONTROL_RATIO = 4.0
DEFAULT_SEED = 20260811

POSITIVE_VALUES = frozenset({"intolerant", "threat", "extremist", "intolerant-race"})
HARD_NEGATIVE_VALUES = frozenset({"rude"})


def ro_uri(path):
    """Read-only SQLite URI. Deliberately NOT immutable=1 (see module docstring)."""
    return "file:" + os.path.abspath(path) + "?mode=ro"


def now_iso():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


# --------------------------------------------------------------------------
# Label-file selection
# --------------------------------------------------------------------------

def find_latest_complete_posts_file(labels_dir):
    """Return the path to the newest label-harvest-posts-*.jsonl with run_status
    'complete'. Raises SystemExit with a clear message if none qualifies.
    """
    candidates = sorted(glob.glob(os.path.join(labels_dir, "label-harvest-posts-*.jsonl")))
    complete = []
    for path in candidates:
        summary_path = path[: -len(".jsonl")] + ".summary.json"
        if not os.path.exists(summary_path):
            continue
        with open(summary_path, "r", encoding="utf-8") as handle:
            summary = json.load(handle)
        if summary.get("run_status") == "complete":
            complete.append(path)
    if not complete:
        raise SystemExit(
            "no complete label-harvest-posts-*.jsonl found under %s "
            "(run tools/labels/harvest_labels.py --subjects posts first)" % labels_dir
        )
    return sorted(complete)[-1]  # filenames are timestamp-sortable


# --------------------------------------------------------------------------
# Label parsing -> subject classification
# --------------------------------------------------------------------------

def load_post_labels(jsonl_path):
    """Parse the label harvest file into per-subject non-negated label values.

    Returns dict: uri -> sorted list of label values (deduplicated), covering
    every post subject with at least one non-negated label of ANY value.
    Negated (`neg: true`) rows are dropped entirely, as if never applied.
    """
    by_subject = {}
    with open(jsonl_path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            rec = json.loads(line)
            if rec.get("subject_type") != "post":
                continue
            if rec.get("neg"):
                continue
            subject = rec.get("subject")
            val = rec.get("val")
            if not subject or not val:
                continue
            by_subject.setdefault(subject, set()).add(val)
    return {uri: sorted(vals) for uri, vals in by_subject.items()}


def classify_subject(labels):
    """positive > hard_negative > None, given a subject's non-negated label values."""
    values = set(labels)
    if values & POSITIVE_VALUES:
        return "positive"
    if values & HARD_NEGATIVE_VALUES:
        return "hard_negative"
    return None


# --------------------------------------------------------------------------
# Store access
# --------------------------------------------------------------------------

def fetch_texts(conn, uris):
    """uri -> text for the given URIs (chunked IN clauses); missing/absent
    from the store or empty text are simply absent from the returned dict.
    """
    out = {}
    uris = list(uris)
    chunk = 500
    for i in range(0, len(uris), chunk):
        batch = uris[i:i + chunk]
        placeholders = ",".join("?" for _ in batch)
        rows = conn.execute(
            "SELECT ZURI, ZTEXT FROM ZPOST WHERE ZURI IN (%s)" % placeholders,
            batch,
        ).fetchall()
        for uri, text in rows:
            if text and text.strip():
                out[uri] = text
    return out


def fetch_reply_uri_pool(conn):
    """All reply URIs (not roots) with non-empty text, in a stable Z_PK order.

    Stable ordering is what makes the easy_negative sample reproducible given
    a fixed seed and store snapshot: random.Random(seed).sample() over this
    list is deterministic, whereas SQLite's RANDOM() is not seedable from
    Python.
    """
    rows = conn.execute(
        "SELECT ZURI FROM ZPOST "
        "WHERE ZISROOTPOST = 0 AND ZTEXT IS NOT NULL AND length(trim(ZTEXT)) > 0 "
        "ORDER BY Z_PK"
    ).fetchall()
    return [r[0] for r in rows if r[0] is not None]


# --------------------------------------------------------------------------
# Build
# --------------------------------------------------------------------------

def build_eval_set(labels_path, store_path, control_ratio, seed):
    """Returns (records, summary_extra) where records is a list of dicts
    ready to serialise, in class order positive, hard_negative, easy_negative.
    """
    post_labels = load_post_labels(labels_path)

    positive_uris = []
    hard_negative_uris = []
    for uri, labels in post_labels.items():
        cls = classify_subject(labels)
        if cls == "positive":
            positive_uris.append(uri)
        elif cls == "hard_negative":
            hard_negative_uris.append(uri)
    positive_uris.sort()
    hard_negative_uris.sort()

    conn = sqlite3.connect(ro_uri(store_path), uri=True)
    try:
        positive_texts = fetch_texts(conn, positive_uris)
        hard_negative_texts = fetch_texts(conn, hard_negative_uris)

        all_labelled = set(post_labels.keys())
        reply_pool = fetch_reply_uri_pool(conn)
        candidate_easy = [u for u in reply_pool if u not in all_labelled]

        target_easy_n = int(round(control_ratio * len(positive_texts)))
        rng = random.Random(seed)
        target_easy_n = min(target_easy_n, len(candidate_easy))
        easy_uris = sorted(rng.sample(candidate_easy, target_easy_n))
        easy_texts = fetch_texts(conn, easy_uris)
    finally:
        conn.close()

    dropped_empty_text = {
        "positive": len(positive_uris) - len(positive_texts),
        "hard_negative": len(hard_negative_uris) - len(hard_negative_texts),
    }

    records = []
    for uri, text in positive_texts.items():
        records.append({"uri": uri, "text": text, "class": "positive",
                         "labels": post_labels[uri]})
    for uri, text in hard_negative_texts.items():
        records.append({"uri": uri, "text": text, "class": "hard_negative",
                         "labels": post_labels[uri]})
    for uri, text in easy_texts.items():
        records.append({"uri": uri, "text": text, "class": "easy_negative",
                         "labels": []})

    # Language tagging: NLLanguageRecognizer, batched through the same swift
    # binary detectors/nltagger.py uses, so class label and language use one
    # consistent source of truth. The store has no language column of its
    # own (checked 2026-08-11: ZPOST carries no ZLANGUAGE field), so this is
    # the only source available.
    texts = [r["text"] for r in records]
    nl_results = nl_score.score_texts(texts) if texts else []
    for rec, nl in zip(records, nl_results):
        rec["language"] = nl["language"]

    summary_extra = {
        "candidateEasyNegativePoolSize": len(candidate_easy),
        "targetEasyNegativeN": target_easy_n,
        "droppedForEmptyOrMissingText": dropped_empty_text,
    }
    return records, summary_extra


def summarize(records, provenance, control_ratio, seed, labels_path, store_path, summary_extra):
    by_class = {}
    by_class_language = {}
    for rec in records:
        by_class[rec["class"]] = by_class.get(rec["class"], 0) + 1
        key = (rec["class"], rec["language"])
        by_class_language[key] = by_class_language.get(key, 0) + 1

    by_class_language_out = {}
    for (cls, lang), n in by_class_language.items():
        by_class_language_out.setdefault(cls, {})[lang] = n

    return {
        "builtAt": provenance["builtAt"],
        "labelsSource": os.path.abspath(labels_path),
        "store": os.path.abspath(store_path),
        "controlRatio": control_ratio,
        "seed": seed,
        "positiveLabelValues": sorted(POSITIVE_VALUES),
        "hardNegativeLabelValues": sorted(HARD_NEGATIVE_VALUES),
        "totalRecords": len(records),
        "byClass": by_class,
        "byClassAndLanguage": by_class_language_out,
        **summary_extra,
        "caveat": (
            "Moderator labels capture what was reported and actioned, not all "
            "hate. This set is a reasonable precision test and a poor recall "
            "test: a model scoring badly may be flagging real hate nobody "
            "reported. hard_negative ('rude') is the discriminating class — a "
            "detector that cannot separate positive from hard_negative is "
            "measuring incivility, not hate, and positive-vs-hard_negative "
            "results must be reported with equal prominence to "
            "positive-vs-easy_negative, never subordinated to it."
        ),
    }


README_TEXT = """# BlueX hate-detector evaluation set

Produced by `tools/benchmark/build_eval_set.py` by joining the completed
Bluesky moderator label sweep (`tools/labels/harvest_labels.py`) to
`ZPOST.ZTEXT` in the BlueX store.

## What this dataset is

Each `eval-set-<timestamp>.jsonl` file has one line per example:

```json
{"uri": "at://...", "text": "...", "class": "positive",
 "labels": ["intolerant"], "language": "en"}
```

Three classes:

  * **positive** — moderator label in `intolerant`, `threat`, `extremist`,
    `intolerant-race`.
  * **hard_negative** — moderator label `rude`. This is the discriminating
    test: a detector that fires on rudeness as readily as on the positive
    classes is measuring incivility, not hate.
  * **easy_negative** — a random sample of replies carrying NO moderator
    label at all (any value), at `controlRatio : 1` against positives.

A `.summary.json` sits beside each JSONL file with class counts, a
per-class/per-language breakdown, the RNG seed used, and the source label
file and store path, so a set can be regenerated exactly.

## What this dataset is NOT

  * **Not ground truth for hate prevalence.** Moderator labels capture what
    was *reported and actioned*, not all hateful content. A model that
    scores badly against this set may be correctly flagging hate that nobody
    ever reported to Bluesky's moderators. This makes the set a reasonable
    **precision** test and a poor **recall** test — say so whenever these
    numbers are quoted.
  * **Not a complete accounting of `rude` or any other label value.** The
    hard_negative pool is capped by how many `rude`-labelled posts still
    carry non-empty text in the live store, not by how many the labeler
    applied historically.
  * **Not deterministic across store snapshots.** Regenerating against a
    different store snapshot (edits, deletions, a later scrape) can shift
    which text is available even with the same seed and label file.

## How it was generated

```
python3 tools/benchmark/build_eval_set.py \\
    [--labels-dir /Volumes/Eregion/bluex-labels] \\
    [--store /Volumes/Eregion/bluex-data/default.store] \\
    [--out-dir /Volumes/Eregion/bluex-benchmark] \\
    [--control-ratio 4.0] [--seed 20260811]
```

The store is opened strictly read-only (`file:...?mode=ro`, never
`?immutable=1`), so it is safe to run while a corpus scrape is writing to it.
Language is tagged via the same `NLLanguageRecognizer` configuration the app
uses (`tools/benchmark/support/nl_score.swift`), because the store itself
carries no language column.
"""


def write_readme(out_dir):
    path = os.path.join(out_dir, "README.md")
    write_atomic(path, lambda handle: handle.write(README_TEXT))
    return path


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


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Build the BlueX hate-detector evaluation set from moderator labels."
    )
    parser.add_argument("--labels-dir", default=DEFAULT_LABELS_DIR)
    parser.add_argument("--labels-file", default=None,
                         help="explicit label-harvest-posts-*.jsonl path, "
                              "overriding auto-selection of the newest complete run")
    parser.add_argument("--store", default=DEFAULT_STORE)
    parser.add_argument("--out-dir", default=DEFAULT_OUT_DIR)
    parser.add_argument("--control-ratio", type=float, default=DEFAULT_CONTROL_RATIO,
                         help="easy_negative : positive ratio")
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    args = parser.parse_args(argv)

    if not os.path.exists(args.store):
        parser.error("store not found: %s" % args.store)

    labels_path = args.labels_file or find_latest_complete_posts_file(args.labels_dir)
    if not os.path.exists(labels_path):
        parser.error("labels file not found: %s" % labels_path)

    now = dt.datetime.now(dt.timezone.utc)
    provenance = {"builtAt": now.replace(microsecond=0).isoformat().replace("+00:00", "Z")}
    stamp = now.strftime("%Y-%m-%dT%H%M%SZ")

    os.makedirs(args.out_dir, exist_ok=True)
    jsonl_path = os.path.join(args.out_dir, "eval-set-%s.jsonl" % stamp)
    summary_path = os.path.join(args.out_dir, "eval-set-%s.summary.json" % stamp)

    records, summary_extra = build_eval_set(
        labels_path, args.store, args.control_ratio, args.seed,
    )

    def write_jsonl(handle):
        for rec in records:
            handle.write(json.dumps(rec, ensure_ascii=False) + "\n")

    write_atomic(jsonl_path, write_jsonl)

    summary = summarize(
        records, provenance, args.control_ratio, args.seed,
        labels_path, args.store, summary_extra,
    )

    def write_summary(handle):
        json.dump(summary, handle, ensure_ascii=False, indent=2)
        handle.write("\n")

    write_atomic(summary_path, write_summary)
    write_readme(args.out_dir)

    print("wrote %s" % jsonl_path)
    print("wrote %s" % summary_path)
    print(json.dumps({k: v for k, v in summary.items() if k != "caveat"}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
