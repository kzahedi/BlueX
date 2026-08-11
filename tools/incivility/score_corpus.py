#!/usr/bin/env python3
"""Score BlueX corpus replies for INCIVILITY (toxicity/insult) — NOT hate.

WHY THIS EXISTS
----------------
`tools/benchmark/` measured `unitary/unbiased-toxic-roberta`'s `toxicity` head
against Bluesky's own moderator labels: it separates moderator-labelled `rude`
posts from random replies at AUC 0.946 (n=872 vs 940). That is a strong,
validated detector of incivility, and it is cheap to run over the whole
corpus (~2.2M replies and growing) since the model already lives on this
machine. This script does that: batched inference on MPS, one JSONL record
per (post, head) pair, resumable, safe to run next to a live scrape.

THE TRAP THIS MUST NEVER FALL INTO — READ BEFORE CHANGING ANYTHING
--------------------------------------------------------------------
The *same* `toxicity` head rates moderator-labelled `rude` posts as MORE
toxic than moderator-labelled `hate` posts (`intolerant`/`threat`) 80% of the
time (hate-vs-rude AUC **0.198** — worse than a coin flip, and in the wrong
direction). `identity_attack` is not much better (hate-vs-rude AUC 0.518).
Full numbers, from `tools/benchmark/`:

    head             hate vs random   hate vs rude   rude vs random
    toxicity              0.846           0.198           0.946
    identity_attack       0.901           0.518           0.919

This model detects incivility — rudeness, insult, profanity — not hate.
Hate is often expressed in clean language ("Man kann den Israelis nur
empfehlen, auszuwandern" scored +1.0 sentiment on a *different* detector,
zero rude words, pure hate). A score from this script must never be reported,
labelled, or field-named in a way that lets a future reader mistake it for a
hate signal. That is why every output record says `"head": "toxicity"` or
`"head": "identity_attack"` explicitly rather than exposing a bare "score" —
there is no field called `toxicity_score` that could get silently repurposed
as a hate proxy, and there is no field called anything resembling "hate".

WHAT THIS DATASET IS NOT
-------------------------
  * NOT a hate detector, and NOT a proxy for one. See above. AUC 0.198.
  * NOT written into the BlueX SwiftData store. This script produces JSONL
    only. The store's `Annotation.speechClass` field is exactly where an
    incivility score could get confused with a hate judgement if written
    carelessly; deciding how (or whether) to ingest this into `Annotation`
    with a clearly distinct `stage` is a separate decision, not made here.
  * NOT calibrated against a clean sample. The moderator labels this was
    validated against capture what was *reported and actioned* — a
    precision test, not a recall test (see TODO.md's methodological rules).
    Incivility that nobody reported is invisible to both the labels and,
    by construction, to any validation done against them.
  * NOT a complete corpus pass unless the accompanying `.summary.json` says
    `"run_status": "complete"`. Check that field before trusting any
    prevalence number computed from this output.

VERIFIED FACTS (measured on this machine 2026-08-11 — do not re-derive)
-------------------------------------------------------------------------
  * Model: `unitary/unbiased-toxic-roberta`, pinned to the `main` revision
    already resolved in the local HF cache: `MODEL_REVISION` below. Sixteen
    output heads (`multi_label_classification`, sigmoid, not softmax); this
    script keeps only `toxicity` and `identity_attack` — the two heads the
    benchmark actually measured. It scores every head in one forward pass
    regardless, so recording both costs nothing extra.
  * `max_position_embeddings` is 514; `tokenizer_config.json` sets
    `model_max_length: 512`. Inputs longer than 512 tokens are truncated by
    the tokenizer (`truncation=True, max_length=512`), not by this script's
    own logic. This is deliberate, not an oversight: the benchmark itself
    truncated the same way, so scoring the full corpus at a different limit
    would silently change what "the same detector" means.
  * torch 2.7.1 / transformers on this machine; MPS is available on the Mac
    mini and is preferred over CPU (`pick_device`).

SAFETY
------
The BlueX store is opened strictly read-only via `file:...?mode=ro`. Never
`?immutable=1`: it is WAL-blind and has returned zero rows on a populated
store. A corpus scrape may be writing to the store while this runs (disk
contention measured: a query that takes 0.80s quiet took 2.84s under scrape
load — expect slowness, not correctness problems). This script never writes
to the store and never invokes any other BlueX binary.

Output lands on the external volume `/Volumes/Eregion/bluex-incivility`,
never inside `/Volumes/Eregion/bluex-data` (the live store's own directory).

PACING
------
Multi-hour runs keep the SoC at full GPU utilization. `pacing.py` (see its
own docstring) adds the same two-layer cool-down `BlueX/Data/LLMPace.swift`
uses for the LLM annotation pass: an unconditional duty cycle plus
thermal-aware escalation via `ProcessInfo.processInfo.thermalState`. Default
60s work / 5s cool costs about 8% throughput; `--cool-seconds 0` disables it.
"""
import argparse
import datetime as dt
import json
import os
import sqlite3
import sys
import tempfile
import time

import pacing

MODEL_ID = "unitary/unbiased-toxic-roberta"
# Pinned to the commit the local HF cache's "main" ref resolves to, so a run
# today and a run in six months use the identical weights unless someone
# deliberately bumps this constant.
MODEL_REVISION = "36295dd80b422dc49f40052021430dae76241adc"
HEADS = ("toxicity", "identity_attack")
MAX_LENGTH = 512  # see "VERIFIED FACTS" above — deliberate, matches the benchmark

DEFAULT_STORE_DIR = os.environ.get("BLUEX_STORE_DIR", "/Volumes/Eregion/bluex-data")
DEFAULT_STORE_FILENAME = "default.store"
DEFAULT_OUT_DIR = "/Volumes/Eregion/bluex-incivility"

DEFAULT_BATCH_SIZE = 32
DEFAULT_MAX_RETRIES = 3
DEFAULT_RETRY_BACKOFF = 0.5

REPLIES_QUERY = (
    "SELECT ZURI, ZTEXT FROM ZPOST WHERE ZISROOTPOST = 0 AND ZURI IS NOT NULL "
    "ORDER BY ZURI"
)


class ScoreFailed(Exception):
    """A batch could not be scored after exhausting retries."""


def ro_uri(path):
    """Read-only SQLite URI. Deliberately NOT immutable=1 (see module docstring)."""
    return "file:" + os.path.abspath(path) + "?mode=ro"


def now_iso():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def default_store_path(store_dir):
    return os.path.join(store_dir, DEFAULT_STORE_FILENAME)


# --------------------------------------------------------------------------
# Store access
# --------------------------------------------------------------------------

def fetch_replies(store_path, limit=None):
    """Return [(uri, text), ...] for every reply in the store.

    Opens the store read-only; never writes to it. `text` is the raw column
    value, which may be None for a handful of rows (see score_texts, which
    treats None as "").
    """
    conn = sqlite3.connect(ro_uri(store_path), uri=True)
    try:
        query = REPLIES_QUERY
        if limit is not None:
            query += " LIMIT %d" % int(limit)
        rows = conn.execute(query).fetchall()
    finally:
        conn.close()
    return [(uri, text) for uri, text in rows]


# --------------------------------------------------------------------------
# Model layer (kept self-contained rather than importing
# tools/benchmark/detectors/hf_encoder.py, because this script needs a
# pinned `revision` for reproducibility, which that shared helper does not
# take as a parameter).
# --------------------------------------------------------------------------

def pick_device(requested=None):
    if requested:
        return requested
    import torch
    if torch.backends.mps.is_available():
        return "mps"
    return "cpu"


def load_model(model_id=MODEL_ID, revision=MODEL_REVISION, device=None):
    """Load tokenizer + model once. Raises on any failure to load/run —
    a failed load is a legitimate, reportable outcome, not something to
    silently work around.
    """
    from transformers import AutoModelForSequenceClassification, AutoTokenizer

    device = pick_device(device)
    tokenizer = AutoTokenizer.from_pretrained(model_id, revision=revision)
    model = AutoModelForSequenceClassification.from_pretrained(model_id, revision=revision)
    model.to(device)
    model.eval()
    return tokenizer, model, device


def score_texts(texts, tokenizer, model, device, max_length=MAX_LENGTH, heads=HEADS):
    """Run one forward pass over `texts`; return {head: [float, ...]} for
    just `heads`, in input order. None/empty text is scored as "" (the
    model handles empty strings fine; it is not a special case we invent).
    Truncation is applied by the tokenizer per VERIFIED FACTS above.
    """
    import torch

    batch = [(t or "") for t in texts]
    with torch.no_grad():
        encoded = tokenizer(
            batch, padding=True, truncation=True, max_length=max_length,
            return_tensors="pt",
        ).to(device)
        logits = model(**encoded).logits
        probs = torch.sigmoid(logits).to("cpu").tolist()

    id2label = model.config.id2label
    label_idx = {id2label[i]: i for i in range(len(id2label))}
    out = {h: [] for h in heads}
    for row in probs:
        for h in heads:
            out[h].append(float(row[label_idx[h]]))
    return out


def make_score_fn(tokenizer, model, device):
    """Bind a (texts) -> {head: [float,...]} callable for the scoring loop."""
    def score_fn(texts):
        return score_texts(texts, tokenizer, model, device)
    return score_fn


def score_batch_with_retry(texts, score_fn, max_retries=DEFAULT_MAX_RETRIES,
                            backoff_base=DEFAULT_RETRY_BACKOFF, sleep_fn=time.sleep):
    """Call score_fn(texts), retrying transient failures with backoff.

    Raises ScoreFailed if retries are exhausted. The caller decides what to
    do with that (count it, keep going — never abort the whole run).
    """
    attempt = 0
    while True:
        attempt += 1
        try:
            return score_fn(texts)
        except Exception as exc:  # noqa: BLE001 - deliberately broad; see module docstring
            if attempt > max_retries:
                raise ScoreFailed(
                    "scoring failed after %d attempts: %s: %s" % (attempt, type(exc).__name__, exc)
                ) from exc
            sleep_fn(backoff_base * attempt)


# --------------------------------------------------------------------------
# Batching / progress
# --------------------------------------------------------------------------

def iter_batches(seq, size):
    """Split seq into ceil(N/size) batches, covering every element exactly once."""
    for i in range(0, len(seq), size):
        yield seq[i:i + size]


def load_progress(path):
    """Return the set of URIs already recorded as scored."""
    done = set()
    if path and os.path.exists(path):
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if line:
                    done.add(line)
    return done


class ProgressWriter:
    """Appends scored URIs to the progress file, flushing after each write."""

    def __init__(self, path):
        self.path = path
        self._handle = None
        if path:
            self._handle = open(path, "a", encoding="utf-8")

    def mark(self, uris):
        if self._handle is None:
            return
        for uri in uris:
            self._handle.write(uri + "\n")
        self._handle.flush()
        os.fsync(self._handle.fileno())

    def close(self):
        if self._handle is not None:
            self._handle.close()


# --------------------------------------------------------------------------
# Scoring loop
# --------------------------------------------------------------------------

def score_corpus(replies, score_fn, batch_size=DEFAULT_BATCH_SIZE,
                  already_done=None, progress=None, on_record=None,
                  max_retries=DEFAULT_MAX_RETRIES, sleep_fn=time.sleep,
                  heads=HEADS, model_id=MODEL_ID, model_revision=MODEL_REVISION,
                  pacer=None):
    """Score `replies` ([(uri, text), ...]), emitting one record per
    (post, head) via on_record(record_dict).

    Skips URIs already in `already_done` (the --resume set). A batch that
    fails after retries increments failed_batches/failed_posts and is
    SKIPPED, not marked as progress — so a later --resume run will retry it
    rather than silently treating it as done. Never aborts the whole run for
    one batch failure.

    `pacer` (a `pacing.Pacer`, or None to disable pacing entirely — used by
    most tests) has its `maybe_pace()` called once per batch, success or
    failure, AFTER progress is marked for that batch. Cooling the hardware
    never touches resume state and can never double-count progress, because
    it happens strictly after the state that matters has already been
    recorded.

    Returns a stats dict: requested, skipped_resume, processed,
    failed_batches, failed_posts.
    """
    already_done = already_done or set()
    todo = [r for r in replies if r[0] not in already_done]

    stats = {
        "requested": len(replies),
        "skipped_resume": len(replies) - len(todo),
        "processed": 0,
        "failed_batches": 0,
        "failed_posts": 0,
    }

    for batch in iter_batches(todo, batch_size):
        uris = [uri for uri, _ in batch]
        texts = [text for _, text in batch]

        try:
            head_scores = score_batch_with_retry(
                texts, score_fn, max_retries=max_retries, sleep_fn=sleep_fn,
            )
        except ScoreFailed:
            stats["failed_batches"] += 1
            stats["failed_posts"] += len(batch)
            if pacer is not None:
                pacer.maybe_pace()
            continue

        scored_at = now_iso()
        for i, uri in enumerate(uris):
            for head in heads:
                rec = {
                    "uri": uri,
                    "head": head,
                    "score": head_scores[head][i],
                    "model_id": model_id,
                    "model_revision": model_revision,
                    "scored_at": scored_at,
                }
                if on_record is not None:
                    on_record(rec)

        stats["processed"] += len(batch)
        if progress is not None:
            progress.mark(uris)
        if pacer is not None:
            pacer.maybe_pace()

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


README_TEXT = """# BlueX incivility scores

This directory holds timestamped incivility scores for BlueX corpus replies,
produced by `tools/incivility/score_corpus.py` using
`unitary/unbiased-toxic-roberta` (revision `%(revision)s`).

## What this score IS

Each `incivility-scores-<timestamp>.jsonl` file contains one line per
(post, head) pair, e.g.:

```json
{"uri": "at://did:plc:.../app.bsky.feed.post/...", "head": "toxicity",
 "score": 0.87, "model_id": "unitary/unbiased-toxic-roberta",
 "model_revision": "%(revision)s", "scored_at": "2026-08-11T12:00:00Z"}
```

Two records per post: one for the `toxicity` head, one for `identity_attack`.
The `toxicity` head separates moderator-labelled `rude` posts from random
replies at **AUC 0.946** (n=872 vs 940, measured in `tools/benchmark/`). That
is a strong, validated **incivility** detector — profanity, insult, rude
tone.

## What this score IS NOT

**It is not a hate signal, and must never be treated as a proxy for one.**
The same `toxicity` head rates moderator-labelled `rude` posts as MORE toxic
than moderator-labelled `hate` posts (`intolerant`/`threat`) 80%% of the time:
hate-vs-rude AUC is **0.198** — worse than chance, and in the wrong
direction. `identity_attack` fares a little better but is still not a hate
detector (hate-vs-rude AUC 0.518). Hate is frequently expressed in clean
language that no toxicity model flags; incivility is a different axis
entirely, and this dataset measures only that axis. See `TODO.md` at the
repo root ("The finding that reframes the project") for the full numbers.

**It is not calibrated against a clean or complete sample.** The moderator
labels this model was validated against capture what was *reported and
actioned*, not a random sample of all incivility. A model scoring well
against these labels is a precision result: it agrees with what moderators
already caught. It says nothing about recall against incivility nobody
reported.

**It is not written into the BlueX SwiftData store.** JSONL only. Whether
and how to ingest this into an `Annotation` row (with a `stage` value kept
clearly distinct from any hate-classification stage) is a separate decision,
not made by this script.

**Not necessarily a complete pass.** Check `"run_status"` in the
`.summary.json` beside each file: `"complete"` means every reply requested
was processed with zero failed batches; `"partial"` means some batches
failed or the run was limited/interrupted, and prevalence figures computed
from that file will be incomplete. `.summary.json` also records the actual
throughput achieved (posts/sec) for that run.

## Reproducibility

Model: `unitary/unbiased-toxic-roberta`, pinned to revision
`%(revision)s`. Heads recorded: `toxicity`, `identity_attack`. Inputs are
truncated to 512 tokens by the tokenizer (`max_position_embeddings` is 514
for this checkpoint) — the same limit the benchmark itself used, so results
are comparable.

## Pacing

Multi-hour runs are paced to spare the hardware, following the same
two-layer scheme `BlueX/Data/LLMPace.swift` uses for the LLM annotation
pass: an unconditional duty cycle (default 60s of work, then 5s cooling —
about 8%% throughput cost) plus thermal-aware escalation that adds 3s
(`serious`) or 10s (`critical`) more when `ProcessInfo.processInfo.thermalState`
reports heat pressure. `.summary.json`'s `"pacing"` block records total
cooling time and how many escalations fired at each level; if it shows zero
escalations, the machine stayed `nominal` throughout and the duty cycle
alone did the job. `--cool-seconds 0` disables all of it.

## How it was generated

```
python3 tools/incivility/score_corpus.py \\
    [--limit N] [--batch-size 32] [--out DIR] [--store PATH] [--resume] \\
    [--work-seconds 60] [--cool-seconds 5]
```

The store is opened strictly read-only (`file:...?mode=ro`, never
`?immutable=1`) so it is safe to run while a corpus scrape is writing to it.
"""


def write_readme(out_dir):
    path = os.path.join(out_dir, "README.md")
    write_atomic(path, lambda handle: handle.write(README_TEXT % {"revision": MODEL_REVISION}))
    return path


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def run(store_path, out_dir, batch_size, limit, resume, device=None,
        model_loader=load_model, sleep_fn=time.sleep,
        work_seconds=pacing.DEFAULT_WORK_SECONDS, cool_seconds=pacing.DEFAULT_COOL_SECONDS,
        thermal_poll_seconds=pacing.DEFAULT_THERMAL_POLL_SECONDS, pacer=None):
    """Execute one full scoring run. Returns (jsonl_path, summary_path, summary).

    `pacer` lets callers (mainly tests) inject a pre-built `pacing.Pacer`;
    otherwise one is constructed from `work_seconds`/`cool_seconds`/
    `thermal_poll_seconds`. Pass `cool_seconds=0` (the CLI's
    `--cool-seconds 0`) to disable pacing entirely.
    """
    replies = fetch_replies(store_path, limit=limit)

    now = dt.datetime.now(dt.timezone.utc)
    stamp = now.strftime("%Y-%m-%dT%H%M%SZ")
    os.makedirs(out_dir, exist_ok=True)

    jsonl_path = os.path.join(out_dir, "incivility-scores-%s.jsonl" % stamp)
    summary_path = os.path.join(out_dir, "incivility-scores-%s.summary.json" % stamp)
    progress_path = os.path.join(out_dir, ".progress.txt") if resume else None

    already_done = load_progress(progress_path) if resume else set()

    tokenizer, model, resolved_device = model_loader(device=device)
    score_fn = make_score_fn(tokenizer, model, resolved_device)

    if pacer is None:
        pacer = pacing.Pacer(
            work_seconds=work_seconds, cool_seconds=cool_seconds,
            thermal_poll_seconds=thermal_poll_seconds,
        )

    jsonl_fd = open(jsonl_path, "w", encoding="utf-8")
    progress = ProgressWriter(progress_path) if progress_path else None

    def on_record(rec):
        jsonl_fd.write(json.dumps(rec, ensure_ascii=False) + "\n")
        jsonl_fd.flush()

    started_at = now_iso()
    start = time.monotonic()
    try:
        stats = score_corpus(
            replies, score_fn, batch_size=batch_size,
            already_done=already_done, progress=progress, on_record=on_record,
            sleep_fn=sleep_fn, pacer=pacer,
        )
    finally:
        jsonl_fd.close()
        if progress is not None:
            progress.close()
    elapsed = max(time.monotonic() - start, 1e-9)
    ended_at = now_iso()

    complete = (
        stats["failed_batches"] == 0
        and stats["processed"] + stats["skipped_resume"] == stats["requested"]
    )
    throughput = stats["processed"] / elapsed if stats["processed"] else 0.0

    summary = {
        "model_id": MODEL_ID,
        "model_revision": MODEL_REVISION,
        "heads": list(HEADS),
        "device": resolved_device,
        "store": os.path.abspath(store_path),
        "started_at": started_at,
        "ended_at": ended_at,
        "elapsed_seconds": elapsed,
        "posts_requested": stats["requested"],
        "posts_skipped_resume": stats["skipped_resume"],
        "posts_scored": stats["processed"],
        "failed_batches": stats["failed_batches"],
        "failed_posts": stats["failed_posts"],
        "throughput_posts_per_sec": throughput,
        "run_status": "complete" if complete else "partial",
        "pacing": pacer.summary(),
    }

    def write_summary(handle):
        json.dump(summary, handle, ensure_ascii=False, indent=2)
        handle.write("\n")

    write_atomic(summary_path, write_summary)

    return jsonl_path, summary_path, summary


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=(
            "Score BlueX corpus replies for incivility/toxicity (NOT hate) "
            "using unitary/unbiased-toxic-roberta."
        )
    )
    parser.add_argument("--limit", type=int, default=None,
                         help="cap the number of replies scored (for throughput measurement)")
    parser.add_argument("--batch-size", type=int, default=DEFAULT_BATCH_SIZE)
    parser.add_argument("--out", default=DEFAULT_OUT_DIR)
    parser.add_argument("--store", default=None,
                         help="path to default.store; defaults to $BLUEX_STORE_DIR "
                              "then /Volumes/Eregion/bluex-data")
    parser.add_argument("--resume", action="store_true",
                         help="skip posts already recorded in the progress file")
    parser.add_argument("--device", default=None,
                         help="override device (default: mps if available, else cpu)")
    parser.add_argument("--work-seconds", type=float, default=pacing.DEFAULT_WORK_SECONDS,
                         help="unconditional duty cycle: seconds of scoring work "
                              "between cool-downs (default: %(default)s)")
    parser.add_argument("--cool-seconds", type=float, default=pacing.DEFAULT_COOL_SECONDS,
                         help="unconditional duty cycle: seconds to sleep after each "
                              "--work-seconds window; 0 disables ALL pacing, including "
                              "thermal escalation (default: %(default)s)")
    args = parser.parse_args(argv)

    store_dir = args.store or DEFAULT_STORE_DIR
    store_path = store_dir if store_dir.endswith(".store") else default_store_path(store_dir)

    if not os.path.exists(store_path):
        parser.error("store not found: %s" % store_path)

    jsonl_path, summary_path, summary = run(
        store_path, args.out, args.batch_size, args.limit, args.resume, device=args.device,
        work_seconds=args.work_seconds, cool_seconds=args.cool_seconds,
    )

    write_readme(args.out)

    print("wrote %s" % jsonl_path)
    print("wrote %s" % summary_path)
    print(json.dumps(summary, ensure_ascii=False, indent=2))

    return 1 if (summary["run_status"] != "complete" or summary["failed_batches"] > 0) else 0


if __name__ == "__main__":
    sys.exit(main())
