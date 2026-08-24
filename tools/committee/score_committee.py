#!/usr/bin/env python3
"""Rank-normalised consensus committee over three decorrelated members.

WHY THIS EXISTS
----------------
The committee is not a hate detector. Its job is to (a) provide decorrelated
per-post signals whose *disagreement* is informative, and (b) define strata
for a future weighted-sampling labelling round (docs/superpowers/specs/
2026-08-22-pre-label-analysis-and-consensus-labelling.md S3). Every member is
trained WITHOUT human gold labels -- only Bluesky moderation labels as
distant supervision -- so the human annotation table stays held-out gold.

This module NEVER reads the human annotation table. NoAnnotationGuardTests
in test_score_committee.py greps this file's own source for the literal
name of that table and fails the build if it ever appears here. Any need to
exclude already-labelled posts (e.g. for the doc2vec_lr post-hoc seal) lives
in a *separate* script, never in this one.

THE THREE MEMBERS
------------------
  * `incivility_toxicity` -- the `toxicity` head of unitary/unbiased-toxic-
    roberta, joined from tools/incivility/score_corpus.py's output
    (incivility-scores-*.jsonl). ALL score files are merged (not just the
    newest) via seal_predictions.merge_incivility_scores, reused verbatim.
    Posts never scored are recorded as score=None -- never imputed.
  * `tfidf_lr` -- TF-IDF + LogisticRegression trained on active
    (non-negated) moderation post labels: intolerant/threat/extremist/
    intolerant-race (positive) vs rude (hard negative). Training and
    scoring reuse tools/prereg/seal_predictions.py's build_training_set,
    train_tfidf_lr and predict_proba_positive verbatim -- this is the exact
    training procedure behind the sealed Stage 0 pre-registration, and must
    not be reimplemented or altered.
  * `doc2vec_lr` -- LogisticRegression trained on the SAME moderation-label
    split, but on doc2vec document vectors (looked up by URI tag in
    /Volumes/Eregion/bluex-data/embeddings/doc2vec-final.model, no
    inference needed) instead of TF-IDF features.

SCALE PROBLEM -- SOLVED BY RANK NORMALISATION, NOT CALIBRATION
------------------------------------------------------------------
The members' raw scores are not comparable (a toxicity probability, and two
"P(hate | one of {hate, rude})" scores from different feature spaces). We do
not invent a calibration. Instead each member's scores are rank-normalised
to a percentile WITHIN the population it actually scored (see
`rank_percentiles`), and mean_pct/spread_pct/n_members are computed only
over the percentiles a post actually has (see `aggregate_row`) -- a missing
member is excluded from the average, never treated as 0 or 0.5.

SAFETY
------
default.store is opened strictly read-only (file:...?mode=ro; never
immutable=1 -- WAL-blind, has silently returned zero rows on a populated
store elsewhere in this project). This tool never writes to that store, and
never touches /Volumes/Eregion/bluex-data/social/ (the live Telegram
backfill).
"""
import argparse
import datetime as dt
import json
import os
import sqlite3
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "prereg"))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "labelling"))

import numpy as np  # noqa: E402
from scipy.stats import rankdata, spearmanr  # noqa: E402
from sklearn.linear_model import LogisticRegression  # noqa: E402
import sklearn  # noqa: E402

import seal_predictions as sp  # noqa: E402 -- reused training/merge logic, verbatim


DEFAULT_STORE_DIR = os.environ.get("BLUEX_STORE_DIR", "/Volumes/Eregion/bluex-data")
DEFAULT_INCIVILITY_DIR = "/Volumes/Eregion/bluex-incivility"
DEFAULT_LABELS_DIR = "/Volumes/Eregion/bluex-labels"
DEFAULT_DOC2VEC_MODEL = "/Volumes/Eregion/bluex-data/embeddings/doc2vec-final.model"
DEFAULT_DB_PATH = "/Volumes/Eregion/bluex-data/committee/committee.db"
DEFAULT_REPORT_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..",
    "docs", "superpowers", "reports", "consensus-committee-report.md",
)
DEFAULT_RANDOM_STATE = sp.DEFAULT_RANDOM_STATE

MODEL_TOX = "incivility_toxicity"
MODEL_TFIDF = "tfidf_lr"
MODEL_D2V = "doc2vec_lr"

NO_HUMAN_ANNOTATION_STATEMENT = (
    "No human annotation was read to produce this run. No query touched the "
    "store's human annotation table or any human-labelled data. All three "
    "committee members are trained exclusively on Bluesky moderation labels "
    "(distant supervision) harvested into "
    "bluex-labels/label-harvest-posts-*.jsonl, or are fully unsupervised "
    "(doc2vec embedding). Human gold labels remain held out."
)


def ro_uri(path):
    """Read-only SQLite URI. Deliberately NOT immutable=1."""
    return sp.ro_uri(path)


def now_iso():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


# --------------------------------------------------------------------------
# Rank normalisation
# --------------------------------------------------------------------------

def rank_percentiles(scores):
    """uri -> score (all non-null, non-empty caller-filtered) -> uri -> pct
    in [0, 100].

    Average-rank method (ties share the mean of their ranks), then mapped
    linearly so the minimum score is percentile 0 and the maximum is
    percentile 100: pct = (rank - 1) / (n - 1) * 100. A population of one
    value has no spread to rank within, so it is defined as 50.0 (neither
    extreme). Every value in `scores` must be a real number -- callers are
    responsible for stripping None/missing entries before calling this;
    passing None raises, so a silent-imputation bug fails loudly here
    instead of downstream.
    """
    if any(v is None for v in scores.values()):
        raise ValueError("rank_percentiles received a None score; filter it out first")
    uris = list(scores.keys())
    n = len(uris)
    if n == 0:
        return {}
    if n == 1:
        return {uris[0]: 50.0}
    values = np.array([scores[u] for u in uris], dtype=float)
    ranks = rankdata(values, method="average")  # 1..n, ties averaged
    pct = (ranks - 1.0) / (n - 1.0) * 100.0
    return {u: float(p) for u, p in zip(uris, pct)}


# --------------------------------------------------------------------------
# Per-post aggregation: mean_pct / spread_pct / n_members
# --------------------------------------------------------------------------

def aggregate_row(member_pct):
    """member_pct: dict of member_name -> pct|None (whatever members exist).
    Returns {"n_members": int, "mean_pct": float|None, "spread_pct": float|None}.
    Missing (None) members are excluded entirely, never imputed as 0 or 0.5.
    spread_pct is the POPULATION standard deviation (ddof=0) of the
    available percentiles.
    """
    available = [v for v in member_pct.values() if v is not None]
    n = len(available)
    if n == 0:
        return {"n_members": 0, "mean_pct": None, "spread_pct": None}
    mean_pct = sum(available) / n
    if n == 1:
        spread_pct = 0.0
    else:
        variance = sum((v - mean_pct) ** 2 for v in available) / n
        spread_pct = variance ** 0.5
    return {"n_members": n, "mean_pct": mean_pct, "spread_pct": spread_pct}


def build_rows(all_uris, tox_pct, tfidf_pct, d2v_pct, tox_raw, tfidf_raw, d2v_raw):
    """Assemble the full per-uri row dict (raw + pct per member + aggregate),
    for every uri in `all_uris` (the union of everything any member scored).
    """
    rows = {}
    for uri in all_uris:
        member_pct = {
            "tox": tox_pct.get(uri),
            "tfidf": tfidf_pct.get(uri),
            "d2v": d2v_pct.get(uri),
        }
        agg = aggregate_row(member_pct)
        rows[uri] = {
            "tox": tox_raw.get(uri),
            "tox_pct": member_pct["tox"],
            "tfidf": tfidf_raw.get(uri),
            "tfidf_pct": member_pct["tfidf"],
            "d2v": d2v_raw.get(uri),
            "d2v_pct": member_pct["d2v"],
            "n_members": agg["n_members"],
            "mean_pct": agg["mean_pct"],
            "spread_pct": agg["spread_pct"],
        }
    return rows


# --------------------------------------------------------------------------
# Spearman on the intersection two members both scored
# --------------------------------------------------------------------------

def spearman_pairwise(a, b):
    """a, b: uri -> score (raw or pct -- Spearman is rank-invariant to a
    monotonic transform, so either works identically). Returns (rho, n)
    over the intersection of uris present (non-null) in both. n < 2 -> rho
    is None (undefined), n reported honestly regardless."""
    common = [u for u in a if u in b]
    n = len(common)
    if n < 2:
        return None, n
    xa = [a[u] for u in common]
    xb = [b[u] for u in common]
    rho, _p = spearmanr(xa, xb)
    if rho is None or (isinstance(rho, float) and rho != rho):
        return None, n
    return float(rho), n


def jaccard(set_a, set_b):
    if not set_a and not set_b:
        return None
    union = set_a | set_b
    if not union:
        return None
    return len(set_a & set_b) / len(union)


# --------------------------------------------------------------------------
# Member 1: incivility_toxicity -- reuse seal_predictions' multi-file merge
# --------------------------------------------------------------------------

def load_toxicity_scores(incivility_dir):
    """uri -> score (float), merged across ALL incivility-scores-*.jsonl
    files -- never just the newest. Reuses seal_predictions.py's merge
    verbatim (that reuse is load-bearing: a prior mistake in this project
    used only the newest file and silently dropped ~60% of scores)."""
    files = sp.find_incivility_score_files(incivility_dir)
    merged = sp.merge_incivility_scores(files)
    return {uri: v[0] for uri, v in merged.items() if v[0] is not None}, files, merged


# --------------------------------------------------------------------------
# Member 2: tfidf_lr -- reuse seal_predictions' training verbatim
# --------------------------------------------------------------------------

def train_and_score_tfidf(conn, labels_path, pool_uris, pool_texts, random_state):
    texts, y, counts = sp.build_training_set(conn, labels_path)
    if len(set(y)) < 2:
        raise SystemExit(
            "cannot train tfidf_lr: need at least one positive AND one "
            "hard_negative labelled post, found counts=%s" % counts
        )
    vec, clf = sp.train_tfidf_lr(texts, y, random_state)
    scores = sp.predict_proba_positive(vec, clf, pool_texts)
    return {uri: float(s) for uri, s in zip(pool_uris, scores)}, counts


# --------------------------------------------------------------------------
# Member 3: doc2vec_lr -- NEW, trained on the same label split
# --------------------------------------------------------------------------

def build_doc2vec_training_arrays(d2v_model, post_labels):
    """post_labels: uri -> sorted list of non-negated label values (from
    sp.load_post_labels). Returns (X, y, counts) using ONLY uris present in
    the doc2vec model's vocabulary (model.dv) -- a labelled post the
    embedding never saw contributes nothing, silently, rather than crashing
    the whole training run."""
    positive_uris = sorted(u for u, vals in post_labels.items()
                            if sp.classify_subject(vals) == "positive")
    hard_negative_uris = sorted(u for u, vals in post_labels.items()
                                 if sp.classify_subject(vals) == "hard_negative")

    pos_vecs = [d2v_model.dv[u] for u in positive_uris if u in d2v_model.dv]
    neg_vecs = [d2v_model.dv[u] for u in hard_negative_uris if u in d2v_model.dv]

    x = np.array(pos_vecs + neg_vecs, dtype=float)
    y = [1] * len(pos_vecs) + [0] * len(neg_vecs)
    counts = {"positive": len(pos_vecs), "hard_negative": len(neg_vecs)}
    return x, y, counts


def train_doc2vec_lr(x, y, random_state):
    clf = LogisticRegression(max_iter=2000, class_weight="balanced", random_state=random_state)
    clf.fit(x, y)
    return clf


def score_doc2vec_lr(clf, d2v_model, uris):
    """uris: iterable, all already confirmed present in d2v_model.dv by the
    caller. Returns uri -> float score, batched to bound peak memory."""
    scores = {}
    uris = list(uris)
    batch = 100_000
    for i in range(0, len(uris), batch):
        chunk = uris[i:i + batch]
        x = np.array([d2v_model.dv[u] for u in chunk], dtype=float)
        proba = clf.predict_proba(x)[:, 1]
        for uri, p in zip(chunk, proba):
            scores[uri] = float(p)
    return scores


# --------------------------------------------------------------------------
# meta
# --------------------------------------------------------------------------

def build_meta(tox_model_id, tox_model_revision, tox_source_files,
                tfidf_random_state, tfidf_training_counts, tfidf_labels_file,
                d2v_random_state, d2v_training_counts, d2v_model_path,
                sklearn_version, gensim_version, row_counts):
    return {
        "created_at": now_iso(),
        "no_human_annotation_statement": NO_HUMAN_ANNOTATION_STATEMENT,
        "tox_model_id": tox_model_id,
        "tox_model_revision": tox_model_revision,
        "tox_source_files": list(tox_source_files),
        "tfidf_random_state": tfidf_random_state,
        "tfidf_training_counts": tfidf_training_counts,
        "tfidf_labels_file": tfidf_labels_file,
        "d2v_random_state": d2v_random_state,
        "d2v_training_counts": d2v_training_counts,
        "d2v_model_path": d2v_model_path,
        "sklearn_version": sklearn_version,
        "gensim_version": gensim_version,
        "row_counts": row_counts,
    }


# --------------------------------------------------------------------------
# DB writer -- idempotent (uri is PRIMARY KEY; INSERT OR REPLACE)
# --------------------------------------------------------------------------

SCHEMA_SCORES = """
CREATE TABLE IF NOT EXISTS scores (
    uri TEXT PRIMARY KEY,
    tox REAL, tox_pct REAL,
    tfidf REAL, tfidf_pct REAL,
    d2v REAL, d2v_pct REAL,
    n_members INTEGER,
    mean_pct REAL,
    spread_pct REAL
)
"""
SCHEMA_META = """
CREATE TABLE IF NOT EXISTS meta (
    key TEXT PRIMARY KEY,
    value TEXT
)
"""


def write_committee_db(db_path, rows, meta):
    os.makedirs(os.path.dirname(db_path), exist_ok=True)
    conn = sqlite3.connect(db_path)
    try:
        conn.execute(SCHEMA_SCORES)
        conn.execute(SCHEMA_META)
        conn.execute("CREATE INDEX IF NOT EXISTS idx_scores_mean_pct ON scores(mean_pct)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_scores_spread_pct ON scores(spread_pct)")
        conn.executemany(
            "INSERT INTO scores (uri, tox, tox_pct, tfidf, tfidf_pct, d2v, d2v_pct, "
            "n_members, mean_pct, spread_pct) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) "
            "ON CONFLICT(uri) DO UPDATE SET "
            "tox=excluded.tox, tox_pct=excluded.tox_pct, "
            "tfidf=excluded.tfidf, tfidf_pct=excluded.tfidf_pct, "
            "d2v=excluded.d2v, d2v_pct=excluded.d2v_pct, "
            "n_members=excluded.n_members, mean_pct=excluded.mean_pct, "
            "spread_pct=excluded.spread_pct",
            [
                (uri, r["tox"], r["tox_pct"], r["tfidf"], r["tfidf_pct"],
                 r["d2v"], r["d2v_pct"], r["n_members"], r["mean_pct"], r["spread_pct"])
                for uri, r in rows.items()
            ],
        )
        conn.executemany(
            "INSERT INTO meta (key, value) VALUES (?, ?) "
            "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            [(k, json.dumps(v) if not isinstance(v, str) else v) for k, v in meta.items()],
        )
        conn.commit()
    finally:
        conn.close()


# --------------------------------------------------------------------------
# Report rendering
# --------------------------------------------------------------------------

def deciles(values):
    if not values:
        return []
    arr = np.array(sorted(values))
    return [float(np.percentile(arr, p)) for p in range(0, 101, 10)]


def top_band_uris(mean_pct_by_uri, fraction):
    n = len(mean_pct_by_uri)
    if n == 0:
        return set()
    k = max(1, int(round(n * fraction)))
    ranked = sorted(mean_pct_by_uri.items(), key=lambda kv: kv[1], reverse=True)
    return {uri for uri, _ in ranked[:k]}


HONEST_HEADER = """\
## Honest header

- `incivility_toxicity` measures INCIVILITY, not hate: hate-vs-rude AUC
  0.198 (worse than chance, wrong direction), rude-vs-random AUC 0.946.
- `tfidf_lr` and `doc2vec_lr` both answer "given hate or rude, which?" --
  they are known weak on random (not curated) text, AUC 0.61-0.68 in prior
  diagnostics.
- All three members were trained on Bluesky-moderator-reported labels,
  which record what was reported and actioned, not ground truth.
- This committee is not a hate detector. It exists to produce decorrelated
  per-post signals whose disagreement is informative, and to define strata
  for future weighted-sampling labelling.
"""


def render_report(spearman_rows, spread_values, top_bands, jaccards, extra_lines=None):
    lines = ["# Consensus committee -- pairwise disagreement report", "", HONEST_HEADER, ""]
    lines.append("## Pairwise Spearman correlations (posts all relevant members scored)")
    lines.append("")
    for (a, b), (rho, n) in spearman_rows.items():
        rho_s = "%.4f" % rho if rho is not None else "n/a"
        flag = ""
        if rho is not None and rho > 0.9:
            flag = "  <-- ABOVE 0.9: these two members may be one member wearing two hats"
        lines.append("- %s vs %s: rho=%s (n=%d)%s" % (a, b, rho_s, n, flag))
    lines.append("")
    lines.append("## spread_pct distribution (deciles)")
    lines.append("")
    lines.append(", ".join("%.2f" % d for d in deciles(spread_values)))
    lines.append("")
    lines.append("## Top mean_pct bands")
    lines.append("")
    for label, n in top_bands.items():
        lines.append("- %s: %d posts" % (label, n))
    lines.append("")
    lines.append("## Top-1% overlap (Jaccard) between members' own top-1% sets")
    lines.append("")
    for pair, j in jaccards.items():
        lines.append("- %s: %s" % (pair, "%.4f" % j if j is not None else "n/a"))
    if extra_lines:
        lines.append("")
        lines.extend(extra_lines)
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------
# CLI orchestration
# --------------------------------------------------------------------------

def run(store_path, incivility_dir, labels_dir, doc2vec_model_path, db_path,
        report_path, random_state, labels_file=None):
    import gensim
    from gensim.models.doc2vec import Doc2Vec

    tox_raw, tox_files, tox_merged = load_toxicity_scores(incivility_dir)

    conn = sqlite3.connect(ro_uri(store_path), uri=True)
    try:
        print("reading reply-post pool from %s ..." % store_path, file=sys.stderr)
        pool = sp.fetch_pool_posts(conn)
        pool_uris = [uri for uri, _ in pool]
        pool_texts = [text for _, text in pool]
        print("pool size: %d reply posts" % len(pool_uris), file=sys.stderr)

        labels_path = labels_file or sp.find_latest_complete_posts_label_file(labels_dir)
        print("training tfidf_lr from %s ..." % labels_path, file=sys.stderr)
        tfidf_raw, tfidf_counts = train_and_score_tfidf(
            conn, labels_path, pool_uris, pool_texts, random_state)

        post_labels = sp.load_post_labels(labels_path)
    finally:
        conn.close()

    print("loading doc2vec model from %s ..." % doc2vec_model_path, file=sys.stderr)
    d2v_model = Doc2Vec.load(doc2vec_model_path)

    print("training doc2vec_lr ...", file=sys.stderr)
    x, y, d2v_counts = build_doc2vec_training_arrays(d2v_model, post_labels)
    if len(set(y)) < 2:
        raise SystemExit(
            "cannot train doc2vec_lr: need at least one positive AND one "
            "hard_negative labelled post present in the doc2vec vocabulary, "
            "found counts=%s" % d2v_counts
        )
    d2v_clf = train_doc2vec_lr(x, y, random_state)

    dv_keys = set(d2v_model.dv.index_to_key)
    print("scoring doc2vec_lr over %d dv-tagged uris ..." % len(dv_keys), file=sys.stderr)
    d2v_raw = score_doc2vec_lr(d2v_clf, d2v_model, dv_keys)

    all_uris = set(pool_uris) | dv_keys

    tox_pct = rank_percentiles(tox_raw)
    tfidf_pct = rank_percentiles(tfidf_raw)
    d2v_pct = rank_percentiles(d2v_raw)

    rows = build_rows(all_uris, tox_pct, tfidf_pct, d2v_pct, tox_raw, tfidf_raw, d2v_raw)

    incivility_model_ids = sorted({v[2] for v in tox_merged.values() if v[2]})
    incivility_revisions = sorted({v[3] for v in tox_merged.values() if v[3]})

    meta = build_meta(
        tox_model_id=incivility_model_ids[0] if incivility_model_ids else None,
        tox_model_revision=incivility_revisions[0] if incivility_revisions else None,
        tox_source_files=[os.path.basename(p) for p in tox_files],
        tfidf_random_state=random_state,
        tfidf_training_counts=tfidf_counts,
        tfidf_labels_file=os.path.basename(labels_path),
        d2v_random_state=random_state,
        d2v_training_counts=d2v_counts,
        d2v_model_path=doc2vec_model_path,
        sklearn_version=sklearn.__version__,
        gensim_version=gensim.__version__,
        row_counts={
            "scores": len(rows),
            "n_scored_tox": len(tox_raw),
            "n_scored_tfidf": len(tfidf_raw),
            "n_scored_d2v": len(d2v_raw),
        },
    )

    print("writing %d rows to %s ..." % (len(rows), db_path), file=sys.stderr)
    write_committee_db(db_path, rows, meta)

    spearman_rows = {
        (MODEL_TOX, MODEL_TFIDF): spearman_pairwise(tox_raw, tfidf_raw),
        (MODEL_TOX, MODEL_D2V): spearman_pairwise(tox_raw, d2v_raw),
        (MODEL_TFIDF, MODEL_D2V): spearman_pairwise(tfidf_raw, d2v_raw),
    }
    spread_values = [r["spread_pct"] for r in rows.values() if r["spread_pct"] is not None]
    mean_pct_by_uri = {u: r["mean_pct"] for u, r in rows.items() if r["mean_pct"] is not None}
    top_1pct = top_band_uris(mean_pct_by_uri, 0.01)
    top_01pct = top_band_uris(mean_pct_by_uri, 0.001)
    top_bands = {"top 1 pct (%d posts)" % len(mean_pct_by_uri): len(top_1pct),
                 "top 0.1 pct": len(top_01pct)}

    tox_top1 = top_band_uris(tox_pct, 0.01)
    tfidf_top1 = top_band_uris(tfidf_pct, 0.01)
    d2v_top1 = top_band_uris(d2v_pct, 0.01)
    jaccards = {
        "%s_vs_%s" % (MODEL_TOX, MODEL_TFIDF): jaccard(tox_top1, tfidf_top1),
        "%s_vs_%s" % (MODEL_TOX, MODEL_D2V): jaccard(tox_top1, d2v_top1),
        "%s_vs_%s" % (MODEL_TFIDF, MODEL_D2V): jaccard(tfidf_top1, d2v_top1),
    }

    report = render_report(spearman_rows, spread_values, top_bands, jaccards)
    os.makedirs(os.path.dirname(report_path), exist_ok=True)
    with open(report_path, "w", encoding="utf-8") as f:
        f.write(report)

    print(report)
    print("wrote %s" % db_path)
    print("wrote %s" % report_path)
    return rows, meta, report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--store", default=None,
                         help="path to default.store; defaults to $BLUEX_STORE_DIR/default.store")
    parser.add_argument("--incivility-dir", default=DEFAULT_INCIVILITY_DIR)
    parser.add_argument("--labels-dir", default=DEFAULT_LABELS_DIR)
    parser.add_argument("--labels-file", default=None)
    parser.add_argument("--doc2vec-model", default=DEFAULT_DOC2VEC_MODEL)
    parser.add_argument("--db", default=DEFAULT_DB_PATH)
    parser.add_argument("--report", default=DEFAULT_REPORT_PATH)
    parser.add_argument("--random-state", type=int, default=DEFAULT_RANDOM_STATE)
    args = parser.parse_args(argv)

    store_dir = args.store or DEFAULT_STORE_DIR
    store_path = store_dir if store_dir.endswith(".store") else os.path.join(store_dir, "default.store")
    if not os.path.exists(store_path):
        parser.error("store not found: %s" % store_path)

    run(store_path, args.incivility_dir, args.labels_dir, args.doc2vec_model,
        args.db, args.report, args.random_state, labels_file=args.labels_file)
    return 0


if __name__ == "__main__":
    sys.exit(main())
