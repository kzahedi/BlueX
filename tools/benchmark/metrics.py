"""Metric computation for the BlueX detector benchmark.

Kept separate from evaluate.py so it can be unit-tested against hand-worked
examples with no network, no store, and no detector imports.

WHAT THESE METRICS ARE NOT
----------------------------
ROC-AUC/PR-AUC against `easy_negative` measures separability from RANDOM
text. It says nothing about whether a detector merely fires on incivility —
that is what positive-vs-`hard_negative` is for, and this module always
computes both, never one silently standing in for the other.
"""
import math

from sklearn.metrics import average_precision_score, precision_recall_curve, roc_auc_score

MIN_LANGUAGE_N = 20  # per-class minimum before a per-language cell is reported


class DegenerateInputError(Exception):
    """Raised (and caught internally) when labels contain only one class."""


def _labels_and_scores(pos_scores, neg_scores):
    labels = [1] * len(pos_scores) + [0] * len(neg_scores)
    scores = list(pos_scores) + list(neg_scores)
    return labels, scores


def roc_auc(pos_scores, neg_scores):
    """ROC-AUC treating pos_scores as the positive class. None if degenerate
    (either group empty) rather than raising or dividing by zero.
    """
    if not pos_scores or not neg_scores:
        return None
    labels, scores = _labels_and_scores(pos_scores, neg_scores)
    return float(roc_auc_score(labels, scores))


def pr_auc(pos_scores, neg_scores):
    """PR-AUC (average precision), positive class = pos_scores. None if
    either group is empty.
    """
    if not pos_scores or not neg_scores:
        return None
    labels, scores = _labels_and_scores(pos_scores, neg_scores)
    return float(average_precision_score(labels, scores))


def best_f1(pos_scores, neg_scores):
    """Best-F1 threshold and precision/recall at it. None if either group is
    empty. Ties in F1 are broken by the first threshold precision_recall_curve
    yields at the max value (stable, not an approximation of "the" best
    threshold when several are tied).
    """
    if not pos_scores or not neg_scores:
        return None
    labels, scores = _labels_and_scores(pos_scores, neg_scores)
    precision, recall, thresholds = precision_recall_curve(labels, scores)
    # precision_recall_curve returns len(thresholds) == len(precision) - 1;
    # the last precision/recall pair (1.0, 0.0) has no corresponding threshold.
    f1s = []
    for p, r in zip(precision[:-1], recall[:-1]):
        denom = p + r
        f1s.append(2 * p * r / denom if denom > 0 else 0.0)
    if not f1s:
        return None
    best_idx = max(range(len(f1s)), key=lambda i: f1s[i])
    return {
        "threshold": float(thresholds[best_idx]),
        "precision": float(precision[best_idx]),
        "recall": float(recall[best_idx]),
        "f1": float(f1s[best_idx]),
    }


def bucket_language(language):
    """en / de -> themselves; anything else (including None) -> 'other'."""
    if language in ("en", "de"):
        return language
    return "other"


def per_language_breakdown(records, scores_by_uri, positive_class, negative_class,
                            min_n=MIN_LANGUAGE_N):
    """records: list of eval-set dicts (uri, class, language).
    scores_by_uri: dict uri -> score for this detector/head.

    Returns dict: language -> {"n_positive", "n_negative", "roc_auc", "pr_auc"}
    (roc_auc/pr_auc are None, with the cell still present showing n, when
    either group's n < min_n — suppressed for being too small to mean
    anything, not omitted silently).
    """
    by_lang = {}
    for rec in records:
        cls = rec["class"]
        if cls not in (positive_class, negative_class):
            continue
        uri = rec["uri"]
        if uri not in scores_by_uri:
            continue
        lang = bucket_language(rec.get("language"))
        by_lang.setdefault(lang, {"pos": [], "neg": []})
        bucket = "pos" if cls == positive_class else "neg"
        by_lang[lang][bucket].append(scores_by_uri[uri])

    out = {}
    for lang, groups in by_lang.items():
        pos, neg = groups["pos"], groups["neg"]
        n_pos, n_neg = len(pos), len(neg)
        big_enough = n_pos >= min_n and n_neg >= min_n
        out[lang] = {
            "n_positive": n_pos,
            "n_negative": n_neg,
            "roc_auc": roc_auc(pos, neg) if big_enough else None,
            "pr_auc": pr_auc(pos, neg) if big_enough else None,
            "suppressed": not big_enough,
        }
    return out
