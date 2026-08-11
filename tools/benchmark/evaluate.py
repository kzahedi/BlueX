#!/usr/bin/env python3
"""Score detectors against a BlueX evaluation set and compare them.

WHY THIS EXISTS
----------------
`tools/benchmark/build_eval_set.py` gives us moderator-labelled positive,
hard_negative, and easy_negative examples. This script is the only place that
turns detector scores into numbers a human can use to choose a detector —
and it exists specifically so that choice is made by measurement, not by
which model has the best reputation.

THE TWO AUCs ARE NOT INTERCHANGEABLE
--------------------------------------
positive-vs-easy_negative tells you whether a detector beats random text.
positive-vs-hard_negative tells you whether it beats *rudeness* — the
distinction this whole benchmark exists to force. Both are always computed,
always printed, and the comparison table is sorted by the hard-negative
number, not the easy one, so a detector cannot look good by hiding behind
random-text separability.

CACHING / RESUMABILITY
------------------------
Each detector's raw scores are cached under `<out-dir>/cache/` keyed by
detector spec + eval-set filename. Re-running with more detectors, or after
a failure partway through, never re-scores a detector whose cache is already
present. Delete the relevant cache file to force a re-score.

WHAT THIS DOES NOT TELL YOU
------------------------------
See build_eval_set.py's docstring and this benchmark's README: moderator
labels are a precision test, not a recall test. A low score here does not
mean a detector catches no real hate — it may be flagging hate nobody
reported. This script reports separability against labelled examples; it
does not and cannot measure recall against unreported hate.
"""
import argparse
import datetime as dt
import hashlib
import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import metrics  # noqa: E402
from detectors import hf_encoder, lexicon, nltagger  # noqa: E402

DEFAULT_OUT_DIR = "/Volumes/Eregion/bluex-benchmark"

POSITIVE_CLASS = "positive"
HARD_NEGATIVE_CLASS = "hard_negative"
EASY_NEGATIVE_CLASS = "easy_negative"


class DetectorFailure(Exception):
    """A detector spec failed to produce scores. Carries a human-readable reason."""


def load_eval_set(path):
    records = []
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line:
                records.append(json.loads(line))
    return records


def eval_set_stamp(path):
    """Stable short id for the eval set file, used in cache filenames."""
    base = os.path.basename(path)
    return hashlib.sha1(base.encode("utf-8")).hexdigest()[:12]


def cache_path(out_dir, detector_spec, stamp):
    safe = detector_spec.replace("/", "_").replace(":", "_")
    return os.path.join(out_dir, "cache", "scores-%s-%s.json" % (safe, stamp))


def write_atomic(path, write_body):
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


def run_detector(spec, records, out_dir, stamp, force=False):
    """Returns dict: {"status": "ok", "heads": {head_name: {uri: score}}}
    or {"status": "failed", "reason": str}. Cached to disk keyed by (spec,
    stamp); a cache hit never re-runs the underlying model.
    """
    cpath = cache_path(out_dir, spec, stamp)
    if not force and os.path.exists(cpath):
        with open(cpath, "r", encoding="utf-8") as handle:
            return json.load(handle)

    texts = [r["text"] for r in records]
    uris = [r["uri"] for r in records]

    try:
        if spec == "lexicon":
            scores = lexicon.score(texts)
            heads = {"lexicon": dict(zip(uris, scores))}
        elif spec == "nltagger":
            scores = nltagger.score(texts)
            heads = {"nltagger": dict(zip(uris, scores))}
        elif spec.startswith("hf:"):
            model_id = spec[len("hf:"):]
            head_scores = hf_encoder.score_heads(texts, model_id)
            heads = {
                "%s#%s" % (spec, head_name): dict(zip(uris, scores))
                for head_name, scores in head_scores.items()
            }
        else:
            raise DetectorFailure("unknown detector spec: %r" % spec)
        result = {"status": "ok", "heads": heads}
    except hf_encoder.DetectorLoadError as exc:
        result = {"status": "failed", "reason": str(exc)}
    except DetectorFailure as exc:
        result = {"status": "failed", "reason": str(exc)}

    def write_body(handle):
        json.dump(result, handle, ensure_ascii=False)

    write_atomic(cpath, write_body)
    return result


def evaluate_head(head_name, scores_by_uri, records, min_lang_n):
    """One head's full metric report against both negative classes."""
    by_class = {POSITIVE_CLASS: [], HARD_NEGATIVE_CLASS: [], EASY_NEGATIVE_CLASS: []}
    for rec in records:
        cls = rec["class"]
        if cls in by_class and rec["uri"] in scores_by_uri:
            by_class[cls].append(scores_by_uri[rec["uri"]])

    report = {"n": {cls: len(v) for cls, v in by_class.items()}}
    for neg_class, label in ((EASY_NEGATIVE_CLASS, "vs_easy_negative"),
                              (HARD_NEGATIVE_CLASS, "vs_hard_negative")):
        pos, neg = by_class[POSITIVE_CLASS], by_class[neg_class]
        report[label] = {
            "roc_auc": metrics.roc_auc(pos, neg),
            "pr_auc": metrics.pr_auc(pos, neg),
            "best_f1": metrics.best_f1(pos, neg),
            "per_language": metrics.per_language_breakdown(
                records, scores_by_uri, POSITIVE_CLASS, neg_class, min_n=min_lang_n,
            ),
        }
    return report


def build_comparison_table(head_reports):
    """Sort by hard-negative ROC-AUC descending; None sorts last."""
    rows = []
    for head_name, report in head_reports.items():
        hard_auc = report["vs_hard_negative"]["roc_auc"]
        easy_auc = report["vs_easy_negative"]["roc_auc"]
        rows.append((head_name, hard_auc, easy_auc, report))
    rows.sort(key=lambda r: (r[1] is None, -(r[1] or 0)))
    return rows


def render_markdown_table(rows):
    lines = [
        "| detector/head | AUC vs hard_negative | AUC vs easy_negative | PR-AUC vs hard_negative |",
        "|---|---|---|---|",
    ]
    for head_name, hard_auc, easy_auc, report in rows:
        hard_pr = report["vs_hard_negative"]["pr_auc"]
        fmt = lambda v: ("%.3f" % v) if v is not None else "n/a"
        lines.append("| %s | %s | %s | %s |" % (
            head_name, fmt(hard_auc), fmt(easy_auc), fmt(hard_pr),
        ))
    return "\n".join(lines)


README_TEXT = """# BlueX detector benchmark — evaluation output

Produced by `tools/benchmark/evaluate.py` against an eval set from
`tools/benchmark/build_eval_set.py`.

## What this measures

Separability of each detector's score between moderator-labelled
`positive` (intolerant/threat/extremist/intolerant-race) posts and two
negative pools:

  * `easy_negative` — random, unlabelled replies. Beating this only shows a
    detector beats random text.
  * `hard_negative` — `rude`-labelled replies. This is the real test: a
    detector that cannot separate `positive` from `hard_negative` is
    measuring incivility, not hate, and should not be trusted for this
    project's purpose. The comparison table is sorted by THIS number.

Multi-head models (e.g. Detoxify-style checkpoints) have every head reported
separately — never averaged — because a narrow head like `identity_attack`
can behave very differently from a generic `toxicity` head against
`hard_negative`.

## What this does NOT measure

Moderator labels capture what was reported and actioned, not all hateful
content. A detector scoring badly here may be correctly flagging real hate
that nobody ever reported to Bluesky's moderators — this evaluation is a
reasonable **precision** test and a **poor recall test**. Do not report a low
score here as "this detector doesn't work"; report it as "this detector does
not separate reported-hate from rudeness/random-text in this sample."

## Layout

  * `evaluation-<timestamp>.json` — full metrics per detector/head, including
    per-language breakdowns (en/de/other; cells with too few examples have
    `"suppressed": true` and null AUCs rather than a meaningless number).
  * `evaluation-<timestamp>.md` — the comparison table.
  * `cache/scores-<detector>-<eval-set-stamp>.json` — raw per-URI scores,
    reused on the next run so re-evaluating one new detector never re-scores
    the others.
"""


def write_readme(out_dir):
    path = os.path.join(out_dir, "README-evaluate.md")
    write_atomic(path, lambda handle: handle.write(README_TEXT))
    return path


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Score detectors against a BlueX eval set and compare them."
    )
    parser.add_argument("--eval-set", required=True)
    parser.add_argument("--detectors", required=True,
                         help="comma-separated: lexicon,nltagger,hf:<model_id>,...")
    parser.add_argument("--out-dir", default=DEFAULT_OUT_DIR)
    parser.add_argument("--min-lang-n", type=int, default=metrics.MIN_LANGUAGE_N)
    parser.add_argument("--force", action="store_true",
                         help="ignore cached scores and re-run every detector")
    args = parser.parse_args(argv)

    records = load_eval_set(args.eval_set)
    stamp = eval_set_stamp(args.eval_set)
    specs = [s.strip() for s in args.detectors.split(",") if s.strip()]

    detector_status = {}
    head_reports = {}
    for spec in specs:
        result = run_detector(spec, records, args.out_dir, stamp, force=args.force)
        if result["status"] != "ok":
            detector_status[spec] = {"status": "failed", "reason": result["reason"]}
            print("FAILED %s: %s" % (spec, result["reason"]))
            continue
        detector_status[spec] = {"status": "ok", "heads": list(result["heads"].keys())}
        for head_name, scores_by_uri in result["heads"].items():
            head_reports[head_name] = evaluate_head(
                head_name, scores_by_uri, records, args.min_lang_n,
            )

    rows = build_comparison_table(head_reports)

    now = dt.datetime.now(dt.timezone.utc)
    out_stamp = now.strftime("%Y-%m-%dT%H%M%SZ")
    os.makedirs(args.out_dir, exist_ok=True)
    json_path = os.path.join(args.out_dir, "evaluation-%s.json" % out_stamp)
    md_path = os.path.join(args.out_dir, "evaluation-%s.md" % out_stamp)

    full = {
        "evaluatedAt": now.replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "evalSet": os.path.abspath(args.eval_set),
        "detectorSpecs": specs,
        "detectorStatus": detector_status,
        "heads": head_reports,
        "comparisonSortedByHardNegativeAUC": [r[0] for r in rows],
    }

    def write_json(handle):
        json.dump(full, handle, ensure_ascii=False, indent=2)
        handle.write("\n")

    write_atomic(json_path, write_json)

    md = "# BlueX detector benchmark — %s\n\n" % out_stamp
    md += "Eval set: `%s`\n\n" % os.path.basename(args.eval_set)
    md += "## Comparison (sorted by AUC vs hard_negative)\n\n"
    md += render_markdown_table(rows) + "\n\n"
    md += (
        "**Head polarity caveat:** heads whose name suggests the NON-hate class "
        "(e.g. `neutral`, `non-hate`, `NON_HATE`) are scored raw, in the same "
        "\"higher score\" direction as every other head, per this benchmark's "
        "uniform detector interface. A high AUC on such a head does NOT mean "
        "that head detects hate — it means the model's hate-direction head "
        "(e.g. `toxic`) is doing the OPPOSITE of what a working detector should: "
        "rating the negative class as more hate-like than the positive class. "
        "Check the complementary head before reading a `neutral`/`non-hate` "
        "result as good news.\n\n"
    )
    if detector_status:
        md += "## Detector load status\n\n"
        for spec, status in detector_status.items():
            if status["status"] == "ok":
                md += "- `%s`: OK (heads: %s)\n" % (spec, ", ".join(status["heads"]))
            else:
                md += "- `%s`: FAILED — %s\n" % (spec, status["reason"])

    write_atomic(md_path, lambda handle: handle.write(md))
    write_readme(args.out_dir)

    print("wrote %s" % json_path)
    print("wrote %s" % md_path)
    print(md)
    return 0


if __name__ == "__main__":
    sys.exit(main())
