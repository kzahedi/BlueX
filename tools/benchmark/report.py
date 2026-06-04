#!/usr/bin/env python3
"""Score annotation models against the benchmark gold labels and write a
markdown report.

gold label per post = user_label.class if present else claude_label.class.
Predictions are read from the SwiftData store (each model's latest llm
annotation for the benchmark URIs).
"""
import json
import os
import sqlite3
import sys
from itertools import combinations

STORE = os.path.expanduser("~/Library/Application Support/BlueX/default.store")
SET = os.path.join(os.path.dirname(__file__), "benchmark-set.json")
OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "docs", "benchmarks")
CLASSES = ("hate", "counter", "neutral")


def gold_labels(entries):
    out = {}
    for e in entries:
        lab = e.get("user_label") or e.get("claude_label")
        if lab and lab.get("class"):
            out[e["uri"]] = lab["class"]
    return out


def score(gold, preds):
    """preds: {uri: {model: class}}. Returns {model: metrics}.

    macro_f1 averages F1 over all three fixed classes (hate/counter/neutral);
    a class with zero gold support contributes F1=0.0 by design, so a model
    can score macro_f1 < 1.0 even when perfect on the classes actually present.
    """
    models = sorted({m for d in preds.values() for m in d})
    results = {}
    for model in models:
        mp = {u: d[model] for u, d in preds.items() if model in d and u in gold}
        per_class = {}
        for c in CLASSES:
            tp = sum(1 for u, p in mp.items() if p == c and gold[u] == c)
            fp = sum(1 for u, p in mp.items() if p == c and gold[u] != c)
            fn = sum(1 for u, p in mp.items() if p != c and gold[u] == c)
            precision = tp / (tp + fp) if (tp + fp) else 0.0
            recall = tp / (tp + fn) if (tp + fn) else 0.0
            f1 = 2 * precision * recall / (precision + recall) if (precision + recall) else 0.0
            per_class[c] = {"precision": precision, "recall": recall, "f1": f1,
                            "tp": tp, "fp": fp, "fn": fn}
        n = len(mp)
        correct = sum(1 for u, p in mp.items() if p == gold[u])
        results[model] = {
            "n": n,
            "accuracy": correct / n if n else 0.0,
            "macro_f1": sum(per_class[c]["f1"] for c in CLASSES) / len(CLASSES),
            "per_class": per_class,
        }
    return results


def agreement(preds):
    """Pairwise fraction-agreement over posts both models predicted."""
    models = sorted({m for d in preds.values() for m in d})
    out = {}
    for a, b in combinations(models, 2):
        shared = [(d[a], d[b]) for d in preds.values() if a in d and b in d]
        out[(a, b)] = sum(1 for x, y in shared if x == y) / len(shared) if shared else 0.0
    return out


def load_preds(conn, uris):
    """uri -> {model: class} from the latest llm annotation per (uri, model)."""
    placeholders = ",".join("?" * len(uris))
    rows = conn.execute(
        f"""
        SELECT p.ZURI, a.ZMODELNAME, a.ZSPEECHCLASS, a.ZCREATEDAT
        FROM ZANNOTATION a JOIN ZPOST p ON a.ZPOST = p.Z_PK
        WHERE a.ZSTAGE='llm' AND a.ZCONFIDENCE > 0 AND p.ZURI IN ({placeholders})
        ORDER BY a.ZCREATEDAT, a.Z_PK
        """,
        list(uris),
    ).fetchall()
    preds, newest = {}, {}
    for uri, model, cls, created in rows:
        key = (uri, model)
        if key not in newest or (created or 0) >= newest[key]:
            newest[key] = created or 0
            preds.setdefault(uri, {})[model] = cls
    return preds


def render(entries, gold, results, agree, preds):
    reviewed = sum(1 for e in entries if e.get("reviewed"))
    lines = [
        "# BlueX Model Benchmark",
        "",
        f"Gold posts: {len(gold)}  ·  user-reviewed: {reviewed}/{len(entries)} "
        f"({100*reviewed//max(len(entries),1)}%)  ·  rest fall back to Claude's label.",
        "",
        "## Scores vs gold",
        "",
        "| Model | n | Acc | macro-F1 | hate F1 | counter F1 | neutral F1 |",
        "|---|---|---|---|---|---|---|",
    ]
    if not gold:
        lines += ["> ⚠ No gold labels yet — score table is empty until the set is labeled.", ""]
    for model in sorted(results):
        m = results[model]
        pc = m["per_class"]
        lines.append(
            f"| {model} | {m['n']} | {m['accuracy']:.2f} | {m['macro_f1']:.2f} | "
            f"{pc['hate']['f1']:.2f} | {pc['counter']['f1']:.2f} | {pc['neutral']['f1']:.2f} |"
        )
    lines += ["", "## Pairwise agreement", "", "| Model A | Model B | Agreement |",
              "|---|---|---|"]
    for (a, b), v in sorted(agree.items()):
        lines.append(f"| {a} | {b} | {v:.2f} |")

    lines += ["", "## Disagreements with gold (hard cases first)", ""]
    by_uri = {e["uri"]: e for e in entries}
    ordered = sorted(by_uri.values(), key=lambda e: (e["tag"] != "hard", e["uri"]))
    for e in ordered:
        uri = e["uri"]
        if uri not in gold:
            continue
        per_model = preds.get(uri, {})
        if per_model and all(c == gold[uri] for c in per_model.values()):
            continue  # every model that predicted this agrees with gold
        calls = ", ".join(f"{m}={c}" for m, c in sorted(per_model.items())) or "(no predictions)"
        text = (e["text"] or "").replace("\n", " ")[:140]
        lines.append(f"- **[{e['tag']}]** gold=`{gold[uri]}` · {calls}\n  > {text}")
    return "\n".join(lines) + "\n"


def main():
    label = sys.argv[1] if len(sys.argv) > 1 else "all"
    with open(SET) as fh:
        entries = json.load(fh)
    gold = gold_labels(entries)
    conn = sqlite3.connect(f"file:{STORE}?mode=ro", uri=True)
    preds = load_preds(conn, [e["uri"] for e in entries])
    results = score(gold, preds)
    agree = agreement(preds)
    md = render(entries, gold, results, agree, preds)
    os.makedirs(OUT_DIR, exist_ok=True)
    out = os.path.join(OUT_DIR, f"benchmark-{label}.md")
    with open(out, "w") as fh:
        fh.write(md)
    print(f"wrote report to {out}")
    print(md)


if __name__ == "__main__":
    main()
