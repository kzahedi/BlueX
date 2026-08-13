#!/usr/bin/env python3
"""Decisive diagnostic: can a model separate moderator-labelled hate from
moderator-labelled `rude` when trained directly on that distinction?

WHY THIS EXISTS
----------------
`tools/benchmark/evaluate.py` showed that every OFF-THE-SHELF detector fails
this distinction (best 0.533 AUC; generic toxicity heads are *inverted*,
0.198 — see `docs/superpowers/notes/2026-08-11-nltagger-sentiment-does-not-
detect-hate.md` and `docs/superpowers/specs/2026-08-12-hate-detection-
programme-design.md`). Those models were trained for toxicity, a different
construct. Nothing has yet been trained on the actual distinction this
project needs. This script is that experiment.

- If a model fine-tuned directly on positive-vs-hard_negative beats chance
  with a real margin, the hate pipeline exists and the expensive
  LLM-labelling stage may be unnecessary entirely.
- If it does not, the distinction is not learnable from text at this label
  quality, and NO amount of LLM labelling would fix that (an LLM labeller
  would just be another text-based classifier). Human annotation becomes
  mandatory. That is a real, valuable result — see the module docstring
  discipline in `build_eval_set.py`: report it as a finding, not a failure.

THE SMALL-N DISCIPLINE (do not violate this)
------------------------------------------------
There are 235 positives in the whole corpus. A single train/test split would
be dominated by which examples happened to land where. Every model and every
baseline in this script is evaluated with the SAME stratified 5-fold CV
harness on the positive/hard_negative core set, and the headline number is
always mean +/- sd of the per-fold test AUC, never a single fold's number.

Per-fold test AUC (`hard_negative` cross-validated) is the headline. In
addition, out-of-fold (OOF) scores are stitched back into per-URI dicts and
run through `evaluate.evaluate_head` — the SAME function `evaluate.py` uses
— so the vs_easy_negative number, per-language breakdown, and suppression of
small language cells are computed identically to the rest of this benchmark,
not reimplemented here. `easy_negative` examples are never in any training
fold; each is scored by all 5 fold models and the mean of those 5 scores is
used as its one score (documented, not hidden, in the output JSON).

OVERFITTING
------------
Small encoders, few epochs, early stopping on an internal validation slice
carved out of each fold's training data (never the test fold). Per-fold
TRAIN AUC is recorded next to per-fold TEST AUC specifically so memorisation
is visible: train AUC near 1.0 with test AUC near 0.5 is memorisation, and
this script prints that plainly rather than only reporting the number that
looks good.

BASELINES ARE IN THE SAME HARNESS
-------------------------------------
The keyword lexicon (no training, scored once, same CV test folds applied to
its precomputed scores so its numbers are directly comparable) and a
TF-IDF + logistic regression pipeline (genuinely refit inside each fold) run
through the identical CV/report path as the fine-tuned transformers. If a
fine-tuned transformer cannot beat TF-IDF on ~1,100 examples, that is a
reportable, common result at this scale — not a bug.

SAFETY
------
This script only reads the eval-set JSONL under /Volumes/Eregion/bluex-
benchmark; it never touches /Volumes/Eregion/bluex-data.
"""
import argparse
import datetime as dt
import json
import os
import random
import sys
import time

import numpy as np
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.linear_model import LogisticRegression
from sklearn.model_selection import StratifiedKFold, train_test_split

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evaluate  # noqa: E402 - reuses evaluate_head, not reimplemented
import metrics  # noqa: E402
from detectors import lexicon  # noqa: E402

DEFAULT_OUT_DIR = "/Volumes/Eregion/bluex-benchmark"
DEFAULT_K_FOLDS = 5
DEFAULT_MODELS = "xlm-roberta-base,cardiffnlp/twitter-roberta-base,unitary/unbiased-toxic-roberta"

POSITIVE_CLASS = "positive"
HARD_NEGATIVE_CLASS = "hard_negative"
EASY_NEGATIVE_CLASS = "easy_negative"


# --------------------------------------------------------------------------
# Data plumbing
# --------------------------------------------------------------------------

def load_eval_set(path):
    return evaluate.load_eval_set(path)


def split_core_and_easy(records):
    """core = positive + hard_negative (the CV set); easy = easy_negative
    (never trained on, scored by every fold model, averaged for reporting).
    """
    core = [r for r in records if r["class"] in (POSITIVE_CLASS, HARD_NEGATIVE_CLASS)]
    easy = [r for r in records if r["class"] == EASY_NEGATIVE_CLASS]
    return core, easy


def core_labels(core_records):
    """1 for positive, 0 for hard_negative — the label this whole diagnostic
    exists to test, not hate-vs-random.
    """
    return np.array([1 if r["class"] == POSITIVE_CLASS else 0 for r in core_records])


def build_folds(core_records, k, seed):
    """Stratified k-fold splits over the core (positive/hard_negative) set.
    Returns list of (train_idx, test_idx) numpy arrays, index into
    core_records. Stratification matters at this n: an unlucky split could
    put a third of the 235 positives in one fold.
    """
    labels = core_labels(core_records)
    skf = StratifiedKFold(n_splits=k, shuffle=True, random_state=seed)
    return list(skf.split(np.zeros(len(labels)), labels))


# --------------------------------------------------------------------------
# Baselines (same CV harness as the fine-tuned models)
# --------------------------------------------------------------------------

def run_lexicon_baseline(core_records, easy_records, folds):
    """No training; deterministic keyword counts. Scored once, then the SAME
    CV test-fold structure is applied so its per-fold numbers are directly
    comparable to the trained models', not computed a different way.
    """
    core_texts = [r["text"] for r in core_records]
    core_scores = np.array(lexicon.score(core_texts))
    easy_scores = np.array(lexicon.score([r["text"] for r in easy_records]))

    labels = core_labels(core_records)
    fold_test_auc = []
    fold_train_auc = []
    fold_easy_auc = []
    oof_scores = np.full(len(core_records), np.nan)
    for train_idx, test_idx in folds:
        train_pos = core_scores[train_idx][labels[train_idx] == 1]
        train_neg = core_scores[train_idx][labels[train_idx] == 0]
        test_pos = core_scores[test_idx][labels[test_idx] == 1]
        test_neg = core_scores[test_idx][labels[test_idx] == 0]
        fold_train_auc.append(metrics.roc_auc(list(train_pos), list(train_neg)))
        fold_test_auc.append(metrics.roc_auc(list(test_pos), list(test_neg)))
        fold_easy_auc.append(metrics.roc_auc(list(test_pos), list(easy_scores)))
        oof_scores[test_idx] = core_scores[test_idx]

    return {
        "fold_train_auc": fold_train_auc,
        "fold_test_auc": fold_test_auc,
        "fold_easy_negative_auc": fold_easy_auc,
        "oof_core_scores": oof_scores.tolist(),
        "easy_negative_scores_per_fold_model": [easy_scores.tolist()] * len(folds),
        "trainable": False,
    }


def run_tfidf_logreg_baseline(core_records, easy_records, folds, seed):
    """Refit inside every fold — this is a genuinely trained baseline, not a
    fixed score like the lexicon. TfidfVectorizer + LogisticRegression is the
    standard small-n text-classification floor.
    """
    core_texts = np.array([r["text"] for r in core_records], dtype=object)
    easy_texts = [r["text"] for r in easy_records]
    labels = core_labels(core_records)

    fold_train_auc = []
    fold_test_auc = []
    fold_easy_auc = []
    oof_scores = np.full(len(core_records), np.nan)
    easy_scores_per_fold = []

    for fold_i, (train_idx, test_idx) in enumerate(folds):
        vec = TfidfVectorizer(
            max_features=20000, ngram_range=(1, 2), min_df=2, sublinear_tf=True,
        )
        X_train = vec.fit_transform(core_texts[train_idx])
        X_test = vec.transform(core_texts[test_idx])
        X_easy = vec.transform(easy_texts)

        clf = LogisticRegression(
            max_iter=2000, class_weight="balanced", random_state=seed + fold_i,
        )
        clf.fit(X_train, labels[train_idx])

        train_scores = clf.predict_proba(X_train)[:, 1]
        test_scores = clf.predict_proba(X_test)[:, 1]
        easy_scores = clf.predict_proba(X_easy)[:, 1]

        y_train, y_test = labels[train_idx], labels[test_idx]
        fold_train_auc.append(metrics.roc_auc(
            list(train_scores[y_train == 1]), list(train_scores[y_train == 0])))
        fold_test_auc.append(metrics.roc_auc(
            list(test_scores[y_test == 1]), list(test_scores[y_test == 0])))
        fold_easy_auc.append(metrics.roc_auc(list(test_scores[y_test == 1]), list(easy_scores)))
        oof_scores[test_idx] = test_scores
        easy_scores_per_fold.append(easy_scores.tolist())

    return {
        "fold_train_auc": fold_train_auc,
        "fold_test_auc": fold_test_auc,
        "fold_easy_negative_auc": fold_easy_auc,
        "oof_core_scores": oof_scores.tolist(),
        "easy_negative_scores_per_fold_model": easy_scores_per_fold,
        "trainable": True,
    }


# --------------------------------------------------------------------------
# Fine-tuned transformer candidates
# --------------------------------------------------------------------------

class ModelLoadError(Exception):
    pass


def _pick_device(requested=None):
    import torch
    if requested:
        return requested
    if torch.backends.mps.is_available():
        return "mps"
    return "cpu"


def _tokenize(tokenizer, texts, max_length):
    return tokenizer(
        list(texts), padding=True, truncation=True,
        max_length=max_length, return_tensors="pt",
    )


def _run_epoch_train(model, optimizer, tokenizer, texts, labels, device, batch_size, max_length):
    import torch
    import torch.nn.functional as F

    model.train()
    order = list(range(len(texts)))
    random.Random(0).shuffle(order)  # seeded shuffle only for batch order stability
    total_loss = 0.0
    for i in range(0, len(order), batch_size):
        idx = order[i:i + batch_size]
        batch_texts = [texts[j] for j in idx]
        batch_labels = torch.tensor([labels[j] for j in idx], dtype=torch.long).to(device)
        encoded = _tokenize(tokenizer, batch_texts, max_length).to(device)
        optimizer.zero_grad()
        logits = model(**encoded).logits
        loss = F.cross_entropy(logits, batch_labels)
        loss.backward()
        optimizer.step()
        total_loss += float(loss.detach().cpu()) * len(idx)
    return total_loss / max(len(order), 1)


def _score_texts(model, tokenizer, texts, device, batch_size, max_length):
    import torch

    model.eval()
    scores = []
    with torch.no_grad():
        for i in range(0, len(texts), batch_size):
            batch = texts[i:i + batch_size]
            encoded = _tokenize(tokenizer, batch, max_length).to(device)
            logits = model(**encoded).logits
            probs = torch.softmax(logits, dim=-1)[:, 1]
            scores.extend(probs.to("cpu").tolist())
    return scores


def finetune_one_fold(model_id, train_texts, train_labels, test_texts,
                       device, epochs, batch_size, max_length, lr, patience, seed,
                       extra_texts=None):
    """Fine-tunes a fresh copy of model_id on (train_texts, train_labels),
    early-stopping on an internal validation slice carved out of the TRAIN
    split (never the test fold), then returns (test_scores, train_scores,
    epochs_run, best_val_auc, extra_scores) where train_scores are the final
    model's scores on the FULL train split (for the overfitting diagnostic)
    and extra_scores (or None) are scores on `extra_texts` — used to score
    easy_negative with the SAME trained model in one pass, rather than
    training a second time.
    """
    import torch
    from transformers import AutoModelForSequenceClassification, AutoTokenizer

    torch.manual_seed(seed)

    tokenizer = AutoTokenizer.from_pretrained(model_id)
    model = AutoModelForSequenceClassification.from_pretrained(
        model_id, num_labels=2, ignore_mismatched_sizes=True,
    )
    model.to(device)

    inner_train_texts, inner_val_texts, inner_train_labels, inner_val_labels = train_test_split(
        train_texts, train_labels, test_size=0.15, random_state=seed, stratify=train_labels,
    )

    optimizer = torch.optim.AdamW(model.parameters(), lr=lr, weight_decay=0.01)

    best_val_auc = -1.0
    best_state = None
    epochs_since_improve = 0
    epochs_run = 0

    for epoch in range(epochs):
        epochs_run = epoch + 1
        _run_epoch_train(
            model, optimizer, tokenizer, inner_train_texts, inner_train_labels,
            device, batch_size, max_length,
        )
        val_scores = _score_texts(model, tokenizer, inner_val_texts, device, batch_size, max_length)
        val_pos = [s for s, l in zip(val_scores, inner_val_labels) if l == 1]
        val_neg = [s for s, l in zip(val_scores, inner_val_labels) if l == 0]
        val_auc = metrics.roc_auc(val_pos, val_neg)
        val_auc = val_auc if val_auc is not None else 0.5

        if val_auc > best_val_auc:
            best_val_auc = val_auc
            best_state = {k: v.detach().clone() for k, v in model.state_dict().items()}
            epochs_since_improve = 0
        else:
            epochs_since_improve += 1
            if epochs_since_improve > patience:
                break

    if best_state is not None:
        model.load_state_dict(best_state)

    test_scores = _score_texts(model, tokenizer, test_texts, device, batch_size, max_length)
    train_scores = _score_texts(model, tokenizer, train_texts, device, batch_size, max_length)
    extra_scores = None
    if extra_texts:
        extra_scores = _score_texts(model, tokenizer, extra_texts, device, batch_size, max_length)

    del model
    return test_scores, train_scores, epochs_run, best_val_auc, extra_scores


def run_finetune_candidate(model_id, core_records, easy_records, folds,
                            epochs, batch_size, max_length, lr, patience, seed,
                            device=None):
    core_texts = [r["text"] for r in core_records]
    easy_texts = [r["text"] for r in easy_records]
    labels = core_labels(core_records)

    device = _pick_device(device)

    fold_train_auc = []
    fold_test_auc = []
    fold_easy_auc = []
    fold_epochs_run = []
    fold_best_val_auc = []
    oof_scores = np.full(len(core_records), np.nan)
    easy_scores_per_fold = []

    for fold_i, (train_idx, test_idx) in enumerate(folds):
        t0 = time.time()
        train_texts = [core_texts[i] for i in train_idx]
        train_labels_fold = [int(labels[i]) for i in train_idx]
        test_texts = [core_texts[i] for i in test_idx]

        # easy_negative is scored by this SAME trained model in one pass
        # (extra_texts) — never trained on, never used for early stopping.
        test_scores, train_scores, epochs_run, best_val_auc, easy_scores_fold = finetune_one_fold(
            model_id, train_texts, train_labels_fold, test_texts,
            device, epochs, batch_size, max_length, lr, patience, seed + fold_i,
            extra_texts=easy_texts,
        )

        y_train, y_test = labels[train_idx], labels[test_idx]
        fold_train_auc.append(metrics.roc_auc(
            [s for s, l in zip(train_scores, y_train) if l == 1],
            [s for s, l in zip(train_scores, y_train) if l == 0],
        ))
        fold_test_auc.append(metrics.roc_auc(
            [s for s, l in zip(test_scores, y_test) if l == 1],
            [s for s, l in zip(test_scores, y_test) if l == 0],
        ))
        oof_scores[test_idx] = test_scores
        fold_epochs_run.append(epochs_run)
        fold_best_val_auc.append(best_val_auc)

        test_pos_scores = [s for s, l in zip(test_scores, y_test) if l == 1]
        fold_easy_auc.append(metrics.roc_auc(test_pos_scores, easy_scores_fold))
        easy_scores_per_fold.append(easy_scores_fold)

        print("  fold %d/%d: train_auc=%s test_auc=%s epochs=%d val_auc=%.3f (%.1fs)" % (
            fold_i + 1, len(folds),
            "%.3f" % fold_train_auc[-1] if fold_train_auc[-1] is not None else "n/a",
            "%.3f" % fold_test_auc[-1] if fold_test_auc[-1] is not None else "n/a",
            epochs_run, best_val_auc, time.time() - t0,
        ))

    return {
        "fold_train_auc": fold_train_auc,
        "fold_test_auc": fold_test_auc,
        "fold_easy_negative_auc": fold_easy_auc,
        "fold_epochs_run": fold_epochs_run,
        "fold_best_val_auc": fold_best_val_auc,
        "oof_core_scores": oof_scores.tolist(),
        "easy_negative_scores_per_fold_model": easy_scores_per_fold,
        "trainable": True,
    }


# --------------------------------------------------------------------------
# Reporting — reuse evaluate.evaluate_head, do not reimplement AUC
# --------------------------------------------------------------------------

def build_scores_by_uri(core_records, easy_records, result):
    """OOF scores for core (positive/hard_negative); mean-of-5-fold-models
    score for easy_negative. Returned dict feeds directly into
    evaluate.evaluate_head, which is the same function evaluate.py uses.
    """
    scores_by_uri = {}
    for rec, score in zip(core_records, result["oof_core_scores"]):
        scores_by_uri[rec["uri"]] = float(score)

    easy_matrix = np.array(result["easy_negative_scores_per_fold_model"], dtype=float)
    easy_mean = easy_matrix.mean(axis=0)
    for rec, score in zip(easy_records, easy_mean):
        scores_by_uri[rec["uri"]] = float(score)
    return scores_by_uri


def summarize_candidate(name, result, core_records, easy_records, all_records, min_lang_n):
    scores_by_uri = build_scores_by_uri(core_records, easy_records, result)
    head_report = evaluate.evaluate_head(name, scores_by_uri, all_records, min_lang_n)

    fold_test = [a for a in result["fold_test_auc"] if a is not None]
    fold_train = [a for a in result["fold_train_auc"] if a is not None]
    fold_easy = [a for a in result["fold_easy_negative_auc"] if a is not None]

    cv_summary = {
        "fold_test_auc_hard_negative": result["fold_test_auc"],
        "mean_test_auc_hard_negative": float(np.mean(fold_test)) if fold_test else None,
        "sd_test_auc_hard_negative": float(np.std(fold_test, ddof=1)) if len(fold_test) > 1 else None,
        "fold_train_auc_hard_negative": result["fold_train_auc"],
        "mean_train_auc_hard_negative": float(np.mean(fold_train)) if fold_train else None,
        "fold_easy_negative_auc": result["fold_easy_negative_auc"],
        "mean_easy_negative_auc": float(np.mean(fold_easy)) if fold_easy else None,
        "sd_easy_negative_auc": float(np.std(fold_easy, ddof=1)) if len(fold_easy) > 1 else None,
        "overfitting_gap": (
            float(np.mean(fold_train) - np.mean(fold_test))
            if fold_train and fold_test else None
        ),
        "trainable": result["trainable"],
    }
    if "fold_epochs_run" in result:
        cv_summary["fold_epochs_run"] = result["fold_epochs_run"]
        cv_summary["fold_best_val_auc"] = result["fold_best_val_auc"]

    return {"cv_summary": cv_summary, "pooled_oof_report": head_report}


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def write_atomic(path, write_body):
    import tempfile
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
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


def render_headline_table(candidate_summaries):
    lines = [
        "| candidate | mean CV test AUC (hard_negative) | sd | mean train AUC | overfit gap | vs easy_negative (pooled) |",
        "|---|---|---|---|---|---|",
    ]
    for name, summary in candidate_summaries.items():
        cv = summary["cv_summary"]
        fmt = lambda v: ("%.3f" % v) if v is not None else "n/a"
        easy_auc = summary["pooled_oof_report"]["vs_easy_negative"]["roc_auc"]
        lines.append("| %s | %s | %s | %s | %s | %s |" % (
            name,
            fmt(cv["mean_test_auc_hard_negative"]),
            fmt(cv["sd_test_auc_hard_negative"]),
            fmt(cv["mean_train_auc_hard_negative"]),
            fmt(cv["overfitting_gap"]),
            fmt(easy_auc),
        ))
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Decisive diagnostic: fine-tune directly on moderator "
                     "hate-vs-rude labels, evaluated with stratified k-fold CV."
    )
    parser.add_argument("--eval-set", required=True)
    parser.add_argument("--out-dir", default=DEFAULT_OUT_DIR)
    parser.add_argument("--k-folds", type=int, default=DEFAULT_K_FOLDS)
    parser.add_argument("--seed", type=int, default=20260813)
    parser.add_argument("--models", default=DEFAULT_MODELS,
                         help="comma-separated HF model ids to fine-tune")
    parser.add_argument("--skip-models", action="store_true",
                         help="run only the lexicon/TF-IDF baselines, skip transformer fine-tuning")
    parser.add_argument("--epochs", type=int, default=4)
    parser.add_argument("--batch-size", type=int, default=8)
    parser.add_argument("--max-length", type=int, default=128)
    parser.add_argument("--lr", type=float, default=2e-5)
    parser.add_argument("--patience", type=int, default=1)
    parser.add_argument("--device", default=None,
                         help="force torch device (cpu/mps); default auto-picks mps if available")
    parser.add_argument("--min-lang-n", type=int, default=metrics.MIN_LANGUAGE_N)
    args = parser.parse_args(argv)

    random.seed(args.seed)
    np.random.seed(args.seed)

    all_records = load_eval_set(args.eval_set)
    core_records, easy_records = split_core_and_easy(all_records)
    folds = build_folds(core_records, args.k_folds, args.seed)

    print("core (positive+hard_negative): %d  easy_negative: %d  folds: %d" % (
        len(core_records), len(easy_records), len(folds)))

    candidate_summaries = {}
    candidate_status = {}

    print("running lexicon baseline...")
    lex_result = run_lexicon_baseline(core_records, easy_records, folds)
    candidate_summaries["lexicon"] = summarize_candidate(
        "lexicon", lex_result, core_records, easy_records, all_records, args.min_lang_n)
    candidate_status["lexicon"] = "ok"

    print("running tfidf_logreg baseline...")
    tfidf_result = run_tfidf_logreg_baseline(core_records, easy_records, folds, args.seed)
    candidate_summaries["tfidf_logreg"] = summarize_candidate(
        "tfidf_logreg", tfidf_result, core_records, easy_records, all_records, args.min_lang_n)
    candidate_status["tfidf_logreg"] = "ok"

    if not args.skip_models:
        specs = [s.strip() for s in args.models.split(",") if s.strip()]
        for model_id in specs:
            print("fine-tuning %s ..." % model_id)
            try:
                result = run_finetune_candidate(
                    model_id, core_records, easy_records, folds,
                    args.epochs, args.batch_size, args.max_length, args.lr,
                    args.patience, args.seed, device=args.device,
                )
                candidate_summaries[model_id] = summarize_candidate(
                    model_id, result, core_records, easy_records, all_records, args.min_lang_n)
                candidate_status[model_id] = "ok"
            except Exception as exc:  # noqa: BLE001 - a load/train failure is a reportable result
                candidate_status[model_id] = "failed: %s: %s" % (type(exc).__name__, exc)
                print("FAILED %s: %s" % (model_id, exc))

    now = dt.datetime.now(dt.timezone.utc)
    stamp = now.strftime("%Y-%m-%dT%H%M%SZ")
    os.makedirs(args.out_dir, exist_ok=True)
    json_path = os.path.join(args.out_dir, "finetune-diagnostic-%s.json" % stamp)
    md_path = os.path.join(args.out_dir, "finetune-diagnostic-%s.md" % stamp)

    full = {
        "runAt": now.replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "evalSet": os.path.abspath(args.eval_set),
        "kFolds": args.k_folds,
        "seed": args.seed,
        "epochs": args.epochs,
        "batchSize": args.batch_size,
        "maxLength": args.max_length,
        "lr": args.lr,
        "patience": args.patience,
        "device": args.device or _pick_device(),
        "candidateStatus": candidate_status,
        "candidates": candidate_summaries,
        "caveat": (
            "positive n=%d, hard_negative n=%d in the CV core set. Per-fold "
            "AUC is reported as mean +/- sd across %d stratified folds "
            "because a single split would be dominated by which examples "
            "landed where. easy_negative scores are the mean of the 5 "
            "fold-models' scores (never trained on). Moderator labels are a "
            "precision test, not a recall test."
        ) % (
            sum(1 for r in core_records if r["class"] == POSITIVE_CLASS),
            sum(1 for r in core_records if r["class"] == HARD_NEGATIVE_CLASS),
            args.k_folds,
        ),
    }

    def write_json(handle):
        json.dump(full, handle, ensure_ascii=False, indent=2)
        handle.write("\n")

    write_atomic(json_path, write_json)

    md = "# BlueX hate-vs-rude fine-tune diagnostic — %s\n\n" % stamp
    md += "Eval set: `%s`\n\n" % os.path.basename(args.eval_set)
    md += "## Headline: mean +/- sd CV test AUC (positive vs hard_negative)\n\n"
    md += render_headline_table(candidate_summaries) + "\n\n"
    md += "## Candidate status\n\n"
    for name, status in candidate_status.items():
        md += "- `%s`: %s\n" % (name, status)

    write_atomic(md_path, lambda handle: handle.write(md))

    print("wrote %s" % json_path)
    print("wrote %s" % md_path)
    print(md)
    return 0


if __name__ == "__main__":
    sys.exit(main())
