# BlueX Model Benchmark Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A reusable benchmark that scores any annotation model against a pinned, expert-labeled post set — quantitative (per-class P/R/F1, macro-F1, agreement matrix) plus Claude's qualitative verdict — so evaluating a new model is `ollama pull` → `run.sh <model>` → read report.

**Architecture:** A pinned `benchmark-set.json` (core intersection of the 3 already-run models + curated hard cases) carries Claude-proposed labels the user confirms/overrides via a resumable Obsidian review doc; gold = user label, falling back to Claude's. The annotate CLI gains a `--benchmark <file>` mode to run any model on exactly that set. Python scripts (stdlib only) build the set, generate/reconcile the review doc, and score models vs. gold into a markdown report.

**Tech Stack:** Swift 5.9 (CLI), Python 3 stdlib (`sqlite3`, `json`, `unittest` — no pip deps), zsh orchestration.

---

## Files

| Action | File | Responsibility |
|--------|------|----------------|
| Modify | `cli/annotate/main.swift` | `--benchmark <file>` annotation mode |
| Create | `tools/benchmark/build_set.py` | Build/refresh benchmark-set.json (merge-preserving) |
| Create | `tools/benchmark/test_build_set.py` | unittest for the merge logic |
| Create | `tools/benchmark/make_review.py` | Generate the Obsidian review doc |
| Create | `tools/benchmark/test_make_review.py` | unittest for review rendering |
| Create | `tools/benchmark/reconcile.py` | Parse review doc → merge verdicts into JSON |
| Create | `tools/benchmark/test_reconcile.py` | unittest for anchor parsing (tricky text) |
| Create | `tools/benchmark/report.py` | Score models vs gold → markdown report |
| Create | `tools/benchmark/test_report.py` | unittest for scoring (P/R/F1, agreement) |
| Create | `tools/benchmark/run.sh` | Orchestrate one model's benchmark run |

All Python scripts share one constant: `STORE = os.path.expanduser("~/Library/Application Support/BlueX/default.store")`.

---

### Task 1: CLI `--benchmark <file>` mode

**Files:**
- Modify: `cli/annotate/main.swift`

- [ ] **Step 1: Add the flag to `CLIArgs`**

In the `CLIArgs` struct (near `var coverage` / `var limit`), add:

```swift
    var benchmarkFile: String? = nil
```

In `CLIArgs.parse`, add a case alongside `--coverage`:

```swift
            case "--benchmark":
                i += 1
                if i < args.count { a.benchmarkFile = args[i] }
                else { fail("blueX-annotate", "--benchmark requires a path to a benchmark-set JSON file") }
```

- [ ] **Step 2: Add help text**

In the `usage` string, after the `--backfill` entry, add:

```
  --benchmark <file> Annotate exactly the posts whose URIs are listed in the
                     given benchmark-set JSON (an array of objects with a "uri"
                     field), bypassing the pending/newest selection. For model
                     benchmarking. Incompatible with --coverage and --limit.
```

- [ ] **Step 3: Add mutual-exclusion guard**

In `runCLI()`, next to the existing `--coverage`/`--limit` guard, add:

```swift
        if args.benchmarkFile != nil && (args.coverage || args.limit != nil) {
            fail("blueX-annotate", "--benchmark is incompatible with --coverage and --limit.")
        }
```

- [ ] **Step 4: Add benchmark selection to the pending-build block**

In the pending-selection block, the structure is `if args.coverage { … } else { … }`. Add a `benchmark` branch as the FIRST condition so it takes precedence. Change:

```swift
        if args.coverage {
```

to:

```swift
        if let benchmarkFile = args.benchmarkFile {
            // Annotate exactly the URIs in the benchmark set (minus any this model
            // already did — alreadyDone filtering already applied to allPending).
            struct BenchmarkEntry: Decodable { let uri: String }
            let url = URL(fileURLWithPath: benchmarkFile)
            let data: Data
            do { data = try Data(contentsOf: url) }
            catch { fail("blueX-annotate", "cannot read benchmark file \(benchmarkFile): \(error)") }
            let entries: [BenchmarkEntry]
            do { entries = try JSONDecoder().decode([BenchmarkEntry].self, from: data) }
            catch { fail("blueX-annotate", "benchmark file is not a JSON array of {\"uri\": …}: \(error)") }
            let wanted = Set(entries.map { $0.uri })
            pending = allPending.filter { wanted.contains($0.uri) }
            print("Benchmark: \(pending.count) of \(wanted.count) set posts pending for \(cfg.modelID) (rest already done).")
        } else if args.coverage {
```

(The trailing `else if args.coverage {` continues into the existing coverage block unchanged; the final `else { pending = allPending … --limit … }` remains.)

- [ ] **Step 5: Build the CLI**

```bash
xcodebuild -scheme BlueXAnnotate -configuration Debug build 2>&1 | grep -E "error:|SUCCEEDED|FAILED" | grep -v CoreSimulator
```

Expected: `** BUILD SUCCEEDED **`. (SourceKit may show false "cannot find type" diagnostics — trust xcodebuild.)

- [ ] **Step 6: Smoke-test with a 2-URI file**

```bash
BIN=$(find ~/Library/Developer/Xcode/DerivedData -name blueX-annotate -path '*/Debug/*' 2>/dev/null | head -1)
STORE="$HOME/Library/Application Support/BlueX/default.store"
# Build a 2-URI benchmark file from real posts:
sqlite3 "$STORE" "SELECT ZURI FROM ZPOST LIMIT 2;" | python3 -c "import sys,json; print(json.dumps([{'uri':u.strip()} for u in sys.stdin if u.strip()]))" > /tmp/bm2.json
cat /tmp/bm2.json
# Guard checks:
"$BIN" --benchmark /tmp/bm2.json --coverage 2>&1 | head -1   # expect incompatible error
# Real run on a fast small model:
"$BIN" --benchmark /tmp/bm2.json --pass llm --model qwen2.5:3b --pace steady 2>&1 | grep -E "Benchmark:|Annotating|Done|err" | head -5
```

Expected: the guard prints the incompatibility error; the real run prints a `Benchmark: N of 2 …` line and annotates (N ≤ 2, depending on whether qwen2.5:3b already did them). If both were already done by qwen2.5:3b, N=0 and it prints "Nothing to do" — that still proves selection works; pick two other URIs if you want to see a live classification.

- [ ] **Step 7: Commit**

```bash
cd /Volumes/Eregion/projects/bluex-v2
git add cli/annotate/main.swift
git commit -m "feat(annotate): --benchmark mode — annotate an exact URI set for model benchmarking"
```

---

### Task 2: `build_set.py` — build/refresh the benchmark set

**Files:**
- Create: `tools/benchmark/build_set.py`
- Create: `tools/benchmark/test_build_set.py`

- [ ] **Step 1: Write the failing test**

Create `tools/benchmark/test_build_set.py`:

```python
import unittest
import build_set


class MergeTest(unittest.TestCase):
    def test_merge_preserves_user_fields(self):
        existing = [{
            "uri": "at://a", "text": "old text", "tag": "core",
            "claude_label": {"class": "neutral", "severity": None, "rationale": "r"},
            "user_label": {"class": "hate", "severity": "mild"},
            "notes": "my note", "reviewed": True,
        }]
        fresh = [
            {"uri": "at://a", "text": "new text", "tag": "core"},
            {"uri": "at://b", "text": "b text", "tag": "hard"},
        ]
        merged = build_set.merge(existing, fresh)
        by_uri = {e["uri"]: e for e in merged}
        # Existing user judgements preserved; tag/text refreshed from fresh:
        self.assertEqual(by_uri["at://a"]["user_label"], {"class": "hate", "severity": "mild"})
        self.assertEqual(by_uri["at://a"]["notes"], "my note")
        self.assertTrue(by_uri["at://a"]["reviewed"])
        self.assertEqual(by_uri["at://a"]["claude_label"]["class"], "neutral")
        self.assertEqual(by_uri["at://a"]["text"], "new text")
        # New post gets empty user fields:
        self.assertIsNone(by_uri["at://b"]["user_label"])
        self.assertFalse(by_uri["at://b"]["reviewed"])
        self.assertEqual(by_uri["at://b"]["claude_label"], None)

    def test_fresh_only_when_no_existing(self):
        merged = build_set.merge([], [{"uri": "at://x", "text": "t", "tag": "core"}])
        self.assertEqual(len(merged), 1)
        self.assertEqual(merged[0]["uri"], "at://x")
        self.assertFalse(merged[0]["reviewed"])


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run it — verify it fails**

```bash
cd /Volumes/Eregion/projects/bluex-v2/tools/benchmark && python3 test_build_set.py
```

Expected: `ModuleNotFoundError: No module named 'build_set'` (or AttributeError once the file exists without `merge`).

- [ ] **Step 3: Implement `build_set.py`**

Create `tools/benchmark/build_set.py`:

```python
#!/usr/bin/env python3
"""Build or refresh tools/benchmark/benchmark-set.json.

core: posts annotated by ALL of phi4:14b, qwen2.5:7b, gpt-oss-120b (the
      comparable set already classified by the three reference models).
hard: posts whose text matches a curated list of known failure-mode substrings.

Merge-preserving: re-running keeps any existing user_label / notes / reviewed /
claude_label, refreshing only text and tag from the store.
"""
import json
import os
import sqlite3
import sys

STORE = os.path.expanduser("~/Library/Application Support/BlueX/default.store")
OUT = os.path.join(os.path.dirname(__file__), "benchmark-set.json")

REFERENCE_MODELS = ("phi4:14b", "qwen2.5:7b", "gpt-oss-120b")

# Known failure modes surfaced during development. Substrings are matched against
# post text; first matching post per substring is added as a hard case.
HARD_SUBSTRINGS = [
    '"China" ihr Kackhaufen',
    "Neonazi mit Pimmel",
    "die Braunen",
    "braunen Horden",
    "Antisemiten haben Pech",
    "Konzentrationslager",
    "Haha lol vergewaltigung",
    "Man kann den Israelis nur empfehlen",
    "Nazi Kolonie",
    "dringend Krieg",
]


def select_core(conn):
    rows = conn.execute(
        """
        WITH m AS (
          SELECT a.ZPOST AS pk, a.ZMODELNAME AS model
          FROM ZANNOTATION a
          WHERE a.ZSTAGE='llm' AND a.ZCONFIDENCE > 0 AND a.ZMODELNAME IN (?,?,?)
          GROUP BY a.ZPOST, a.ZMODELNAME
        ),
        inter AS (
          SELECT pk FROM m GROUP BY pk HAVING COUNT(DISTINCT model)=3
        )
        SELECT p.ZURI, p.ZTEXT FROM ZPOST p
        JOIN inter ON inter.pk = p.Z_PK
        ORDER BY p.ZURI
        """,
        REFERENCE_MODELS,
    ).fetchall()
    return [{"uri": u, "text": t or "", "tag": "core"} for (u, t) in rows]


def select_hard(conn, substrings=HARD_SUBSTRINGS):
    seen = set()
    out = []
    for sub in substrings:
        row = conn.execute(
            "SELECT ZURI, ZTEXT FROM ZPOST WHERE ZTEXT LIKE ? LIMIT 1",
            ("%" + sub + "%",),
        ).fetchone()
        if row and row[0] not in seen:
            seen.add(row[0])
            out.append({"uri": row[0], "text": row[1] or "", "tag": "hard"})
    return out


def merge(existing, fresh):
    """Return fresh entries, carrying over user_label/notes/reviewed/claude_label
    from existing entries with the same uri. text and tag come from fresh."""
    prior = {e["uri"]: e for e in existing}
    out = []
    for f in fresh:
        p = prior.get(f["uri"], {})
        out.append({
            "uri": f["uri"],
            "text": f["text"],
            "tag": f["tag"],
            "claude_label": p.get("claude_label"),
            "user_label": p.get("user_label"),
            "notes": p.get("notes", ""),
            "reviewed": p.get("reviewed", False),
        })
    return out


def main():
    if not os.path.exists(STORE):
        sys.exit(f"store not found: {STORE}")
    conn = sqlite3.connect(f"file:{STORE}?mode=ro", uri=True)
    fresh = select_core(conn) + select_hard(conn)
    # Dedup by uri (a hard case might also be in core); prefer the 'hard' tag.
    by_uri = {}
    for e in fresh:
        if e["uri"] in by_uri and e["tag"] == "core":
            continue
        by_uri[e["uri"]] = e
    fresh = list(by_uri.values())

    existing = []
    if os.path.exists(OUT):
        with open(OUT) as fh:
            existing = json.load(fh)
    merged = merge(existing, fresh)
    with open(OUT, "w") as fh:
        json.dump(merged, fh, ensure_ascii=False, indent=2)
    core = sum(1 for e in merged if e["tag"] == "core")
    hard = sum(1 for e in merged if e["tag"] == "hard")
    print(f"wrote {len(merged)} entries to {OUT} ({core} core, {hard} hard)")


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run the test — verify it passes**

```bash
cd /Volumes/Eregion/projects/bluex-v2/tools/benchmark && python3 test_build_set.py
```

Expected: `OK` (2 tests).

- [ ] **Step 5: Run it against the real store**

```bash
cd /Volumes/Eregion/projects/bluex-v2/tools/benchmark && python3 build_set.py
```

Expected: `wrote ~228 entries … (~198 core, ~10-30 hard)`. Confirm `benchmark-set.json` exists and is valid: `python3 -c "import json; print(len(json.load(open('benchmark-set.json'))))"`.

- [ ] **Step 6: Commit**

```bash
cd /Volumes/Eregion/projects/bluex-v2
git add tools/benchmark/build_set.py tools/benchmark/test_build_set.py tools/benchmark/benchmark-set.json
git commit -m "feat(benchmark): build_set.py — pin core intersection + hard cases"
```

---

### Task 3: `make_review.py` — generate the Obsidian review doc

**Files:**
- Create: `tools/benchmark/make_review.py`
- Create: `tools/benchmark/test_make_review.py`

- [ ] **Step 1: Write the failing test**

Create `tools/benchmark/test_make_review.py`:

```python
import unittest
import make_review


class RenderTest(unittest.TestCase):
    def setUp(self):
        self.entries = [
            {"uri": "at://hard1", "text": "tricky\ntext with > markdown",
             "tag": "hard",
             "claude_label": {"class": "hate", "severity": "moderate", "rationale": "why"},
             "user_label": None, "notes": "", "reviewed": False},
            {"uri": "at://core1", "text": "plain", "tag": "core",
             "claude_label": {"class": "neutral", "severity": None, "rationale": "ok"},
             "user_label": None, "notes": "", "reviewed": False},
        ]

    def test_anchor_present_for_each_post(self):
        md = make_review.render(self.entries)
        self.assertIn("<!-- bm: at://hard1 -->", md)
        self.assertIn("<!-- bm: at://core1 -->", md)

    def test_verdict_prefilled_with_claude_label(self):
        md = make_review.render(self.entries)
        self.assertIn("**Verdict:** hate", md)
        self.assertIn("**Verdict:** neutral", md)

    def test_hard_cases_render_before_core(self):
        md = make_review.render(self.entries)
        self.assertLess(md.index("at://hard1"), md.index("at://core1"))

    def test_reviewed_checkbox_reflects_state(self):
        self.entries[1]["reviewed"] = True
        md = make_review.render(self.entries)
        # core1 reviewed -> checked; hard1 not -> unchecked
        self.assertIn("- [x] reviewed", md)
        self.assertIn("- [ ] reviewed", md)

    def test_user_label_used_as_verdict_when_present(self):
        self.entries[0]["user_label"] = {"class": "counter", "severity": None}
        md = make_review.render(self.entries)
        self.assertIn("**Verdict:** counter", md)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run it — verify it fails**

```bash
cd /Volumes/Eregion/projects/bluex-v2/tools/benchmark && python3 test_make_review.py
```

Expected: `ModuleNotFoundError: No module named 'make_review'`.

- [ ] **Step 3: Implement `make_review.py`**

Create `tools/benchmark/make_review.py`:

```python
#!/usr/bin/env python3
"""Generate the Obsidian review doc from benchmark-set.json.

Each post is one anchored block. The Verdict line is pre-filled with the
user's label if set, else Claude's, so the default action is "accept". The
reviewed checkbox tracks progress and is resumable.
"""
import json
import os

SET = os.path.join(os.path.dirname(__file__), "benchmark-set.json")
OUT = os.path.expanduser(
    "~/Obsidian/projects/personal/bluex-v2/BlueX Benchmark Review.md"
)


def _verdict(entry):
    label = entry.get("user_label") or entry.get("claude_label") or {}
    return label.get("class", "")


def render(entries):
    # Hard cases first (highest value), then core; stable order within each.
    ordered = sorted(enumerate(entries), key=lambda iz: (iz[1]["tag"] != "hard", iz[0]))
    lines = [
        "# BlueX Benchmark Review",
        "",
        "Edit **Verdict:** only when you disagree with Claude's proposal; add **Notes:** freely.",
        "Check `reviewed` once you've eyeballed a post. Unreviewed posts fall back to Claude's label.",
        "",
    ]
    for n, (_, e) in enumerate(ordered, start=1):
        cl = e.get("claude_label") or {}
        sev = cl.get("severity")
        sev_str = f" ({sev})" if sev else ""
        checkbox = "- [x] reviewed" if e.get("reviewed") else "- [ ] reviewed"
        notes = e.get("notes", "") or ""
        quoted = "\n".join("> " + ln for ln in (e["text"] or "").splitlines() or [""])
        lines += [
            f"<!-- bm: {e['uri']} -->",
            f"### [{n}] · {e['tag']}",
            quoted,
            "",
            f"**Claude:** {cl.get('class','?')}{sev_str} — {cl.get('rationale','')}",
            f"**Verdict:** {_verdict(e)}",
            f"**Notes:** {notes}",
            checkbox,
            "",
            "---",
            "",
        ]
    return "\n".join(lines)


def main():
    with open(SET) as fh:
        entries = json.load(fh)
    md = render(entries)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as fh:
        fh.write(md)
    print(f"wrote review doc with {len(entries)} posts to {OUT}")


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run the test — verify it passes**

```bash
cd /Volumes/Eregion/projects/bluex-v2/tools/benchmark && python3 test_make_review.py
```

Expected: `OK` (5 tests).

- [ ] **Step 5: Commit**

```bash
cd /Volumes/Eregion/projects/bluex-v2
git add tools/benchmark/make_review.py tools/benchmark/test_make_review.py
git commit -m "feat(benchmark): make_review.py — anchored Obsidian review doc"
```

---

### Task 4: `reconcile.py` — merge user verdicts back into the JSON

**Files:**
- Create: `tools/benchmark/reconcile.py`
- Create: `tools/benchmark/test_reconcile.py`

- [ ] **Step 1: Write the failing test**

Create `tools/benchmark/test_reconcile.py`:

```python
import unittest
import reconcile

SAMPLE = """# BlueX Benchmark Review

<!-- bm: at://hard1 -->
### [1] · hard
> tricky
> text with > markdown and an anchor-looking <!-- bm: fake --> inside

**Claude:** hate (moderate) — why
**Verdict:** counter
**Notes:** this is actually counter-speech
- [x] reviewed

---

<!-- bm: at://core1 -->
### [2] · core
> plain

**Claude:** neutral — ok
**Verdict:** neutral
**Notes:**
- [ ] reviewed

---
"""


class ParseTest(unittest.TestCase):
    def test_parses_verdict_notes_reviewed_per_uri(self):
        parsed = reconcile.parse_review(SAMPLE)
        self.assertEqual(parsed["at://hard1"]["verdict"], "counter")
        self.assertEqual(parsed["at://hard1"]["notes"], "this is actually counter-speech")
        self.assertTrue(parsed["at://hard1"]["reviewed"])
        self.assertEqual(parsed["at://core1"]["verdict"], "neutral")
        self.assertFalse(parsed["at://core1"]["reviewed"])

    def test_inline_fake_anchor_in_quote_does_not_split(self):
        # The "<!-- bm: fake -->" inside the blockquote must NOT create an entry.
        parsed = reconcile.parse_review(SAMPLE)
        self.assertNotIn("fake", parsed)
        self.assertEqual(len(parsed), 2)

    def test_merge_writes_user_label_and_keeps_unreviewed_as_claude(self):
        entries = [
            {"uri": "at://hard1", "text": "t", "tag": "hard",
             "claude_label": {"class": "hate", "severity": "moderate", "rationale": "x"},
             "user_label": None, "notes": "", "reviewed": False},
            {"uri": "at://core1", "text": "t", "tag": "core",
             "claude_label": {"class": "neutral", "severity": None, "rationale": "x"},
             "user_label": None, "notes": "", "reviewed": False},
        ]
        parsed = reconcile.parse_review(SAMPLE)
        merged = reconcile.apply(entries, parsed)
        by = {e["uri"]: e for e in merged}
        # hard1 reviewed + verdict differs from claude -> user_label set to counter
        self.assertEqual(by["at://hard1"]["user_label"]["class"], "counter")
        self.assertEqual(by["at://hard1"]["notes"], "this is actually counter-speech")
        self.assertTrue(by["at://hard1"]["reviewed"])
        # core1 not reviewed -> user_label stays None (falls back to claude at scoring)
        self.assertIsNone(by["at://core1"]["user_label"])


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run it — verify it fails**

```bash
cd /Volumes/Eregion/projects/bluex-v2/tools/benchmark && python3 test_reconcile.py
```

Expected: `ModuleNotFoundError: No module named 'reconcile'`.

- [ ] **Step 3: Implement `reconcile.py`**

Create `tools/benchmark/reconcile.py`:

```python
#!/usr/bin/env python3
"""Parse the Obsidian review doc and merge the user's verdicts/notes/reviewed
state back into benchmark-set.json.

Robustness: blocks are split on lines that are EXACTLY an anchor comment
(`<!-- bm: <uri> -->` as the whole line). An anchor-looking string inside a
blockquote (prefixed with '> ') is not a line-start anchor and is ignored.
"""
import json
import os
import re

SET = os.path.join(os.path.dirname(__file__), "benchmark-set.json")
REVIEW = os.path.expanduser(
    "~/Obsidian/projects/personal/bluex-v2/BlueX Benchmark Review.md"
)

ANCHOR = re.compile(r"^<!-- bm: (\S+) -->\s*$", re.MULTILINE)


def parse_review(text):
    """uri -> {verdict, notes, reviewed} for each anchored block."""
    out = {}
    matches = list(ANCHOR.finditer(text))
    for idx, m in enumerate(matches):
        uri = m.group(1)
        start = m.end()
        end = matches[idx + 1].start() if idx + 1 < len(matches) else len(text)
        block = text[start:end]
        verdict = ""
        notes = ""
        reviewed = False
        for line in block.splitlines():
            s = line.strip()
            if s.startswith("**Verdict:**"):
                verdict = s[len("**Verdict:**"):].strip()
            elif s.startswith("**Notes:**"):
                notes = s[len("**Notes:**"):].strip()
            elif s.startswith("- [x] reviewed") or s.startswith("- [X] reviewed"):
                reviewed = True
        out[uri] = {"verdict": verdict, "notes": notes, "reviewed": reviewed}
    return out


def apply(entries, parsed):
    """Write user_label/notes/reviewed into entries from parsed review data.
    A user_label is set only when the post is reviewed AND a verdict is present;
    severity is carried from claude_label when the verdict class matches, else None."""
    for e in entries:
        p = parsed.get(e["uri"])
        if not p:
            continue
        e["notes"] = p["notes"]
        e["reviewed"] = p["reviewed"]
        if p["reviewed"] and p["verdict"]:
            cl = e.get("claude_label") or {}
            sev = cl.get("severity") if p["verdict"] == cl.get("class") else None
            e["user_label"] = {"class": p["verdict"], "severity": sev}
    return entries


def main():
    if not os.path.exists(REVIEW):
        raise SystemExit(f"review doc not found: {REVIEW}")
    with open(REVIEW) as fh:
        parsed = parse_review(fh.read())
    with open(SET) as fh:
        entries = json.load(fh)
    apply(entries, parsed)
    with open(SET, "w") as fh:
        json.dump(entries, fh, ensure_ascii=False, indent=2)
    reviewed = sum(1 for e in entries if e.get("reviewed"))
    overrides = sum(1 for e in entries if e.get("user_label"))
    print(f"reconciled {len(parsed)} blocks → {reviewed} reviewed, {overrides} user labels set")


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run the test — verify it passes**

```bash
cd /Volumes/Eregion/projects/bluex-v2/tools/benchmark && python3 test_reconcile.py
```

Expected: `OK` (3 tests).

- [ ] **Step 5: Commit**

```bash
cd /Volumes/Eregion/projects/bluex-v2
git add tools/benchmark/reconcile.py tools/benchmark/test_reconcile.py
git commit -m "feat(benchmark): reconcile.py — merge user verdicts from review doc"
```

---

### Task 5: `report.py` — score models vs gold

**Files:**
- Create: `tools/benchmark/report.py`
- Create: `tools/benchmark/test_report.py`

- [ ] **Step 1: Write the failing test**

Create `tools/benchmark/test_report.py`:

```python
import unittest
import report

CLASSES = ("hate", "counter", "neutral")


class ScoreTest(unittest.TestCase):
    def test_perfect_model_scores_1(self):
        gold = {"u1": "hate", "u2": "neutral", "u3": "counter"}
        preds = {"u1": {"m": "hate"}, "u2": {"m": "neutral"}, "u3": {"m": "counter"}}
        metrics = report.score(gold, preds)["m"]
        self.assertEqual(metrics["accuracy"], 1.0)
        self.assertEqual(metrics["macro_f1"], 1.0)

    def test_precision_recall_on_confusion(self):
        # gold: 2 hate, 2 neutral. model calls everything hate.
        gold = {"a": "hate", "b": "hate", "c": "neutral", "d": "neutral"}
        preds = {k: {"m": "hate"} for k in gold}
        m = report.score(gold, preds)["m"]
        # hate: precision 2/4=0.5, recall 2/2=1.0, f1=0.667
        self.assertAlmostEqual(m["per_class"]["hate"]["precision"], 0.5, places=3)
        self.assertAlmostEqual(m["per_class"]["hate"]["recall"], 1.0, places=3)
        self.assertAlmostEqual(m["per_class"]["hate"]["f1"], 2 / 3, places=3)
        # neutral: never predicted -> precision 0 (no preds), recall 0
        self.assertEqual(m["per_class"]["neutral"]["recall"], 0.0)

    def test_only_scores_posts_the_model_predicted(self):
        gold = {"a": "hate", "b": "neutral"}
        preds = {"a": {"m": "hate"}}  # model only did 'a'
        m = report.score(gold, preds)["m"]
        self.assertEqual(m["n"], 1)
        self.assertEqual(m["accuracy"], 1.0)

    def test_agreement_matrix_pairwise(self):
        gold = {"a": "hate", "b": "neutral"}
        preds = {"a": {"m1": "hate", "m2": "hate"}, "b": {"m1": "neutral", "m2": "hate"}}
        agree = report.agreement(preds)
        # m1 vs m2 agree on 'a' only -> 1/2 = 0.5
        self.assertAlmostEqual(agree[("m1", "m2")], 0.5, places=3)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run it — verify it fails**

```bash
cd /Volumes/Eregion/projects/bluex-v2/tools/benchmark && python3 test_report.py
```

Expected: `ModuleNotFoundError: No module named 'report'`.

- [ ] **Step 3: Implement `report.py`**

Create `tools/benchmark/report.py`:

```python
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
    """preds: {uri: {model: class}}. Returns {model: metrics}."""
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
        SELECT p.ZURI, a.ZMODELNAME, a.ZSPEECHCLASS, a.ZCONFIDENCE, a.ZCREATEDAT
        FROM ZANNOTATION a JOIN ZPOST p ON a.ZPOST = p.Z_PK
        WHERE a.ZSTAGE='llm' AND a.ZCONFIDENCE > 0 AND p.ZURI IN ({placeholders})
        """,
        list(uris),
    ).fetchall()
    preds, newest = {}, {}
    for uri, model, cls, conf, created in rows:
        key = (uri, model)
        if key not in newest or (created or 0) > newest[key]:
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
        if all(c == gold[uri] for c in per_model.values()):
            continue  # everyone agrees with gold
        calls = ", ".join(f"{m}={c}" for m, c in sorted(per_model.items()))
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
```

- [ ] **Step 4: Run the test — verify it passes**

```bash
cd /Volumes/Eregion/projects/bluex-v2/tools/benchmark && python3 test_report.py
```

Expected: `OK` (4 tests).

- [ ] **Step 5: Run against the real store (3 reference models already present)**

```bash
cd /Volumes/Eregion/projects/bluex-v2/tools/benchmark && python3 report.py baseline 2>&1 | head -25
```

Expected: a scores table for phi4:14b, qwen2.5:7b, gpt-oss-120b (gold currently = Claude labels once Task 2's set is labeled; if `claude_label` is still empty, gold will be empty and the table shows n=0 — that's expected until labeling happens, see post-implementation steps). The agreement matrix should populate regardless since it doesn't need gold.

- [ ] **Step 6: Commit**

```bash
cd /Volumes/Eregion/projects/bluex-v2
git add tools/benchmark/report.py tools/benchmark/test_report.py
git commit -m "feat(benchmark): report.py — P/R/F1 + macro-F1 + agreement vs gold"
```

---

### Task 6: `run.sh` orchestrator

**Files:**
- Create: `tools/benchmark/run.sh`

- [ ] **Step 1: Write the script**

Create `tools/benchmark/run.sh`:

```bash
#!/bin/zsh
# Benchmark one model on the pinned set, then regenerate the report.
# Usage: tools/benchmark/run.sh <model-id>   (e.g. gemma4:12b)
set -u

if [ $# -lt 1 ]; then
  echo "usage: $0 <model-id>" >&2
  exit 2
fi
MODEL="$1"
HERE="${0:A:h}"
SET="$HERE/benchmark-set.json"
ANNOTATE="$HOME/.local/bin/blueX-annotate"

if [ ! -f "$SET" ]; then
  echo "benchmark set not found: $SET — run build_set.py first." >&2
  exit 1
fi

echo "warming $MODEL…"
curl -s -o /dev/null http://localhost:11434/api/generate \
  -d "{\"model\":\"$MODEL\",\"prompt\":\"warmup\",\"stream\":false}" 2>/dev/null

echo "annotating benchmark set with $MODEL…"
"$ANNOTATE" --benchmark "$SET" --pass llm --model "$MODEL" --pace steady

echo "generating report…"
python3 "$HERE/report.py" "${MODEL//[:\/]/-}"
```

- [ ] **Step 2: Make executable + syntax-check**

```bash
chmod +x /Volumes/Eregion/projects/bluex-v2/tools/benchmark/run.sh
zsh -n /Volumes/Eregion/projects/bluex-v2/tools/benchmark/run.sh && echo "syntax OK"
```

Expected: `syntax OK`.

- [ ] **Step 3: Commit**

```bash
cd /Volumes/Eregion/projects/bluex-v2
git add tools/benchmark/run.sh
git commit -m "feat(benchmark): run.sh — one-command model benchmark + report"
```

---

## Post-implementation (controller, not a subagent task)

After all tasks pass:
1. **Claude labels the set:** read `benchmark-set.json`, fill `claude_label` for every entry (class + severity + one-line rationale) applying the German-context criteria, write the file back. Re-run `make_review.py` to generate the Obsidian review doc.
2. **First report:** `python3 report.py baseline` → Claude writes the qualitative verdict on phi4 vs qwen vs gpt-oss vs gold.
3. Hand the review doc to the user for their verdicts; `reconcile.py` merges them; re-run `report.py` for the expert-gold scores.
4. When `gemma4:12b` lands in Ollama: `ollama pull gemma4:12b && tools/benchmark/run.sh gemma4:12b`, then Claude evaluates.
