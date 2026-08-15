#!/usr/bin/env python3
"""Harvest Bluesky moderation labels for the accounts and posts in the BlueX corpus.

WHY THIS EXISTS
----------------
Bluesky's labeler (`mod.bsky.app`) holds moderation labels on accounts and posts:
`needs-review`, `!suspend`, `!takedown`, `spam`, `rude`, `!hide` on accounts and,
critically, `intolerant` on posts — a human moderator's judgement that specific
content discriminates against a protected group. The project's benchmark set
currently has zero true-positive hate examples, which makes hate recall
unmeasurable. Labels like `intolerant` are externally generated, independent of
any classifier this project builds, and are a candidate seed for a gold set.

Labels are also perishable in a way the corpus itself is not: once an account is
taken down, its posts become unreachable from both the AppView and its own PDS
(`getAuthorFeed` and `com.atproto.repo.listRecords` both return HTTP 400 for
taken-down, deactivated, and deleted accounts, verified 2026-08-10). Every day
this harvester does not run against a still-reachable account is a day of
enforcement-latency data (`cts`, the label's creation timestamp) permanently
lost. Re-running this tool over time on the same corpus therefore produces a
label *history*, not just a snapshot: when a label first appears, and whether it
is later negated (`neg: true`, a retraction), are both preserved because output
is timestamped and never overwritten.

WHAT THIS DATASET IS NOT
-------------------------
  * NOT a hate-speech classifier's output. Every label here is Bluesky's own
    moderation action (or a third-party labeler's), not a judgement this
    project made.
  * NOT a complete moderation picture. `queryLabels` returns only labels the
    queried labeler (default: `mod.bsky.app`, i.e. Bluesky's own moderation
    service) has applied. Other labelers, and any moderation action that never
    produced a label, are invisible to this tool.
  * NOT proof of compliance when a subject carries no label. Absence from the
    response is the normal, expected case for the overwhelming majority of
    subjects (measured 2026-08-10: 7.7% of reply authors, 0.17% of replies)
    and must never be read as "this content was reviewed and found clean" —
    most subjects are simply never reviewed at all.
  * NOT a counter-speech signal. There is no moderation label for counter-speech;
    this tool cannot and does not produce one.
  * NOT necessarily a complete sweep of the corpus on any single run. A sweep
    can be interrupted (Ctrl-C, machine sleep, network loss) or contain failed
    batches. The `.summary.json` beside the data states explicitly whether the
    run that produced it was `"complete"` or `"partial"` — check that field
    before trusting prevalence numbers computed from the output.

VERIFIED API FACTS (measured 2026-08-10 against the live service — do not
re-derive, do not "improve")
-----------------------------------------------------------------------------
  * Endpoint: `https://mod.bsky.app/xrpc/com.atproto.label.queryLabels`.
    Unauthenticated. No credentials, no Keychain access.
  * `uriPatterns` query parameter repeats, one per subject; 40 subjects per
    request is confirmed to work and is the default batch size here.
  * A subject is a bare DID (`did:plc:...`) for an account label, or an AT URI
    (`at://did:plc:.../app.bsky.feed.post/...`) for a post label.
  * Response shape: `{"labels": [{"src":..., "uri":..., "val":..., "cts":...,
    "neg":...}, ...]}`.
  * Subjects with no labels are simply absent from the response body. This is
    the normal case, not an error, and must not be treated as a failure.
  * `getProfiles` is NOT a source of moderation labels (checked across 500
    sampled authors: every label it returned was a user's self-applied
    `!no-unauthenticated` privacy flag, zero moderation labels) and is
    deliberately not used here.

SAFETY
------
The BlueX store is opened strictly read-only via `file:...?mode=ro`. We never
use `?immutable=1`: it is WAL-blind and has been observed to silently return
zero rows on a populated store. A corpus scrape may be writing to the store
while this tool reads it; that is expected, not an error. This tool never
writes to the store and never invokes any other BlueX binary.

Output lands under `/Volumes/Eregion/bluex-labels` (external volume), never
inside `/Volumes/Eregion/bluex-data` (the live store's own directory).
"""
import argparse
import datetime as dt
import json
import os
import sqlite3
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

LABEL_ENDPOINT = "https://mod.bsky.app/xrpc/com.atproto.label.queryLabels"

DEFAULT_STORE_DIR = os.environ.get("BLUEX_STORE_DIR", "/Volumes/Eregion/bluex-data")
DEFAULT_STORE_FILENAME = "default.store"
DEFAULT_OUT_DIR = "/Volumes/Eregion/bluex-labels"

DEFAULT_BATCH_SIZE = 40
DEFAULT_SLEEP_SECONDS = 0.3
DEFAULT_QUERY_LIMIT = 250
DEFAULT_MAX_RETRIES = 5

ACCOUNTS_QUERY = "SELECT DISTINCT ZAUTHORDID FROM ZPOST WHERE ZISROOTPOST = 0"
POSTS_QUERY = "SELECT ZURI FROM ZPOST WHERE ZISROOTPOST = 0"

ACCOUNT_LABEL_VALUES_SEEN = (
    "needs-review", "!suspend", "!takedown", "spam", "rude", "!hide",
)
POST_LABEL_VALUES_SEEN = ("intolerant",)


class RetryableError(Exception):
    """A transient network failure; the caller should back off and retry."""


class FetchFailed(Exception):
    """A batch could not be fetched after exhausting retries."""


def ro_uri(path):
    """Read-only SQLite URI. Deliberately NOT immutable=1 (see module docstring)."""
    return "file:" + os.path.abspath(path) + "?mode=ro"


def now_iso():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


# --------------------------------------------------------------------------
# Store access
# --------------------------------------------------------------------------

def fetch_subjects(store_path, subject_type):
    """Return the distinct list of subjects of the given type from the store.

    subject_type is "accounts" or "posts". Opens the store read-only; never
    writes to it.
    """
    query = ACCOUNTS_QUERY if subject_type == "accounts" else POSTS_QUERY
    conn = sqlite3.connect(ro_uri(store_path), uri=True)
    try:
        rows = conn.execute(query).fetchall()
    finally:
        conn.close()
    return [row[0] for row in rows if row[0] is not None]


# --------------------------------------------------------------------------
# HTTP layer
# --------------------------------------------------------------------------

def build_url(subjects, limit=DEFAULT_QUERY_LIMIT, base=LABEL_ENDPOINT):
    params = [("uriPatterns", s) for s in subjects]
    params.append(("limit", str(limit)))
    return base + "?" + urllib.parse.urlencode(params)


def real_http_get(url, timeout=10):
    """Perform the real HTTP GET.

    Returns (status_code, headers_dict, body_bytes). Raises RetryableError for
    connection-level failures (timeouts, DNS, refused connections, etc.) so the
    retry loop in fetch_batch can back off and try again.
    """
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            return resp.status, dict(resp.headers), resp.read()
    except urllib.error.HTTPError as e:
        body = e.read() if hasattr(e, "read") else b""
        return e.code, dict(e.headers or {}), body
    except urllib.error.URLError as e:
        raise RetryableError(str(e))


def fetch_batch(subjects, http_get, max_retries=DEFAULT_MAX_RETRIES,
                 backoff_base=1.0, sleep_fn=time.sleep):
    """Fetch labels for one batch of subjects, retrying transient failures.

    http_get(url) -> (status_code, headers_dict, body_bytes), matching the
    contract of real_http_get above. Raises FetchFailed if retries are
    exhausted or the server returns a non-retryable error status.
    """
    url = build_url(subjects)
    attempt = 0
    while True:
        attempt += 1
        try:
            status, headers, body = http_get(url)
        except RetryableError as exc:
            if attempt > max_retries:
                raise FetchFailed("network error after %d attempts: %s" % (attempt, exc))
            sleep_fn(backoff_base * attempt)
            continue

        if status == 429:
            if attempt > max_retries:
                raise FetchFailed("429 after %d attempts" % attempt)
            retry_after = headers.get("Retry-After") or headers.get("retry-after")
            try:
                delay = float(retry_after)
            except (TypeError, ValueError):
                delay = backoff_base * attempt
            sleep_fn(delay)
            continue

        if status != 200:
            raise FetchFailed("HTTP %s for batch of %d subjects" % (status, len(subjects)))

        try:
            return json.loads(body)
        except (ValueError, TypeError) as exc:
            raise FetchFailed("bad JSON body: %s" % exc)


# --------------------------------------------------------------------------
# Batching / progress
# --------------------------------------------------------------------------

def iter_batches(subjects, size):
    """Split subjects into ceil(N/size) batches, covering every one exactly once."""
    for i in range(0, len(subjects), size):
        yield subjects[i:i + size]


def load_progress(path):
    """Return the set of subjects already recorded as processed."""
    done = set()
    if path and os.path.exists(path):
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if line:
                    done.add(line)
    return done


class ProgressWriter:
    """Appends processed subjects to the progress file, flushing after each write."""

    def __init__(self, path):
        self.path = path
        self._handle = None
        if path:
            self._handle = open(path, "a", encoding="utf-8")

    def mark(self, subjects):
        if self._handle is None:
            return
        for s in subjects:
            self._handle.write(s + "\n")
        self._handle.flush()
        os.fsync(self._handle.fileno())

    def close(self):
        if self._handle is not None:
            self._handle.close()


# --------------------------------------------------------------------------
# Harvest loop
# --------------------------------------------------------------------------

def label_to_record(label, subject_type, observed_at):
    return {
        "subject": label.get("uri"),
        "subject_type": subject_type,
        "src": label.get("src"),
        "val": label.get("val"),
        "cts": label.get("cts"),
        "neg": bool(label.get("neg", False)),
        "observed_at": observed_at,
    }


def harvest(subjects, subject_type, http_get, batch_size=DEFAULT_BATCH_SIZE,
            sleep_seconds=DEFAULT_SLEEP_SECONDS, sleep_fn=time.sleep,
            already_done=None, progress=None, on_record=None,
            max_retries=DEFAULT_MAX_RETRIES):
    """Sweep `subjects`, calling on_record(record_dict) for every label found.

    Skips subjects already in `already_done` (the --resume set). Marks each
    successfully-processed batch's subjects via `progress.mark(...)`. Never
    aborts on a single batch failure; counts them instead.

    IMPORTANT: `neg: true` on a label means the label was later retracted by
    the moderator (see module docstring). A record with `neg: true` is NOT an
    active moderation action. This function therefore tracks active and
    negated counts SEPARATELY — it does not produce a single blended count
    that conflates "this account was suspended" with "this account was
    suspended, then un-suspended." Measured 2026-08-14 on the account sweep:
    conflating the two overstated actioned accounts by roughly 100x (6,723
    reported vs. 63 actually-active `!suspend`/`!takedown` labels; ~77% of
    account labels in that sweep were negated).

    Returns a stats dict:
      requested, skipped_resume, processed, failed_batches, labels_found,
      by_value_active (dict of val -> count, neg == False only),
      by_value_negated (dict of val -> count, neg == True only),
      subjects_with_active_labels (subjects carrying at least one active
        label), subjects_with_only_negated_labels (subjects whose only labels
        are all negated -- i.e. NOT counted as actively labelled).
    """
    already_done = already_done or set()
    todo = [s for s in subjects if s not in already_done]

    stats = {
        "requested": len(subjects),
        "skipped_resume": len(subjects) - len(todo),
        "processed": 0,
        "failed_batches": 0,
        "labels_found": 0,
        "by_value_active": {},
        "by_value_negated": {},
        "subjects_with_active_labels": 0,
        "subjects_with_only_negated_labels": 0,
    }

    first_batch = True
    for batch in iter_batches(todo, batch_size):
        if not first_batch:
            sleep_fn(sleep_seconds)
        first_batch = False

        try:
            data = fetch_batch(batch, http_get, max_retries=max_retries, sleep_fn=sleep_fn)
        except FetchFailed:
            stats["failed_batches"] += 1
            continue

        observed_at = now_iso()
        labels = data.get("labels", []) or []
        active_subjects_in_batch = set()
        all_subjects_in_batch = set()
        for label in labels:
            rec = label_to_record(label, subject_type, observed_at)
            stats["labels_found"] += 1
            all_subjects_in_batch.add(rec["subject"])
            if rec["neg"]:
                stats["by_value_negated"][rec["val"]] = stats["by_value_negated"].get(rec["val"], 0) + 1
            else:
                stats["by_value_active"][rec["val"]] = stats["by_value_active"].get(rec["val"], 0) + 1
                active_subjects_in_batch.add(rec["subject"])
            if on_record is not None:
                on_record(rec)
        stats["subjects_with_active_labels"] += len(active_subjects_in_batch)
        stats["subjects_with_only_negated_labels"] += len(
            all_subjects_in_batch - active_subjects_in_batch
        )

        stats["processed"] += len(batch)
        if progress is not None:
            progress.mark(batch)

    return stats


# --------------------------------------------------------------------------
# Output plumbing
# --------------------------------------------------------------------------

def write_atomic(path, write_body):
    """Write via a temp file in the same directory, then rename."""
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


README_TEXT = """# BlueX moderation-label harvest

This directory holds timestamped snapshots of Bluesky moderation labels
(`com.atproto.label.queryLabels` against `mod.bsky.app`) for the accounts and
posts in the BlueX corpus, produced by `tools/labels/harvest_labels.py`.

## READ THIS FIRST: `neg: true` means retracted, not active

**~77% of account labels in a real sweep are negated (`neg: true`).** A label
record with `neg: true` means the moderator LATER RETRACTED that label — it
is NOT an active moderation action, and must be filtered out of any
"how many accounts are actioned" analysis.

On the 2026-08-14 account sweep, treating every label record as active
(ignoring `neg`) produced **`!takedown: 1777, !suspend: 4946`**, read as
"6,723 actioned accounts (3.27%)". The true, `neg`-filtered figure is
**43 active `!suspend` + 20 active `!takedown` = 63 accounts** — a ~100x
overstatement that reached specs, TODO.md, and a source-code comment before
being caught.

**Always filter `neg: true` before counting.** The JSONL records always carry
`neg` correctly (this was never wrong); what was wrong, until 2026-08, was
that the `.summary.json` blended active and negated counts into a single
`labels_by_value` / `subjects_with_labels` field. That field has been
replaced (see below) — treat any old summary you still have on disk that
has a bare `labels_by_value` key as suspect and re-derive counts from the
JSONL with a `neg` filter instead of trusting it.

## What this dataset is

Each `label-harvest-<subject_type>-<timestamp>.jsonl` file contains one line
per moderation label found, e.g.:

```json
{"subject": "did:plc:...", "subject_type": "account", "src": "did:plc:ar7c...",
 "val": "intolerant", "cts": "2026-05-01T00:00:00Z", "neg": false,
 "observed_at": "2026-08-10T12:00:00Z"}
```

`cts` is when the label was created by the moderator (the enforcement-latency
signal); `observed_at` is when this tool saw it. Re-running the harvester
against the same corpus over time turns these snapshots into a label
*history*: repeated observed_at values with the same cts show a stable label;
a later run with `neg: true` for a previously-seen label shows a retraction.

A `.summary.json` sits beside each JSONL file with subject counts, label
counts, a breakdown by label value, failed-batch count, and whether the run
was `"complete"` or `"partial"`.

**`neg: true` means retracted, not active.** The summary reports active and
negated counts SEPARATELY: `labels_by_value_active` / `labels_by_value_negated`
(plus `labels_by_value_total` for raw auditing), and
`subjects_with_active_labels` / `subjects_with_only_negated_labels`. Earlier
summaries (before 2026-08) had a single blended `labels_by_value` /
`subjects_with_labels` field that did not distinguish `neg: true` records —
on the 2026-08-14 account sweep this overstated actioned accounts by ~100x
(6,723 reported vs. 63 actually-active `!suspend`/`!takedown` labels; ~77% of
account labels in that sweep were negated). Always read the `*_active`
fields when asking "is this account currently actioned."

## What this dataset is NOT

  * **Not a hate-speech classifier's judgement.** Every label here was applied
    by Bluesky's own moderation service (or a third-party labeler it
    surfaces), not by anything in this project.
  * **Not proof of compliance for unlabelled content.** Absence of a label is
    the overwhelmingly common case (measured 2026-08-10: roughly 7.7% of reply
    authors and 0.17% of replies carry any label at all) and reflects that
    most content is never reviewed, not that it was reviewed and passed.
  * **Not a complete moderation picture.** `queryLabels` only returns labels
    from the queried labeler. Other labelers, or moderation actions that never
    produced a label, are invisible here.
  * **Not a counter-speech signal.** There is no moderation label for
    counter-speech; none of these files can be used to identify it.
  * **Not necessarily a complete sweep.** Check `"run_status"` in the
    `.summary.json` for each file: `"complete"` means every subject requested
    was processed with zero failed batches; `"partial"` means some subjects
    were skipped, some batches failed, or the run was interrupted, and
    prevalence figures computed from that file will understate the true
    label count.

## How it was generated

```
python3 tools/labels/harvest_labels.py --subjects accounts|posts|both \\
    [--limit N] [--batch 40] [--sleep 0.3] [--store PATH] [--out DIR] [--resume]
```

The store is opened strictly read-only (`file:...?mode=ro`, never
`?immutable=1`) so it is safe to run while a corpus scrape is writing to it.
The labeler endpoint is unauthenticated and queried at 40 subjects per
request by default, with the default 0.3s spacing between requests to stay
polite to the API.
"""


def write_readme(out_dir):
    path = os.path.join(out_dir, "README.md")
    write_atomic(path, lambda handle: handle.write(README_TEXT))
    return path


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def default_store_path(store_dir):
    return os.path.join(store_dir, DEFAULT_STORE_FILENAME)


def run_subject_type(subject_type, store_path, out_dir, args, http_get):
    subjects = fetch_subjects(store_path, subject_type)
    if args.limit is not None:
        subjects = subjects[:args.limit]

    now = dt.datetime.now(dt.timezone.utc)
    stamp = now.strftime("%Y-%m-%dT%H%M%SZ")
    os.makedirs(out_dir, exist_ok=True)

    jsonl_path = os.path.join(out_dir, "label-harvest-%s-%s.jsonl" % (subject_type, stamp))
    summary_path = os.path.join(out_dir, "label-harvest-%s-%s.summary.json" % (subject_type, stamp))
    progress_path = os.path.join(out_dir, ".progress-%s.txt" % subject_type) if args.resume else None

    already_done = load_progress(progress_path) if args.resume else set()

    jsonl_fd = open(jsonl_path, "w", encoding="utf-8")
    progress = ProgressWriter(progress_path) if progress_path else None

    def on_record(rec):
        jsonl_fd.write(json.dumps(rec, ensure_ascii=False) + "\n")
        jsonl_fd.flush()

    sweep_start = now_iso()
    try:
        stats = harvest(
            subjects, "account" if subject_type == "accounts" else "post",
            http_get,
            batch_size=args.batch,
            sleep_seconds=args.sleep,
            already_done=already_done,
            progress=progress,
            on_record=on_record,
        )
    finally:
        jsonl_fd.close()
        if progress is not None:
            progress.close()
    sweep_end = now_iso()

    complete = (stats["failed_batches"] == 0) and (stats["processed"] + stats["skipped_resume"] == stats["requested"])
    all_values = set(stats["by_value_active"]) | set(stats["by_value_negated"])
    labels_by_value_total = {
        val: stats["by_value_active"].get(val, 0) + stats["by_value_negated"].get(val, 0)
        for val in all_values
    }
    summary = {
        "subject_type": subject_type,
        "store": os.path.abspath(store_path),
        "sweep_start": sweep_start,
        "sweep_end": sweep_end,
        "subjects_requested": stats["requested"],
        "subjects_skipped_resume": stats["skipped_resume"],
        "subjects_processed": stats["processed"],
        # NOTE (2026-08): "labels_by_value"/"subjects_with_labels" (blended
        # active+negated counts) were REMOVED here — they caused a ~100x
        # over-report of actioned accounts (6,723 reported vs. 63 actually
        # active). See README.md in the output dir and the harvest()
        # docstring above. Use the *_active fields for "is this account
        # currently actioned"; the *_negated fields for retracted labels;
        # labels_by_value_total only for raw event-count auditing.
        "subjects_with_active_labels": stats["subjects_with_active_labels"],
        "subjects_with_only_negated_labels": stats["subjects_with_only_negated_labels"],
        "total_labels": stats["labels_found"],
        "labels_by_value_active": stats["by_value_active"],
        "labels_by_value_negated": stats["by_value_negated"],
        "labels_by_value_total": labels_by_value_total,
        "failed_batches": stats["failed_batches"],
        "run_status": "complete" if complete else "partial",
    }

    def write_summary(handle):
        json.dump(summary, handle, ensure_ascii=False, indent=2)
        handle.write("\n")

    write_atomic(summary_path, write_summary)

    return jsonl_path, summary_path, summary


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Harvest Bluesky moderation labels for the BlueX corpus."
    )
    parser.add_argument("--subjects", choices=["accounts", "posts", "both"], required=True)
    parser.add_argument("--limit", type=int, default=None,
                         help="cap the number of subjects processed (per subject type)")
    parser.add_argument("--batch", type=int, default=DEFAULT_BATCH_SIZE)
    parser.add_argument("--sleep", type=float, default=DEFAULT_SLEEP_SECONDS)
    parser.add_argument("--store", default=None,
                         help="path to default.store; defaults to $BLUEX_STORE_DIR "
                              "then /Volumes/Eregion/bluex-data")
    parser.add_argument("--out", default=DEFAULT_OUT_DIR)
    parser.add_argument("--resume", action="store_true",
                         help="skip subjects already recorded in the progress file")
    args = parser.parse_args(argv)

    store_dir = args.store or DEFAULT_STORE_DIR
    store_path = store_dir if store_dir.endswith(".store") else default_store_path(store_dir)

    if not os.path.exists(store_path):
        parser.error("store not found: %s" % store_path)

    subject_types = ["accounts", "posts"] if args.subjects == "both" else [args.subjects]

    any_failures = False
    for subject_type in subject_types:
        jsonl_path, summary_path, summary = run_subject_type(
            subject_type, store_path, args.out, args, real_http_get,
        )
        print("wrote %s" % jsonl_path)
        print("wrote %s" % summary_path)
        print(json.dumps(summary, ensure_ascii=False, indent=2))
        if summary["run_status"] != "complete":
            any_failures = True

    write_readme(args.out)

    return 1 if any_failures else 0


if __name__ == "__main__":
    sys.exit(main())
