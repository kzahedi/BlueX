#!/usr/bin/env python3
"""Pre-registered, sealed model predictions for the Stage 0 hand-labelling
sample -- so that comparing models against the human labels afterwards is
honest evidence, not hindsight.

WHY THIS EXISTS
----------------
On Monday a human hand-labels ~300 uniform-random Bluesky replies (Stage 0)
to measure the base rate of hate speech (see `tools/labelling/base_rate.py`).
The labelling UI is deliberately blind: the annotator never sees a model's
prediction. That discipline is worthless, though, unless we also protect the
*other* direction -- a model prediction made AFTER seeing the human label is
not evidence of anything, because it's trivial to look good in hindsight.

This tool closes that gap by writing model predictions over a SUPERSET of any
possible Stage 0 batch (every reply post in the store, not just whichever 300
get drawn), sealing them (sha256 in a git-committed manifest) BEFORE any human
label exists, so their timestamp -- via the git commit that adds the
manifest -- is a tamper-evident anchor: "these predictions existed before
labelling happened", provable independent of anything on this machine.

THREE SUBCOMMANDS
------------------
  * `seal`    -- refuses if the store already contains a human label (see
                 the guard below), builds/loads two models' scores over
                 every reply post with non-empty text, writes them to a
                 gzip JSONL OUTSIDE the store (a directory the macOS app has
                 no code path to -- `/Volumes/Eregion/bluex-data/predictions`,
                 a sibling of `default.store`, never read by the app or the
                 labelling UI), and writes a git-tracked metadata-only
                 manifest to `docs/prereg/`.
  * `verify`  -- recomputes the sealed file's sha256 and compares it to the
                 manifest. A mismatch means the pre-registration is void --
                 something changed the file after it was sealed -- and this
                 tool says so in as many words, refusing to proceed.
  * `compare` -- runs AFTER Stage 0 labelling. Verifies the hash first (see
                 above); refuses on mismatch. Then joins the sealed
                 predictions against the human labels (same uniformRandom,
                 pass-1-only discipline as `base_rate.py` -- reusing its
                 `wilson_ci` rather than reimplementing it) and reports AUC,
                 accuracy/precision/recall at a stated (not tuned) threshold,
                 inter-model agreement, and the human base rate with its
                 Wilson CI.

THE GUARD THAT MAKES THIS HONEST
----------------------------------
`seal` refuses (non-zero exit, clear message, no files written) if the store
already contains ANY `ZANNOTATION` row with `ZSTAGE='human'`. Once a single
human label exists, predictions "sealed" after that point could have been
influenced by it (directly, or by the person running this tool having seen
labelling results informally) and would no longer be pre-registered evidence
-- they would just be a benchmark run, which this project already has
(`tools/benchmark/`). This guard is the entire point of the tool; without it,
"sealed prediction" is a claim, not a fact.

THE TWO MODELS
----------------
  * `incivility_toxicity` -- the `toxicity` head of `unitary/unbiased-toxic-
    roberta`, joined from `tools/incivility/score_corpus.py`'s output
    (`incivility-scores-*.jsonl`). This is an INCIVILITY detector, not a hate
    detector (see that script's docstring: it rates moderator-labelled
    `rude` posts as MORE toxic than moderator-labelled hate posts 80% of the
    time, hate-vs-rude AUC 0.198 -- worse than chance, in the wrong
    direction). Posts never scored by that pipeline are recorded as `score:
    null` here, never dropped or imputed -- a null is missing information,
    not a zero.
  * `tfidf_lr_hate_vs_rude` -- a TF-IDF + LogisticRegression classifier
    trained fresh here on the corpus's own moderator labels (joined the same
    way `tools/benchmark/build_eval_set.py` does): positive class = active
    (non-negated) `intolerant`/`threat`/`extremist`/`intolerant-race` post
    labels, negative class = active `rude` post labels. Its score means
    **P(hate | one of {hate, rude})** -- NOT P(hate) on arbitrary text, and
    every record produced by this tool says so verbatim in its `meaning`
    field. On random text (not curated to be hate-or-rude) this model is
    known to be weak (AUC 0.61-0.68, see
    `docs/superpowers/notes/2026-08-13-hate-vs-rude-finetune-diagnostic.md`)
    -- reporting that weakness honestly against a truly random Stage 0
    sample is precisely the point of pre-registering it.

SAFETY
------
`default.store` is opened strictly read-only (`file:...?mode=ro`; never
`?immutable=1` -- WAL-blind, has silently returned zero rows on a populated
store elsewhere in this project). This tool never writes to that store, and
never touches `/Volumes/Eregion/bluex-data/social/` (a live Telegram
backfill) or the Telegram collector.
"""
import argparse
import datetime as dt
import glob
import gzip
import hashlib
import json
import os
import sqlite3
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "labelling"))

import base_rate as br  # noqa: E402 -- reuses wilson_ci, the UUID/batch join, SchemaNotReady

from sklearn.feature_extraction.text import TfidfVectorizer  # noqa: E402
from sklearn.linear_model import LogisticRegression  # noqa: E402
from sklearn.metrics import roc_auc_score, accuracy_score, precision_score, recall_score  # noqa: E402
from scipy.stats import spearmanr  # noqa: E402
import sklearn  # noqa: E402


DEFAULT_STORE_DIR = os.environ.get("BLUEX_STORE_DIR", "/Volumes/Eregion/bluex-data")
DEFAULT_STORE_FILENAME = "default.store"
DEFAULT_INCIVILITY_DIR = "/Volumes/Eregion/bluex-incivility"
DEFAULT_LABELS_DIR = "/Volumes/Eregion/bluex-labels"
# Deliberately a directory the macOS app has no code path to: a sibling of
# default.store, not a table inside it, and not under bluex-labelling or
# bluex-benchmark either (those are read by ad hoc analysis scripts, but
# never by the labelling UI's SwiftData model). The labelling UI's blindness
# to model output depends on this tool never writing predictions anywhere
# the app's persistence layer touches.
DEFAULT_PREDICTIONS_DIR = "/Volumes/Eregion/bluex-data/predictions"
# git-tracked -- relative to the repo root (this file lives at tools/prereg/).
DEFAULT_MANIFEST_DIR = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "docs", "prereg"
)

MODEL_INCIVILITY = "incivility_toxicity"
MODEL_TFIDF = "tfidf_lr_hate_vs_rude"

MEANING_INCIVILITY = (
    "toxicity head score from unitary/unbiased-toxic-roberta "
    "(tools/incivility/score_corpus.py). An INCIVILITY detector, not a hate "
    "detector: it rates moderator-labelled 'rude' posts as MORE toxic than "
    "moderator-labelled hate posts ('intolerant'/'threat') 80% of the time "
    "(hate-vs-rude AUC 0.198, worse than chance, wrong direction). null means "
    "this post was never scored by that pipeline -- not that its score is 0."
)
MEANING_TFIDF = (
    "P(hate | one of {hate, rude}) -- NOT P(hate) on arbitrary text. "
    "TF-IDF + LogisticRegression trained on moderator-labelled "
    "intolerant/threat/extremist/intolerant-race (positive) vs rude "
    "(negative) posts. Known weak on random text (AUC 0.61-0.68, see "
    "docs/superpowers/notes/2026-08-13-hate-vs-rude-finetune-diagnostic.md) "
    "-- that weakness, measured honestly on a truly random sample, is what "
    "this pre-registration exists to capture."
)

POSITIVE_LABEL_VALUES = frozenset({"intolerant", "threat", "extremist", "intolerant-race"})
HARD_NEGATIVE_LABEL_VALUES = frozenset({"rude"})

# Threshold used by `compare` for accuracy/precision/recall. Fixed and stated
# here rather than tuned against the human labels after the fact -- tuning a
# threshold on the very data being evaluated would make the reported
# precision/recall meaningless as an unbiased estimate.
COMPARE_THRESHOLD = 0.5

DEFAULT_RANDOM_STATE = 20260822

PROGRESS_EVERY = 200_000


class SealGuardError(Exception):
    """The store already has a human label; sealing would not be pre-registration."""


# --------------------------------------------------------------------------
# Small generic helpers
# --------------------------------------------------------------------------

def ro_uri(path):
    """Read-only SQLite URI. Deliberately NOT immutable=1 -- see module docstring."""
    return "file:" + os.path.abspath(path) + "?mode=ro"


def now_iso():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def now_stamp():
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H%M%SZ")


def default_store_path(store_dir):
    return os.path.join(store_dir, DEFAULT_STORE_FILENAME)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def write_atomic(path, write_body, mode="w"):
    directory = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=directory, suffix=".tmp")
    try:
        os.close(fd)
        with open(tmp, mode, encoding=None if "b" in mode else "utf-8") as handle:
            write_body(handle)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


# --------------------------------------------------------------------------
# The seal guard
# --------------------------------------------------------------------------

def store_has_human_annotations(conn):
    """True if ZANNOTATION contains any row with ZSTAGE='human'. False (not
    an error) if ZANNOTATION doesn't exist yet or lacks ZSTAGE -- a store
    that can't record human labels at all obviously doesn't have any."""
    cols = br.column_map(conn, "ZANNOTATION")
    if not cols or "ZSTAGE" not in cols:
        return False
    row = conn.execute(
        "SELECT COUNT(*) FROM ZANNOTATION WHERE %s = 'human'" % cols["ZSTAGE"]
    ).fetchone()
    return row[0] > 0


# --------------------------------------------------------------------------
# Store reads (read-only; the reply-post pool)
# --------------------------------------------------------------------------

def fetch_pool_posts(conn, progress=True):
    """Every reply post (ZISROOTPOST = 0) with non-empty text: list of
    (uri, text), in stable Z_PK order. This is the SUPERSET any Stage 0 batch
    is drawn from -- sealing over it means the batch's draw timing never
    matters."""
    cursor = conn.execute(
        "SELECT ZURI, ZTEXT FROM ZPOST "
        "WHERE ZISROOTPOST = 0 AND ZTEXT IS NOT NULL AND length(trim(ZTEXT)) > 0 "
        "ORDER BY Z_PK"
    )
    out = []
    while True:
        rows = cursor.fetchmany(50_000)
        if not rows:
            break
        for uri, text in rows:
            if uri is not None:
                out.append((uri, text))
        if progress and len(out) % PROGRESS_EVERY < 50_000:
            print("  ... %d pool posts read so far" % len(out), file=sys.stderr)
    return out


def fetch_texts_for_uris(conn, uris):
    """uri -> text, chunked IN query (mirrors build_eval_set.py's fetch_texts).
    Missing/empty-text URIs are simply absent from the result."""
    out = {}
    uris = list(uris)
    chunk = 500
    for i in range(0, len(uris), chunk):
        batch = uris[i:i + chunk]
        placeholders = ",".join("?" for _ in batch)
        rows = conn.execute(
            "SELECT ZURI, ZTEXT FROM ZPOST WHERE ZURI IN (%s)" % placeholders, batch,
        ).fetchall()
        for uri, text in rows:
            if text and text.strip():
                out[uri] = text
    return out


# --------------------------------------------------------------------------
# Model 1: incivility_toxicity -- merge ALL score files, never just the newest
# --------------------------------------------------------------------------

def find_incivility_score_files(incivility_dir):
    return sorted(glob.glob(os.path.join(incivility_dir, "incivility-scores-*.jsonl")))


def merge_incivility_scores(paths):
    """Merge every incivility-scores-*.jsonl file's `head == "toxicity"`
    records into uri -> (score, scored_at, model_id, model_revision).

    Merging ALL files matters: a prior mistake in this project used only the
    newest score file and silently dropped 60% of scores that only existed
    in an older file. When the same uri+toxicity appears in more than one
    file, the record with the later `scored_at` wins (a re-score supersedes
    an earlier one); ties keep whichever is seen last.
    """
    best = {}
    for path in paths:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                rec = json.loads(line)
                if rec.get("head") != "toxicity":
                    continue
                uri = rec.get("uri")
                if uri is None:
                    continue
                scored_at = rec.get("scored_at") or ""
                current = best.get(uri)
                if current is None or scored_at >= (current[1] or ""):
                    best[uri] = (rec.get("score"), scored_at, rec.get("model_id"), rec.get("model_revision"))
    return best


# --------------------------------------------------------------------------
# Model 2: tfidf_lr_hate_vs_rude -- trained on moderator labels
# --------------------------------------------------------------------------

def find_latest_complete_posts_label_file(labels_dir):
    """Mirrors tools/benchmark/build_eval_set.py's selection rule: newest
    label-harvest-posts-*.jsonl whose sibling .summary.json says 'complete'."""
    candidates = sorted(glob.glob(os.path.join(labels_dir, "label-harvest-posts-*.jsonl")))
    complete = []
    for path in candidates:
        summary_path = path[: -len(".jsonl")] + ".summary.json"
        if not os.path.exists(summary_path):
            continue
        with open(summary_path, "r", encoding="utf-8") as f:
            summary = json.load(f)
        if summary.get("run_status") == "complete":
            complete.append(path)
    if not complete:
        raise SystemExit(
            "no complete label-harvest-posts-*.jsonl found under %s "
            "(run tools/labels/harvest_labels.py --subjects posts first)" % labels_dir
        )
    return sorted(complete)[-1]


def load_post_labels(jsonl_path):
    """uri -> sorted list of non-negated label values. Identical discipline
    to build_eval_set.py's load_post_labels: `neg: true` rows are dropped
    entirely, as if never applied."""
    by_subject = {}
    with open(jsonl_path, "r", encoding="utf-8") as f:
        for line in f:
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


def classify_subject(label_values):
    """positive > hard_negative > None, given a subject's non-negated label
    values. Mirrors build_eval_set.py's classify_subject."""
    values = set(label_values)
    if values & POSITIVE_LABEL_VALUES:
        return "positive"
    if values & HARD_NEGATIVE_LABEL_VALUES:
        return "hard_negative"
    return None


def build_training_set(conn, labels_path):
    """Returns (texts, y, counts) where y is 1 for hate-relevant, 0 for rude."""
    post_labels = load_post_labels(labels_path)
    positive_uris = sorted(u for u, vals in post_labels.items() if classify_subject(vals) == "positive")
    hard_negative_uris = sorted(u for u, vals in post_labels.items() if classify_subject(vals) == "hard_negative")

    positive_texts = fetch_texts_for_uris(conn, positive_uris)
    hard_negative_texts = fetch_texts_for_uris(conn, hard_negative_uris)

    texts = list(positive_texts.values()) + list(hard_negative_texts.values())
    y = [1] * len(positive_texts) + [0] * len(hard_negative_texts)
    counts = {"positive": len(positive_texts), "hard_negative": len(hard_negative_texts)}
    return texts, y, counts


def train_tfidf_lr(texts, y, random_state):
    vec = TfidfVectorizer(max_features=20000, ngram_range=(1, 2), min_df=2, sublinear_tf=True)
    x = vec.fit_transform(texts)
    clf = LogisticRegression(max_iter=2000, class_weight="balanced", random_state=random_state)
    clf.fit(x, y)
    return vec, clf


def predict_proba_positive(vec, clf, texts, progress=True):
    scores = []
    batch_size = 50_000
    for i in range(0, len(texts), batch_size):
        batch = texts[i:i + batch_size]
        x = vec.transform(batch)
        scores.extend(clf.predict_proba(x)[:, 1].tolist())
        if progress and len(texts) > batch_size:
            print("  ... tfidf_lr scored %d/%d pool posts" % (min(i + batch_size, len(texts)), len(texts)),
                  file=sys.stderr)
    return scores


# --------------------------------------------------------------------------
# seal
# --------------------------------------------------------------------------

def run_seal(store_path, incivility_dir, labels_dir, labels_file, predictions_dir,
             manifest_dir, random_state):
    conn = sqlite3.connect(ro_uri(store_path), uri=True)
    try:
        if store_has_human_annotations(conn):
            raise SealGuardError(
                "REFUSING to seal: the store already contains at least one human "
                "annotation (ZANNOTATION.ZSTAGE='human'). Predictions sealed now "
                "would no longer be pre-registered -- Stage 0 labelling has "
                "already started. No files were written."
            )

        print("reading reply-post pool from %s ..." % store_path, file=sys.stderr)
        pool = fetch_pool_posts(conn)
        print("pool size: %d reply posts with non-empty text" % len(pool), file=sys.stderr)

        labels_path = labels_file or find_latest_complete_posts_label_file(labels_dir)
        print("training tfidf_lr_hate_vs_rude from %s ..." % labels_path, file=sys.stderr)
        texts, y, label_counts = build_training_set(conn, labels_path)
        if len(set(y)) < 2:
            raise SystemExit(
                "cannot train tfidf_lr_hate_vs_rude: need at least one positive "
                "AND one hard_negative labelled post, found counts=%s" % label_counts
            )
        vec, clf = train_tfidf_lr(texts, y, random_state)
    finally:
        conn.close()

    incivility_files = find_incivility_score_files(incivility_dir)
    if not incivility_files:
        raise SystemExit(
            "no incivility-scores-*.jsonl files found under %s -- refusing to "
            "seal with zero incivility coverage (that would silently look like "
            "'every post scored null', which is a different, checkable claim "
            "than 'the scoring pipeline was never run')" % incivility_dir
        )
    print("merging %d incivility score file(s): %s"
          % (len(incivility_files), ", ".join(os.path.basename(p) for p in incivility_files)),
          file=sys.stderr)
    incivility_scores = merge_incivility_scores(incivility_files)

    pool_uris = [uri for uri, _ in pool]
    pool_texts = [text for _, text in pool]

    print("scoring pool with tfidf_lr_hate_vs_rude ...", file=sys.stderr)
    tfidf_scores = predict_proba_positive(vec, clf, pool_texts)

    os.makedirs(predictions_dir, exist_ok=True)
    os.makedirs(manifest_dir, exist_ok=True)
    stamp = now_stamp()
    out_path = os.path.join(predictions_dir, "sealed-stage0-%s.jsonl.gz" % stamp)
    tmp_path = out_path + ".partial"

    print("writing %d records for %d posts to %s ..." % (2 * len(pool_uris), len(pool_uris), out_path),
          file=sys.stderr)
    try:
        with gzip.open(tmp_path, "wt", encoding="utf-8") as gz:
            for i, uri in enumerate(pool_uris):
                inc = incivility_scores.get(uri)
                inc_score = inc[0] if inc is not None else None
                gz.write(json.dumps(
                    {"uri": uri, "model": MODEL_INCIVILITY, "score": inc_score, "meaning": MEANING_INCIVILITY},
                    ensure_ascii=False) + "\n")
                gz.write(json.dumps(
                    {"uri": uri, "model": MODEL_TFIDF, "score": float(tfidf_scores[i]), "meaning": MEANING_TFIDF},
                    ensure_ascii=False) + "\n")
                if (i + 1) % PROGRESS_EVERY == 0:
                    print("  ... wrote %d/%d posts" % (i + 1, len(pool_uris)), file=sys.stderr)
        os.replace(tmp_path, out_path)
    except (KeyboardInterrupt, BaseException):
        # Never leave a half-written file at the final name -- an interrupted
        # run must be unmistakably incomplete, not silently indistinguishable
        # from a finished seal.
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
        raise

    sha256 = sha256_file(out_path)
    record_count = 2 * len(pool_uris)
    distinct_uri_count = len(pool_uris)

    incivility_model_ids = {v[2] for v in incivility_scores.values() if v[2]}
    incivility_revisions = {v[3] for v in incivility_scores.values() if v[3]}

    manifest = {
        "sealed_file": os.path.basename(out_path),
        "sha256": sha256,
        "record_count": record_count,
        "distinct_uri_count": distinct_uri_count,
        "created_at": now_iso(),
        "intent": (
            "Pre-registration: these model predictions over every Stage-0-"
            "eligible reply post were sealed BEFORE any human Stage 0 label "
            "existed in the store (the seal guard checked and found zero "
            "ZANNOTATION rows with ZSTAGE='human'). Comparing them against "
            "human labels after Monday's session is therefore unbiased "
            "evidence of each model's accuracy on the deployment "
            "distribution, not hindsight."
        ),
        "manifest_is_tamper_evident_anchor": (
            "This manifest is committed to git. Its git commit timestamp is "
            "the tamper-evident proof that these predictions existed before "
            "Stage 0 labelling happened -- provable independent of anything "
            "on this machine. This file is never edited after being "
            "committed; `verify`/`compare` recompute the sealed file's "
            "sha256 and refuse to proceed on any mismatch."
        ),
        "models": {
            MODEL_INCIVILITY: {
                "meaning": MEANING_INCIVILITY,
                "model_id": sorted(incivility_model_ids)[0] if incivility_model_ids else None,
                "model_revision": sorted(incivility_revisions)[0] if incivility_revisions else None,
                "source_files": [os.path.basename(p) for p in incivility_files],
                "n_scored": sum(1 for v in incivility_scores.values() if v[0] is not None),
            },
            MODEL_TFIDF: {
                "meaning": MEANING_TFIDF,
                "training_label_source_file": os.path.basename(labels_path),
                "training_label_counts": label_counts,
                "random_state": random_state,
                "sklearn_version": sklearn.__version__,
                "vectorizer": "TfidfVectorizer(max_features=20000, ngram_range=(1,2), min_df=2, sublinear_tf=True)",
                "classifier": "LogisticRegression(max_iter=2000, class_weight='balanced')",
            },
        },
    }
    manifest_path = os.path.join(manifest_dir, "sealed-stage0-%s.json" % stamp)
    write_atomic(manifest_path, lambda h: (json.dump(manifest, h, ensure_ascii=False, indent=2), h.write("\n")))

    return out_path, manifest_path, manifest


# --------------------------------------------------------------------------
# verify
# --------------------------------------------------------------------------

def verify_hash(manifest_path, predictions_dir):
    """Returns (ok: bool, message: str, manifest: dict|None)."""
    with open(manifest_path, "r", encoding="utf-8") as f:
        manifest = json.load(f)
    pred_path = os.path.join(predictions_dir, manifest["sealed_file"])
    if not os.path.exists(pred_path):
        return False, "sealed file not found: %s" % pred_path, manifest
    actual = sha256_file(pred_path)
    if actual != manifest["sha256"]:
        return False, (
            "SHA256 MISMATCH for %s: manifest says %s, file now hashes to %s. "
            "This INVALIDATES the pre-registration -- the sealed file has "
            "changed since it was sealed and can no longer be trusted as "
            "evidence collected before human labelling." % (pred_path, manifest["sha256"], actual)
        ), manifest
    return True, "OK: sha256 matches manifest (%s). Pre-registration intact." % manifest["sha256"], manifest


# --------------------------------------------------------------------------
# compare
# --------------------------------------------------------------------------

def load_sealed_predictions(manifest, predictions_dir):
    """Returns dict: (uri, model) -> score (None allowed)."""
    pred_path = os.path.join(predictions_dir, manifest["sealed_file"])
    out = {}
    with gzip.open(pred_path, "rt", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            rec = json.loads(line)
            out[(rec["uri"], rec["model"])] = rec["score"]
    return out


def fetch_eligible_human_labels(conn):
    """Same discipline as base_rate.py: only human annotations whose batch's
    sampling frame is uniformRandom AND passNumber == 1 count. Returns list
    of (uri, speech_class) -- unlike base_rate.py this tool also needs the
    post's URI (to join against sealed predictions), via ZANNOTATION.ZPOST ->
    ZPOST.Z_PK."""
    a_cols = br.column_map(conn, "ZANNOTATION")
    if not a_cols:
        raise br.SchemaNotReady("ZANNOTATION table not found in this store")
    for required in ("ZSPEECHCLASS", "ZSTAGE", "ZPOST"):
        if required not in a_cols:
            raise br.SchemaNotReady("ZANNOTATION is missing %s (found: %s)" % (required, sorted(a_cols)))

    p_cols = br.column_map(conn, "ZPOST")
    if "ZURI" not in p_cols:
        raise br.SchemaNotReady("ZPOST is missing ZURI")

    has_batch_id = "ZBATCHID" in a_cols

    select_cols = ["a.%s" % a_cols["ZSPEECHCLASS"], "p.%s" % p_cols["ZURI"]]
    if has_batch_id:
        select_cols.append("a.%s" % a_cols["ZBATCHID"])

    query = (
        "SELECT %s FROM ZANNOTATION a JOIN ZPOST p ON a.%s = p.Z_PK "
        "WHERE a.%s = 'human'" % (", ".join(select_cols), a_cols["ZPOST"], a_cols["ZSTAGE"])
    )
    rows = conn.execute(query).fetchall()

    batches, batches_meta = br.fetch_batches(conn)
    batches_available = batches_meta["status"] == "ok"

    eligible = []
    for row in rows:
        speech_class, uri = row[0], row[1]
        batch_id_raw = row[2] if has_batch_id else None
        annotation = {"speech_class": speech_class, "batch_id_raw": batch_id_raw}
        bucket, _reason, _sc = br.classify_label(annotation, batches, batches_available)
        if bucket == "included":
            eligible.append((uri, speech_class))
    return eligible


def compute_model_report(scores_by_uri, human_hate_by_uri, threshold=COMPARE_THRESHOLD):
    """scores_by_uri: uri -> score|None (only for uris in the human-labelled
    eligible set). human_hate_by_uri: uri -> 0/1."""
    uris_with_label = list(human_hate_by_uri.keys())
    n_null = sum(1 for u in uris_with_label if scores_by_uri.get(u) is None)
    usable = [u for u in uris_with_label if scores_by_uri.get(u) is not None]

    report = {
        "n_compared": len(usable),
        "n_null": n_null,
        "threshold": threshold,
    }
    if len(usable) == 0:
        report.update({"roc_auc": None, "accuracy": None, "precision": None, "recall": None})
        return report

    y_true = [human_hate_by_uri[u] for u in usable]
    y_score = [scores_by_uri[u] for u in usable]

    if len(set(y_true)) < 2:
        report["roc_auc"] = None
    else:
        report["roc_auc"] = float(roc_auc_score(y_true, y_score))

    y_pred = [1 if s >= threshold else 0 for s in y_score]
    report["accuracy"] = float(accuracy_score(y_true, y_pred))
    report["precision"] = float(precision_score(y_true, y_pred, zero_division=0))
    report["recall"] = float(recall_score(y_true, y_pred, zero_division=0))
    return report


def compute_inter_model_agreement(predictions, uris, model_a, model_b, threshold=COMPARE_THRESHOLD):
    """Pairwise Spearman correlation + binarised-decision agreement over the
    whole sealed pool (not limited to the human-labelled subset) -- more
    statistical power, and inter-model agreement needs no human label at
    all."""
    pairs = []
    for uri in uris:
        sa = predictions.get((uri, model_a))
        sb = predictions.get((uri, model_b))
        if sa is not None and sb is not None:
            pairs.append((sa, sb))
    if len(pairs) < 2:
        return {"n": len(pairs), "spearman": None, "binarised_agreement": None}
    a_scores = [p[0] for p in pairs]
    b_scores = [p[1] for p in pairs]
    rho, _p = spearmanr(a_scores, b_scores)
    # spearmanr returns nan (not an exception) when either input is constant
    # -- a real, reportable condition ("this model produced no variation on
    # this pool"), not a crash, but nan must not leak into JSON as a bare
    # float (not valid JSON) or be mistaken for a real correlation of 0.
    rho_out = None if rho is None or (isinstance(rho, float) and rho != rho) else float(rho)
    agree = sum(1 for a, b in pairs if (a >= threshold) == (b >= threshold))
    return {
        "n": len(pairs),
        "spearman": rho_out,
        "binarised_agreement": agree / len(pairs),
    }


MIN_HUMAN_LABELS = 30


def run_compare(manifest_path, predictions_dir, store_path):
    """Returns (return_code, report_dict|None). Prints nothing -- callers
    (main()) do the printing, so tests can inspect the report directly."""
    ok, message, manifest = verify_hash(manifest_path, predictions_dir)
    if not ok:
        return 1, {"error": message}

    predictions = load_sealed_predictions(manifest, predictions_dir)
    all_uris = sorted({uri for (uri, _model) in predictions.keys()})

    conn = sqlite3.connect(ro_uri(store_path), uri=True)
    try:
        try:
            eligible = fetch_eligible_human_labels(conn)
        except br.SchemaNotReady as exc:
            return 1, {"error": "cannot read human labels: %s" % exc}
    finally:
        conn.close()

    if len(eligible) < MIN_HUMAN_LABELS:
        return 1, {
            "error": (
                "not enough labels yet: found %d uniformRandom pass-1 human "
                "labels, need at least %d. Run more of Stage 0 labelling "
                "before comparing." % (len(eligible), MIN_HUMAN_LABELS)
            ),
            "n_human_labels": len(eligible),
        }

    human_hate_by_uri = {uri: (1 if sc == "hate" else 0) for uri, sc in eligible}
    k = sum(human_hate_by_uri.values())
    n = len(human_hate_by_uri)
    lo, hi = br.wilson_ci(k, n)

    models = {}
    for model in (MODEL_INCIVILITY, MODEL_TFIDF):
        scores_by_uri = {uri: predictions.get((uri, model)) for uri in human_hate_by_uri}
        models[model] = compute_model_report(scores_by_uri, human_hate_by_uri)

    agreement = compute_inter_model_agreement(predictions, all_uris, MODEL_INCIVILITY, MODEL_TFIDF)

    report = {
        "n_human_labels": n,
        "human_base_rate": {"k": k, "n": n, "prevalence": k / n if n else None, "wilson_ci": (lo, hi)},
        "models": models,
        "agreement": {"%s_vs_%s" % (MODEL_INCIVILITY, MODEL_TFIDF): agreement},
        "threshold_used": COMPARE_THRESHOLD,
    }
    return 0, report


def render_compare_report(report):
    lines = []
    lines.append("Stage 0 pre-registered prediction comparison")
    lines.append("")
    br_info = report["human_base_rate"]
    lines.append("Human hate base rate (uniformRandom, pass 1 only): "
                  "%.2f%% (k=%d, n=%d), 95%% Wilson CI [%.2f%%, %.2f%%]"
                  % (br_info["prevalence"] * 100, br_info["k"], br_info["n"],
                     br_info["wilson_ci"][0] * 100, br_info["wilson_ci"][1] * 100))
    lines.append("")
    lines.append("Threshold used for accuracy/precision/recall: %.2f (fixed, not tuned on this data)"
                  % report["threshold_used"])
    for model, m in report["models"].items():
        lines.append("")
        lines.append("Model: %s" % model)
        lines.append("  n_compared=%d  n_null=%d" % (m["n_compared"], m["n_null"]))
        lines.append("  ROC AUC vs human hate label: %s" % ("%.4f" % m["roc_auc"] if m["roc_auc"] is not None else "n/a"))
        if m["accuracy"] is not None:
            lines.append("  accuracy=%.4f precision=%.4f recall=%.4f" % (m["accuracy"], m["precision"], m["recall"]))
    lines.append("")
    lines.append("Inter-model agreement (whole sealed pool, not just the human-labelled subset):")
    for pair, agr in report["agreement"].items():
        lines.append("  %s: n=%d spearman=%s binarised_agreement=%s"
                      % (pair, agr["n"],
                         "%.4f" % agr["spearman"] if agr["spearman"] is not None else "n/a",
                         "%.4f" % agr["binarised_agreement"] if agr["binarised_agreement"] is not None else "n/a"))
    return "\n".join(lines)


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def add_common_store_arg(parser):
    parser.add_argument("--store", default=None,
                         help="path to default.store; defaults to $BLUEX_STORE_DIR "
                              "then /Volumes/Eregion/bluex-data")


def resolve_store_path(args):
    store_dir = args.store or DEFAULT_STORE_DIR
    return store_dir if store_dir.endswith(".store") else default_store_path(store_dir)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)

    p_seal = sub.add_parser("seal", help="Seal predictions over the current reply-post pool.")
    add_common_store_arg(p_seal)
    p_seal.add_argument("--incivility-dir", default=DEFAULT_INCIVILITY_DIR)
    p_seal.add_argument("--labels-dir", default=DEFAULT_LABELS_DIR)
    p_seal.add_argument("--labels-file", default=None,
                         help="explicit label-harvest-posts-*.jsonl, overriding auto-selection")
    p_seal.add_argument("--predictions-dir", default=DEFAULT_PREDICTIONS_DIR)
    p_seal.add_argument("--manifest-dir", default=DEFAULT_MANIFEST_DIR)
    p_seal.add_argument("--random-state", type=int, default=DEFAULT_RANDOM_STATE)

    p_verify = sub.add_parser("verify", help="Verify a sealed file's hash against its manifest.")
    p_verify.add_argument("--manifest", required=True)
    p_verify.add_argument("--predictions-dir", default=DEFAULT_PREDICTIONS_DIR)

    p_compare = sub.add_parser("compare", help="Compare sealed predictions against human labels.")
    p_compare.add_argument("--manifest", required=True)
    p_compare.add_argument("--predictions-dir", default=DEFAULT_PREDICTIONS_DIR)
    add_common_store_arg(p_compare)

    args = parser.parse_args(argv)

    if args.command == "seal":
        store_path = resolve_store_path(args)
        if not os.path.exists(store_path):
            parser.error("store not found: %s" % store_path)
        try:
            out_path, manifest_path, manifest = run_seal(
                store_path, args.incivility_dir, args.labels_dir, args.labels_file,
                args.predictions_dir, args.manifest_dir, args.random_state,
            )
        except SealGuardError as exc:
            print("ERROR: %s" % exc, file=sys.stderr)
            return 1
        print("wrote %s" % out_path)
        print("wrote %s" % manifest_path)
        print(json.dumps({k: v for k, v in manifest.items()}, ensure_ascii=False, indent=2))
        return 0

    if args.command == "verify":
        ok, message, _manifest = verify_hash(args.manifest, args.predictions_dir)
        print(message)
        return 0 if ok else 1

    if args.command == "compare":
        store_path = resolve_store_path(args)
        rc, report = run_compare(args.manifest, args.predictions_dir, store_path)
        if rc != 0:
            print("ERROR: %s" % report.get("error"), file=sys.stderr)
            return rc
        print(render_compare_report(report))
        return 0

    parser.error("unknown command")
    return 2


if __name__ == "__main__":
    sys.exit(main())
