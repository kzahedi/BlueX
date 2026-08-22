#!/usr/bin/env python3
"""Train UNSUPERVISED paragraph embeddings (gensim Doc2Vec) on the full
BlueX reply corpus. Stage 1 of the classification proposal
(`docs/proposal/bluex-classification-proposal.tex`): the one ensemble member
that needs no labels at all.

WHY THIS EXISTS
----------------
Every hate-classification model built so far was trained on a hate-vs-rude
task and has never seen the corpus's overwhelming majority class (ordinary
replies) -- which is why measured performance collapses from 0.96 (on the
labelled benchmark) to 0.61-0.68 on real corpus text. A Doc2Vec model
trained unsupervised on the whole deployment distribution -- ordinary
replies included -- learns that distribution's own structure and its
bilingual (82% English / 14% German, see docs/proposal) vocabulary, neither
of which any off-the-shelf sentence embedding model was fit on. This is
purely descriptive/unsupervised, in line with the contamination rule in
`docs/superpowers/specs/2026-08-22-pre-label-analysis-and-consensus-labelling.md`
(Section 0): nothing here produces or touches a label, so this model can
later be evaluated against human labels as genuinely held-out gold.

CONTAMINATION RULES (non-negotiable -- see module docstring of
tools/labelling/base_rate.py for the store-access pattern this follows)
-----------------------------------------------------------------------
  * Training text comes from the corpus (`ZPOST.ZTEXT`) ONLY. This script
    never reads `/Volumes/Eregion/bluex-data/predictions/` (sealed
    pre-registration) and never reads any annotation table. It contains no
    label information whatsoever.
  * Read-only store access: `file:...?mode=ro`, NEVER `?immutable=1` (that
    flag is WAL-blind and has returned zero rows on a populated store --
    see score_corpus.py / base_rate.py precedent). Never writes to the
    store. Never touches `/Volumes/Eregion/bluex-data/social/` (live
    Telegram backfill).

STREAMING, NOT MATERIALISING
-----------------------------
`StreamingCorpus` re-opens a fresh read-only sqlite connection and re-runs
the query on every `__iter__()` call. This is deliberate: gensim's
`Doc2Vec.train()` iterates its `corpus_iterable` once per epoch, and a
plain one-shot generator would silently train on zero documents for every
epoch after the first -- a classic, quiet gensim footgun. `StreamingCorpus`
is a class with `__iter__`, not a generator function, precisely so each
call produces an independent stream. Never build a 2.1M-element Python list
of texts to work around this.

REPRODUCIBILITY
----------------
gensim's own documentation is explicit that bit-for-bit determinism in
Word2Vec/Doc2Vec training requires `workers=1` (multi-threaded training has
nondeterministic thread interleaving even with a fixed seed). This script
records BOTH the seed and the actual `workers` value used in metadata, and
states plainly whether the run is fully reproducible (`workers == 1`) or
only seed-reproducible-in-expectation (`workers > 1`, the default for
speed). Default: `max(1, cpu_count() - 2)`; override with `--workers`.

TOKENISATION (documented, not stemmed)
-----------------------------------------
Lowercase, Unicode-aware `\\w+` word tokens, keeping `#hashtag` and
`@mention` as single tokens, with URLs collapsed to a literal `<url>`
token. No stemming: the corpus is bilingual (English/German) and stemming
one language's morphology and not the other's would silently bias the
vocabulary toward whichever language's stemmer happened to be applied --
so neither is stemmed. See `tokenize()` below.

POLITENESS / CHECKPOINTING
-----------------------------
Runs `os.nice(10)` internally (best-effort; failures are swallowed -- a
missing `nice` syscall must never abort training) and applies the same
two-layer cool-down (`tools/incivility/pacing.py`, itself modelled on
`BlueX/Data/LLMPace.swift`) between epochs: default 60s work / 5s cool.
`--cool-seconds 0` disables all pacing. The model is checkpointed to
`--out-dir` after every epoch so an interrupted multi-hour run resumes
(`--resume`) rather than restarting from epoch 0.
"""
import argparse
import datetime as dt
import glob
import json
import multiprocessing
import os
import re
import sqlite3
import sys
import tempfile
import time

import gensim
from gensim.models.doc2vec import Doc2Vec, TaggedDocument

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "incivility"))
import pacing  # noqa: E402 -- see sys.path.insert above; reuses the LLMPace-derived cool-down scheme

DEFAULT_STORE_DIR = os.environ.get("BLUEX_STORE_DIR", "/Volumes/Eregion/bluex-data")
DEFAULT_STORE_FILENAME = "default.store"
DEFAULT_OUT_DIR = "/Volumes/Eregion/bluex-data/embeddings/"

REPLIES_QUERY = (
    "SELECT ZURI, ZTEXT FROM ZPOST WHERE ZISROOTPOST = 0 AND ZURI IS NOT NULL "
    "ORDER BY ZURI"
)
REPLIES_COUNT_QUERY = (
    "SELECT COUNT(*) FROM ZPOST WHERE ZISROOTPOST = 0 AND ZURI IS NOT NULL"
)

DEFAULT_VECTOR_SIZE = 200
DEFAULT_WINDOW = 5
DEFAULT_MIN_COUNT = 5
DEFAULT_DM = 1
DEFAULT_DBOW_WORDS = 0
DEFAULT_EPOCHS = 10
DEFAULT_SEED = 42

CHECKPOINT_PREFIX = "doc2vec-epoch"
FINAL_MODEL_NAME = "doc2vec-final.model"
FINAL_METADATA_NAME = "doc2vec-final.meta.json"


# --------------------------------------------------------------------------
# Store access
# --------------------------------------------------------------------------

def ro_uri(path):
    """Read-only SQLite URI. Deliberately NOT immutable=1 -- see module docstring."""
    return "file:" + os.path.abspath(path) + "?mode=ro"


def default_store_path(store_dir):
    return os.path.join(store_dir, DEFAULT_STORE_FILENAME)


def fetch_row_count(store_path, limit=None):
    """COUNT(*) of eligible reply rows, honouring the same --limit a training
    run would use (so metadata's corpus_row_count matches what was actually
    streamed, not the store's full population)."""
    if limit is not None:
        return min(limit, _raw_row_count(store_path))
    return _raw_row_count(store_path)


def _raw_row_count(store_path):
    conn = sqlite3.connect(ro_uri(store_path), uri=True)
    try:
        (n,) = conn.execute(REPLIES_COUNT_QUERY).fetchone()
    finally:
        conn.close()
    return n


# --------------------------------------------------------------------------
# Tokenisation -- lowercase, Unicode word tokens, #hashtags/@mentions kept,
# URLs collapsed to <url>. No stemming (see module docstring).
# --------------------------------------------------------------------------

URL_RE = re.compile(r"https?://\S+")
# Unicode word characters plus an optional leading # or @, so hashtags and
# mentions survive as single tokens instead of being split on the symbol.
TOKEN_RE = re.compile(r"[#@]?\w+", re.UNICODE)
# Placeholder that survives TOKEN_RE (which strips '<'/'>') so the literal
# "<url>" token can be reinstated after tokenising.
_URL_PLACEHOLDER = "xxurlplaceholderxx"


def tokenize(text):
    """Lowercase, replace URLs with a literal <url> token, then extract
    Unicode word / #hashtag / @mention tokens. Returns a list of str.
    None/empty text yields []."""
    if not text:
        return []
    text = URL_RE.sub(" " + _URL_PLACEHOLDER + " ", text)
    text = text.lower()
    tokens = []
    for match in TOKEN_RE.finditer(text):
        tok = match.group(0)
        # A bare "#" or "@" with no following word char shouldn't happen
        # given the regex, but guard anyway rather than emit a lone symbol.
        if tok in ("#", "@"):
            continue
        if tok == _URL_PLACEHOLDER:
            tok = "<url>"
        tokens.append(tok)
    return tokens


# --------------------------------------------------------------------------
# Streaming, re-iterable corpus
# --------------------------------------------------------------------------

class StreamingCorpus:
    """Re-iterable TaggedDocument stream over the reply corpus.

    Every call to __iter__() opens its own fresh read-only sqlite
    connection and re-runs the query from scratch -- required because
    gensim's Doc2Vec.train() iterates corpus_iterable once per epoch, and a
    one-shot generator would silently yield nothing after the first pass.
    Tags are the post's URI (stable across limited/unlimited runs, unlike a
    positional index).
    """

    def __init__(self, store_path, limit=None):
        self.store_path = store_path
        self.limit = limit

    def __iter__(self):
        conn = sqlite3.connect(ro_uri(self.store_path), uri=True)
        try:
            query = REPLIES_QUERY
            if self.limit is not None:
                query += " LIMIT %d" % int(self.limit)
            cursor = conn.execute(query)
            for uri, text in cursor:
                yield TaggedDocument(words=tokenize(text), tags=[uri])
        finally:
            conn.close()


# --------------------------------------------------------------------------
# Checkpointing
# --------------------------------------------------------------------------

def checkpoint_path(out_dir, epoch):
    return os.path.join(out_dir, "%s%03d.model" % (CHECKPOINT_PREFIX, epoch))


def find_latest_checkpoint(out_dir):
    """Return (epoch_number, path) for the highest-numbered checkpoint found
    in out_dir, or (0, None) if none exist."""
    pattern = os.path.join(out_dir, "%s???.model" % CHECKPOINT_PREFIX)
    candidates = []
    for path in glob.glob(pattern):
        base = os.path.basename(path)
        match = re.match(r"%s(\d+)\.model$" % re.escape(CHECKPOINT_PREFIX), base)
        if match:
            candidates.append((int(match.group(1)), path))
    if not candidates:
        return 0, None
    return max(candidates, key=lambda pair: pair[0])


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


# --------------------------------------------------------------------------
# now_iso helper
# --------------------------------------------------------------------------

def now_iso():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


# --------------------------------------------------------------------------
# Training
# --------------------------------------------------------------------------

def default_workers():
    return max(1, (multiprocessing.cpu_count() or 1) - 2)


def apply_low_priority():
    """Best-effort os.nice(10) -- never abort training if the platform
    doesn't support it (e.g. Windows has no os.nice)."""
    try:
        os.nice(10)
    except (AttributeError, OSError):
        pass


def run_train(store_path, out_dir, epochs=DEFAULT_EPOCHS, vector_size=DEFAULT_VECTOR_SIZE,
              window=DEFAULT_WINDOW, min_count=DEFAULT_MIN_COUNT, dm=DEFAULT_DM,
              dbow_words=DEFAULT_DBOW_WORDS, seed=DEFAULT_SEED, workers=None,
              limit=None, resume=False, work_seconds=pacing.DEFAULT_WORK_SECONDS,
              cool_seconds=pacing.DEFAULT_COOL_SECONDS, sleep_fn=time.sleep,
              pacer=None):
    """Train (or resume training) a Doc2Vec model, checkpointing after every
    epoch. Returns a dict describing what happened this run, including the
    paths of the final model/metadata once all requested epochs are done.
    """
    apply_low_priority()

    os.makedirs(out_dir, exist_ok=True)
    workers = workers if workers is not None else default_workers()

    corpus = StreamingCorpus(store_path, limit=limit)
    row_count = fetch_row_count(store_path, limit=limit)

    start_epoch, ckpt_path = (find_latest_checkpoint(out_dir) if resume else (0, None))

    if ckpt_path is not None:
        model = Doc2Vec.load(ckpt_path)
    else:
        model = Doc2Vec(
            vector_size=vector_size, window=window, min_count=min_count,
            dm=dm, dbow_words=dbow_words, seed=seed, workers=workers,
        )
        model.build_vocab(corpus_iterable=corpus)
        start_epoch = 0

    if pacer is None:
        pacer = pacing.Pacer(
            work_seconds=work_seconds, cool_seconds=cool_seconds, sleep_fn=sleep_fn,
        )

    started_at = now_iso()
    wall_start = time.monotonic()

    epochs_trained_this_run = 0
    current_epoch = start_epoch
    while current_epoch < epochs:
        current_epoch += 1
        model.train(corpus_iterable=corpus, total_examples=model.corpus_count, epochs=1)
        model.save(checkpoint_path(out_dir, current_epoch))
        epochs_trained_this_run += 1
        pacer.maybe_pace()

    ended_at = now_iso()
    wall_time = time.monotonic() - wall_start

    final_model_path = os.path.join(out_dir, FINAL_MODEL_NAME)
    model.save(final_model_path)

    metadata = {
        "corpus_row_count": row_count,
        "vocabulary_size": len(model.wv.key_to_index),
        "hyperparameters": {
            "vector_size": vector_size,
            "window": window,
            "min_count": min_count,
            "dm": dm,
            "dbow_words": dbow_words,
            "epochs": epochs,
        },
        "gensim_version": gensim.__version__,
        "seed": seed,
        "workers": workers,
        "fully_reproducible": workers == 1,
        "reproducibility_note": (
            "gensim Doc2Vec/Word2Vec training is only bit-for-bit "
            "reproducible with workers=1 (multi-threaded training has "
            "nondeterministic thread interleaving even with a fixed seed). "
            "This run used workers=%d, so it is %s."
        ) % (
            workers,
            "fully reproducible" if workers == 1 else
            "seed-reproducible-in-expectation but not bit-for-bit reproducible",
        ),
        "tokenisation": (
            "lowercase, Unicode-aware \\w+ word tokens; #hashtags and "
            "@mentions kept as single tokens; URLs collapsed to a literal "
            "<url> token; no stemming (corpus is bilingual EN/DE and "
            "stemming one language and not the other would bias the "
            "vocabulary)."
        ),
        "started_at": started_at,
        "ended_at": ended_at,
        "wall_time_seconds": wall_time,
        "store": os.path.abspath(store_path),
        "limit": limit,
        "notes": (
            "This model is UNSUPERVISED and contains no label information "
            "whatsoever -- it was trained only on ZPOST.ZTEXT reply text, "
            "never on any annotation/prediction table."
        ),
        "pacing": pacer.summary(),
    }
    metadata_path = os.path.join(out_dir, FINAL_METADATA_NAME)

    def write_meta(handle):
        json.dump(metadata, handle, ensure_ascii=False, indent=2)
        handle.write("\n")

    write_atomic(metadata_path, write_meta)

    return {
        "final_model_path": final_model_path,
        "metadata_path": metadata_path,
        "metadata": metadata,
        "start_epoch": start_epoch + 1,
        "epochs_trained_this_run": epochs_trained_this_run,
        "final_epoch": current_epoch,
    }


# --------------------------------------------------------------------------
# Probing (label-free sanity checks)
# --------------------------------------------------------------------------

def load_model(path):
    return Doc2Vec.load(path)


def probe_words(model, words, topn=10):
    """For each word, return {"neighbours": [(word, sim), ...]} if in
    vocabulary, else {"error": "..."} -- never raises on an OOV word."""
    results = {}
    for word in words:
        if word not in model.wv.key_to_index:
            results[word] = {"error": "out of vocabulary"}
            continue
        neighbours = model.wv.most_similar(word, topn=topn)
        results[word] = {"neighbours": [[w, float(s)] for w, s in neighbours]}
    return results


def _cosine_similarity(a, b):
    import numpy as np
    a = np.asarray(a, dtype="float64")
    b = np.asarray(b, dtype="float64")
    denom = (np.linalg.norm(a) * np.linalg.norm(b))
    if denom == 0:
        return 0.0
    return float(np.dot(a, b) / denom)


def probe_pairs(model, pairs, steps=50):
    """pairs: list of {"a": text, "b": text}. Returns a list of
    {"a":..., "b":..., "cosine_similarity": float} using model.infer_vector
    on freshly tokenized text (never touches training tags)."""
    results = []
    for pair in pairs:
        vec_a = model.infer_vector(tokenize(pair["a"]), epochs=steps)
        vec_b = model.infer_vector(tokenize(pair["b"]), epochs=steps)
        results.append({
            "a": pair["a"],
            "b": pair["b"],
            "cosine_similarity": _cosine_similarity(vec_a, vec_b),
        })
    return results


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def build_parser():
    parser = argparse.ArgumentParser(
        description="Train (unsupervised) or probe a Doc2Vec model on the BlueX reply corpus."
    )
    sub = parser.add_subparsers(dest="command", required=True)

    train_p = sub.add_parser("train", help="train a Doc2Vec model on the reply corpus")
    train_p.add_argument("--store", default=None,
                          help="path to default.store; defaults to $BLUEX_STORE_DIR "
                               "then /Volumes/Eregion/bluex-data")
    train_p.add_argument("--out-dir", default=DEFAULT_OUT_DIR)
    train_p.add_argument("--limit", type=int, default=None,
                          help="cap the number of replies streamed (for smoke/throughput runs)")
    train_p.add_argument("--epochs", type=int, default=DEFAULT_EPOCHS)
    train_p.add_argument("--vector-size", type=int, default=DEFAULT_VECTOR_SIZE)
    train_p.add_argument("--window", type=int, default=DEFAULT_WINDOW)
    train_p.add_argument("--min-count", type=int, default=DEFAULT_MIN_COUNT)
    train_p.add_argument("--dm", type=int, default=DEFAULT_DM, choices=[0, 1])
    train_p.add_argument("--dbow-words", type=int, default=DEFAULT_DBOW_WORDS, choices=[0, 1])
    train_p.add_argument("--seed", type=int, default=DEFAULT_SEED)
    train_p.add_argument("--workers", type=int, default=None,
                          help="default: max(1, cpu_count() - 2). Use --workers 1 for "
                               "full bit-for-bit reproducibility (see module docstring).")
    train_p.add_argument("--resume", action="store_true",
                          help="resume from the newest checkpoint in --out-dir")
    train_p.add_argument("--work-seconds", type=float, default=pacing.DEFAULT_WORK_SECONDS)
    train_p.add_argument("--cool-seconds", type=float, default=pacing.DEFAULT_COOL_SECONDS,
                          help="0 disables all pacing (duty cycle + thermal escalation)")

    probe_p = sub.add_parser("probe", help="label-free sanity checks on a trained model")
    probe_p.add_argument("--model", required=True, help="path to a saved Doc2Vec model")
    probe_p.add_argument("--words", nargs="*", default=[],
                          help="probe words to look up nearest neighbours for")
    probe_p.add_argument("--topn", type=int, default=10)
    probe_p.add_argument("--pairs-file", default=None,
                          help="JSON file: a list of {\"a\": text, \"b\": text} pairs "
                               "(near-duplicate or unrelated sentence pairs)")

    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.command == "train":
        store_dir = args.store or DEFAULT_STORE_DIR
        store_path = store_dir if store_dir.endswith(".store") else default_store_path(store_dir)
        if not os.path.exists(store_path):
            parser.error("store not found: %s" % store_path)

        result = run_train(
            store_path=store_path, out_dir=args.out_dir, epochs=args.epochs,
            vector_size=args.vector_size, window=args.window, min_count=args.min_count,
            dm=args.dm, dbow_words=args.dbow_words, seed=args.seed, workers=args.workers,
            limit=args.limit, resume=args.resume,
            work_seconds=args.work_seconds, cool_seconds=args.cool_seconds,
        )
        print("wrote %s" % result["final_model_path"])
        print("wrote %s" % result["metadata_path"])
        print(json.dumps(result["metadata"], ensure_ascii=False, indent=2))
        return 0

    if args.command == "probe":
        model = load_model(args.model)
        if args.words:
            word_results = probe_words(model, args.words, topn=args.topn)
            print(json.dumps(word_results, ensure_ascii=False, indent=2))
        if args.pairs_file:
            with open(args.pairs_file, "r", encoding="utf-8") as handle:
                pairs = json.load(handle)
            pair_results = probe_pairs(model, pairs)
            print(json.dumps(pair_results, ensure_ascii=False, indent=2))
        if not args.words and not args.pairs_file:
            print(json.dumps({"vocabulary_size": len(model.wv.key_to_index)}, indent=2))
        return 0

    parser.error("unknown command")
    return 1


if __name__ == "__main__":
    sys.exit(main())
