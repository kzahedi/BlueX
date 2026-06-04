# BlueX Model Benchmark — Design

**Date:** 2026-06-04
**Status:** Approved (design)
**Repo:** `/Volumes/Eregion/projects/bluex-v2`

## Goal

A reusable benchmark for evaluating any annotation model (local Ollama or cloud)
against a fixed, expert-labeled set of posts — so that when a new model ships
(e.g. Gemma 4 12B), evaluating it is three steps: `ollama pull`, run the
benchmark, read the scored report.

Two evaluation layers:
1. **Quantitative** — precision / recall / F1 per class + macro-F1 vs. a gold
   label set, plus a pairwise inter-model agreement matrix.
2. **Qualitative** — Claude (in-session) adjudicates the disagreements and
   hard-case results and writes a verdict on which model performs best and why.

The gold labels are **expert-authored by the user** (who wrote the founding
hate-speech paper), with Claude-proposed labels pre-filled so the user reviews
rather than labels from scratch.

## The benchmark set

Canonical store: `tools/benchmark/benchmark-set.json` (version-controlled).

Two strata:
- **core** (~198): the intersection of posts already annotated by `phi4:14b`,
  `qwen2.5:7b`, and `gpt-oss-120b`. Representative of the real reply
  distribution; gives an instant 3-model comparison with no new annotation.
- **hard** (~30–50): curated posts loaded with the failure modes found during
  development — `die Braunen`, `"China" ihr Kackhaufen`, `Neonazi mit Pimmel`,
  genuine counter-speech (antisemitism rebuttals), the disability+war post, etc.
  Pulled from the store by URI/text match.

### Schema (per entry)

```json
{
  "uri": "at://did:plc:.../app.bsky.feed.post/...",
  "text": "the full post text",
  "tag": "core",
  "claude_label": { "class": "hate", "severity": "moderate", "rationale": "…" },
  "user_label":   { "class": "hate", "severity": "moderate" },   // optional, authoritative when present
  "notes": "",          // user's 2 cents
  "reviewed": false      // set true when the user has eyeballed this post
}
```

`text` is embedded so the set is reviewable and reconstructable without a DB
lookup, and so the gold set survives even if the store is rebuilt.

**Gold label resolution:** `user_label` if present, else `claude_label`. The
report notes what fraction of gold is user-reviewed.

## Components

### 1. Set builder — `tools/benchmark/build_set.py`
Reads the SwiftData store, computes the core intersection, matches the hard-case
list (a small in-script list of text substrings → URIs), emits
`benchmark-set.json` with `claude_label` left empty (filled in step 2). Idempotent:
re-running preserves existing `user_label`/`notes`/`reviewed` by merging on `uri`.

### 2. Claude gold-labeling (one-time, in-session)
Claude reads every post in the set and fills `claude_label` (class + severity +
one-line rationale), applying the documented German-context criteria. Hard-case
labels are already known from development. This is the upfront cost.

### 3. Review doc — `tools/benchmark/make_review.py` → Obsidian
Generates `~/Obsidian/projects/personal/bluex-v2/BlueX Benchmark Review.md`:
- Hard cases first, then core.
- Each post block, anchored by `<!-- bm: <uri> -->` for robust parse-back:
  ```
  <!-- bm: at://…/post/abc -->
  ### [12] · hard
  > <full post text>

  **Claude:** hate (moderate) — targets X via slur
  **Verdict:** hate          ← change only if you disagree
  **Notes:**
  - [ ] reviewed
  ```
- `Verdict:` is pre-filled with the Claude label so the default is "accept".
- Resumable: review in chunks; `- [x] reviewed` tracks progress.

### 4. Reconcile — `tools/benchmark/reconcile.py`
Parses the review doc by `<!-- bm: <uri> -->` anchors, extracts `Verdict:`,
`Notes:`, and the `reviewed` checkbox per post, and merges them into
`benchmark-set.json` as `user_label` / `notes` / `reviewed`. Robust to arbitrary
text in the blockquote because it splits on the anchors, not on content.

### 5. CLI benchmark mode — `cli/annotate/main.swift`
Add `blueX-annotate --benchmark <path>`: annotate **exactly** the URIs listed in
the JSON file with the chosen model, bypassing the pending/newest-N selection (a
brand-new model has the whole store pending and would otherwise never hit the set).
Reuses the existing classify + persist loop. Annotations coexist, keyed by
`modelName`, so re-runs and new models accumulate side by side.
Mutually exclusive with `--coverage` and `--limit`.

### 6. Report — `tools/benchmark/report.py`
Reads `benchmark-set.json` + all model annotations for those URIs from the store.
Emits `docs/benchmarks/<date>-<model>.md` (and an all-models comparison):
- Per model: class distribution; precision / recall / F1 per class; **macro-F1**
  (ties to the founding paper's metric); accuracy; mean confidence.
- Pairwise inter-model agreement matrix.
- Every gold-disagreement, hard cases flagged, with text + each model's call.
- Header line: gold coverage (% user-reviewed vs. Claude-default).

### 7. Orchestrator — `tools/benchmark/run.sh <model-id>`
`ollama`-pull is the user's step. `run.sh` runs `blueX-annotate --benchmark
benchmark-set.json --model <id>` then `report.py`. Claude then reads the report
and writes the qualitative verdict in-session.

## Recurrence (the point)

New model out →
1. `ollama pull <model>`
2. `tools/benchmark/run.sh <model>`
3. Claude reads the report → verdict.

Gold improves over time as the user reviews more posts; no re-labeling needed per
model.

## Testing
- `report.py` scoring (P/R/F1, macro-F1, agreement) — unit-tested with a small
  fixture of gold + model labels. Pure data, no store.
- `reconcile.py` anchor parsing — unit-tested with a sample review doc including
  posts whose text contains markdown/newlines/emoji.
- `--benchmark` CLI mode — smoke test (annotates a 2-URI file, confirms 2 rows).

## Out of scope
- Automated label-by-a-bigger-model (gold is Claude-proposed + user-confirmed).
- Severity scoring beyond class-level F1 (severity stored, not scored initially).
- Any GUI surface — this is a CLI/data workflow.

## File summary

| File | Responsibility |
|------|----------------|
| `tools/benchmark/benchmark-set.json` | Canonical pinned set + labels (version-controlled) |
| `tools/benchmark/build_set.py` | Build/refresh the set from the store (merge-preserving) |
| `tools/benchmark/make_review.py` | Generate the Obsidian review doc |
| `tools/benchmark/reconcile.py` | Merge user verdicts/notes back into the JSON |
| `tools/benchmark/report.py` | Score models vs. gold → markdown report |
| `tools/benchmark/run.sh` | Orchestrate run + report for one model |
| `cli/annotate/main.swift` | `--benchmark <file>` annotation mode |
| `docs/benchmarks/<date>-<model>.md` | Generated reports |
