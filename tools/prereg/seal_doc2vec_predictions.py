#!/usr/bin/env python3
"""Post-hoc, honestly-scoped seal of the doc2vec_lr committee member.

WHY THIS EXISTS
----------------
tools/prereg/seal_predictions.py sealed TWO models (incivility_toxicity,
tfidf_lr_hate_vs_rude) over the full reply-post pool BEFORE any human Stage
0 label existed -- a true pre-registration. `doc2vec_lr` (see
tools/committee/score_committee.py) did not exist at that time, so its
predictions are NOT pre-registered for whichever posts got labelled in the
meantime. Pretending otherwise would be exactly the "checked the model
after seeing labels" hindsight problem seal_predictions.py's own docstring
warns against.

This script draws an honest line instead of fudging it:
  * For posts a human has ALREADY labelled by the time this runs, doc2vec_lr
    evaluation on them is POST-HOC and must always be reported as such --
    this script does not even seal predictions for them; they are excluded
    from the sealed file entirely.
  * For every other post doc2vec_lr can score (every URI in the doc2vec
    model's vocabulary, per tools/committee/score_committee.py's
    "score every URI present in model.dv"), predictions ARE sealed here,
    BEFORE any future label on those specific posts exists -- a real
    pre-registration for the still-unlabelled pool.

HOW THE EXCLUSION LIST IS OBTAINED
-------------------------------------
By default this script reads the store's human-annotation table to get the
SET OF URIS already labelled -- and NOTHING else. `fetch_labelled_uris_readonly`
below is the only place that happens; it selects the post join column and
the post's URI, never any label/speech-class/confidence/reasoning value. A
`--exclude-uris-file` argument is also accepted, which skips that store read
entirely (a newline-delimited file of URIs to exclude, supplied by whoever
runs this) -- pass it if you would rather this script never touch the store
for that purpose at all.

The manifest records plainly which method produced the exclusion set.

SAFETY
------
default.store is opened strictly read-only (file:...?mode=ro; never
immutable=1). This script never writes to that store.
"""
import argparse
import datetime as dt
import gzip
import hashlib
import json
import os
import sqlite3
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "labelling"))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "committee"))

import sklearn  # noqa: E402

import seal_predictions as sp  # noqa: E402 -- ro_uri, load_post_labels, classify_subject, write_atomic, sha256_file
import score_committee as scmt  # noqa: E402 -- build_doc2vec_training_arrays, train_doc2vec_lr, score_doc2vec_lr


DEFAULT_STORE_DIR = os.environ.get("BLUEX_STORE_DIR", "/Volumes/Eregion/bluex-data")
DEFAULT_LABELS_DIR = "/Volumes/Eregion/bluex-labels"
DEFAULT_DOC2VEC_MODEL = scmt.DEFAULT_DOC2VEC_MODEL
DEFAULT_PREDICTIONS_DIR = "/Volumes/Eregion/bluex-data/predictions"
DEFAULT_MANIFEST_DIR = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "docs", "prereg"
)
DEFAULT_RANDOM_STATE = sp.DEFAULT_RANDOM_STATE

MODEL_D2V = "doc2vec_lr"
MEANING_D2V = (
    "P(hate | one of {hate, rude}) -- NOT P(hate) on arbitrary text. "
    "LogisticRegression trained on doc2vec-final.model document vectors "
    "(200-dim, tagged by post URI) for the same moderator-labelled "
    "intolerant/threat/extremist/intolerant-race (positive) vs rude "
    "(negative) split used by tfidf_lr_hate_vs_rude. This member did NOT "
    "exist when the original Stage 0 pre-registration was sealed; its "
    "evaluation on posts labelled before THIS seal's timestamp is "
    "necessarily POST-HOC and must be reported as such -- those posts are "
    "excluded from this sealed file entirely, not scored retroactively."
)


def now_iso():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def now_stamp():
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H%M%SZ")


# --------------------------------------------------------------------------
# Exclusion: URIs only, no label values -- a separate, clearly-commented step
# --------------------------------------------------------------------------

def fetch_labelled_uris_readonly(conn):
    """Returns the SET of post URIs that already have at least one human
    annotation. Reads ONLY the join column (ZANNOTATION.ZPOST -> ZPOST.Z_PK)
    and ZPOST.ZURI -- never ZSPEECHCLASS, ZCONFIDENCE, ZREASONING, or any
    other label VALUE. This is the one place in this script that touches
    the human annotation table, and it reads identity (which posts were
    labelled), never content (what the label says)."""
    a_cols = sp.br.column_map(conn, "ZANNOTATION") if hasattr(sp, "br") else None
    if a_cols is None:
        # seal_predictions doesn't re-export br as an attribute; fall back
        # to a direct, equally minimal column probe.
        cur = conn.execute("PRAGMA table_info(ZANNOTATION)")
        cols = {row[1] for row in cur.fetchall()}
        if "ZPOST" not in cols:
            return set()
    rows = conn.execute(
        "SELECT DISTINCT p.ZURI FROM ZANNOTATION a JOIN ZPOST p ON a.ZPOST = p.Z_PK"
    ).fetchall()
    return {r[0] for r in rows if r[0] is not None}


def load_exclusion_set(exclude_uris_file, conn):
    if exclude_uris_file:
        with open(exclude_uris_file, "r", encoding="utf-8") as f:
            return {line.strip() for line in f if line.strip()}, "cli_file"
    return fetch_labelled_uris_readonly(conn), "store_readonly_uris_only"


# --------------------------------------------------------------------------
# Pool arithmetic
# --------------------------------------------------------------------------

def unlabelled_pool(population, excluded_uris):
    return set(population) - set(excluded_uris)


# --------------------------------------------------------------------------
# Sealed file writer
# --------------------------------------------------------------------------

def write_sealed_doc2vec_file(out_path, scores):
    """scores: uri -> float, ALREADY restricted to the unlabelled pool by
    the caller. Writes one record per uri; no record is ever written for an
    excluded (already-labelled) uri."""
    tmp_path = out_path + ".partial"
    try:
        with gzip.open(tmp_path, "wt", encoding="utf-8") as gz:
            for uri, score in scores.items():
                gz.write(json.dumps(
                    {"uri": uri, "model": MODEL_D2V, "score": float(score), "meaning": MEANING_D2V},
                    ensure_ascii=False) + "\n")
        os.replace(tmp_path, out_path)
    except (KeyboardInterrupt, BaseException):
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)
        raise


# --------------------------------------------------------------------------
# Manifest
# --------------------------------------------------------------------------

def build_manifest(sealed_file, sha256, n_sealed, n_excluded_labelled,
                    exclusion_source, training_counts, random_state,
                    sklearn_version, gensim_version, d2v_model_path, labels_file):
    return {
        "sealed_file": sealed_file,
        "sha256": sha256,
        "n_sealed": n_sealed,
        "n_excluded_labelled": n_excluded_labelled,
        "exclusion_source": exclusion_source,
        "created_at": now_iso(),
        "model": MODEL_D2V,
        "meaning": MEANING_D2V,
        "intent": (
            "Pre-registration for doc2vec_lr, scoped honestly: this model did "
            "not exist when the original two-model Stage 0 seal "
            "(docs/prereg/sealed-stage0-*.json) was made, so its predictions "
            "for the %d post(s) already carrying a human label at the time "
            "this manifest was created are POST-HOC and must be reported as "
            "such -- they are NOT included in the sealed file below at all. "
            "The %d sealed predictions cover only posts with no human label "
            "yet, exactly like the original seal, so comparing them against "
            "FUTURE labels on those specific posts is unbiased evidence."
            % (n_excluded_labelled, n_sealed)
        ),
        "manifest_is_tamper_evident_anchor": (
            "This manifest is committed to git. Its git commit timestamp is "
            "the tamper-evident proof that these predictions existed before "
            "any human label was applied to the posts they cover -- provable "
            "independent of anything on this machine. This file is never "
            "edited after being committed."
        ),
        "training": {
            "labels_file": labels_file,
            "training_counts": training_counts,
            "random_state": random_state,
            "sklearn_version": sklearn_version,
            "gensim_version": gensim_version,
            "d2v_model_path": d2v_model_path,
            "classifier": "LogisticRegression(max_iter=2000, class_weight='balanced')",
        },
        "does_not_modify_original_seal": (
            "docs/prereg/sealed-stage0-*.json and its .jsonl.gz are NOT "
            "touched or replaced by this script -- this is a separate, "
            "additional manifest for the third member only."
        ),
    }


# --------------------------------------------------------------------------
# seal
# --------------------------------------------------------------------------

def run_seal(store_path, labels_dir, labels_file, doc2vec_model_path,
             predictions_dir, manifest_dir, random_state, exclude_uris_file):
    from gensim.models.doc2vec import Doc2Vec
    import gensim

    conn = sqlite3.connect(sp.ro_uri(store_path), uri=True)
    try:
        excluded_uris, exclusion_source = load_exclusion_set(exclude_uris_file, conn)
        print("excluded (already human-labelled) uris: %d (source=%s)"
              % (len(excluded_uris), exclusion_source), file=sys.stderr)

        labels_path = labels_file or sp.find_latest_complete_posts_label_file(labels_dir)
        post_labels = sp.load_post_labels(labels_path)
    finally:
        conn.close()

    print("loading doc2vec model from %s ..." % doc2vec_model_path, file=sys.stderr)
    d2v_model = Doc2Vec.load(doc2vec_model_path)

    x, y, training_counts = scmt.build_doc2vec_training_arrays(d2v_model, post_labels)
    if len(set(y)) < 2:
        raise SystemExit(
            "cannot train doc2vec_lr: need at least one positive AND one "
            "hard_negative labelled post present in the doc2vec vocabulary, "
            "found counts=%s" % training_counts
        )
    clf = scmt.train_doc2vec_lr(x, y, random_state)

    population = set(d2v_model.dv.index_to_key)
    pool = unlabelled_pool(population, excluded_uris)
    print("doc2vec vocabulary: %d uris; unlabelled pool to seal: %d; excluded: %d"
          % (len(population), len(pool), len(population) - len(pool)), file=sys.stderr)

    scores = scmt.score_doc2vec_lr(clf, d2v_model, pool)

    os.makedirs(predictions_dir, exist_ok=True)
    os.makedirs(manifest_dir, exist_ok=True)
    stamp = now_stamp()
    out_path = os.path.join(predictions_dir, "sealed-stage0-doc2vec-%s.jsonl.gz" % stamp)
    write_sealed_doc2vec_file(out_path, scores)

    sha256 = sp.sha256_file(out_path)
    manifest = build_manifest(
        sealed_file=os.path.basename(out_path),
        sha256=sha256,
        n_sealed=len(scores),
        n_excluded_labelled=len(population) - len(pool),
        exclusion_source=exclusion_source,
        training_counts=training_counts,
        random_state=random_state,
        sklearn_version=sklearn.__version__,
        gensim_version=gensim.__version__,
        d2v_model_path=doc2vec_model_path,
        labels_file=os.path.basename(labels_path),
    )
    manifest_path = os.path.join(manifest_dir, "sealed-stage0-doc2vec-%s.json" % stamp)
    sp.write_atomic(manifest_path, lambda h: (json.dump(manifest, h, ensure_ascii=False, indent=2), h.write("\n")))

    return out_path, manifest_path, manifest


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--store", default=None)
    parser.add_argument("--labels-dir", default=DEFAULT_LABELS_DIR)
    parser.add_argument("--labels-file", default=None)
    parser.add_argument("--doc2vec-model", default=DEFAULT_DOC2VEC_MODEL)
    parser.add_argument("--predictions-dir", default=DEFAULT_PREDICTIONS_DIR)
    parser.add_argument("--manifest-dir", default=DEFAULT_MANIFEST_DIR)
    parser.add_argument("--random-state", type=int, default=DEFAULT_RANDOM_STATE)
    parser.add_argument("--exclude-uris-file", default=None,
                         help="newline-delimited file of URIs to exclude, "
                              "instead of reading the store's human "
                              "annotation table for that purpose")
    args = parser.parse_args(argv)

    store_dir = args.store or DEFAULT_STORE_DIR
    store_path = store_dir if store_dir.endswith(".store") else os.path.join(store_dir, "default.store")
    if not os.path.exists(store_path):
        parser.error("store not found: %s" % store_path)

    out_path, manifest_path, manifest = run_seal(
        store_path, args.labels_dir, args.labels_file, args.doc2vec_model,
        args.predictions_dir, args.manifest_dir, args.random_state,
        args.exclude_uris_file,
    )
    print("wrote %s" % out_path)
    print("wrote %s" % manifest_path)
    print(json.dumps(manifest, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
