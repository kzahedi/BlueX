# Manual labelling tab — design (2026-08-13)

A tab in BlueX for hand-labelling replies, producing the held-out gold set the hate
detection programme depends on.

## Why this exists

The project has no working hate detector. Measured 2026-08-11: no off-the-shelf model
separates moderator-labelled hate from moderator-labelled rudeness (best 0.533 AUC; several
*inverted* to ~0.19). See
`docs/superpowers/specs/2026-08-12-hate-detection-programme-design.md`.

Human annotation capacity is **a few hundred posts, one annotator**. That is enough to
*validate* a classifier and not to train one — so these labels are **held-out gold, never
training data**. Spending them on training would leave nothing to measure against.

## Decisions

**AMENDED 2026-08-14 after the fine-tune diagnostic.** Models trained on hate-vs-`rude`
reach 0.96 but only 0.61–0.68 against *random* replies — the deployment distribution.
The scarcest labels are therefore **uniform random draws** (base-rate estimation and
deployment-distribution validation; see the LaTeX proposal's Stage 0), not just filtered
pools. The tab must support both, and a **uniform random pool must be a first-class
preset**, not something approximated by clearing filters. The sampling-frame recording
below is what keeps the two usable for different purposes.

| Decision | Choice | Rationale |
|---|---|---|
| Sampling | **Filtered pool, then random draw within it — AND uniform random as a first-class mode** | Filtered pools find positives efficiently; uniform draws are the only unbiased base-rate/validation source. Both needed, frames recorded. |
| Sampling frame | **Recorded with every label** | Non-negotiable; see below. |
| Context shown | **Root post + immediate parent** | User: *"context matters."* |
| Model outputs shown | **Never, during labelling** | Anchoring would compromise the only independent ground truth in the project. |
| `severity` field | **Out of scope for v1** | Exists on `Annotation` but unused. Adding it multiplies decisions per post. Addable later without migration. |
| Counter-speech | Selectable, but see caveat | `speechClass` already supports it; counter-speech is relational and its own design is deferred. |

### The sampling frame must be stored — this is the load-bearing requirement

If some labels come from a high-incivility filter, some from moderator-flagged posts, and
some from a uniform draw, then without a recorded frame they are **indistinguishable later**
and any prevalence estimate computed across them is silently biased.

Storing the frame costs nothing now and preserves the ability to weight or stratify
afterwards. Without it the labels are usable for validation only, never for measurement.

Record, per label: the filter predicate that defined the pool, the pool's size at draw time,
the batch id, and the draw's RNG seed.

## Context display — always available, measured

| | Count | Share |
|---|---|---|
| Replies total | 2,128,007 | |
| Depth 1 — parent **is** the root | 1,667,532 | 78% |
| Deeper than 1 | 460,475 | 22% |
| **Deeper replies whose parent is missing from the store** | **0** | — |

So the pane can always show root + parent. For the 78% at depth 1 they are the same post and
only one context block is shown.

## Components

**Pool builder.** Filters over the corpus: outlet, date range, incivility score band
(`/Volumes/Eregion/bluex-incivility/`), moderator label presence/value, thread reply-count,
language, author reply-volume. Shows the matching count *before* drawing, so the annotator
knows the frame they are sampling from.

**Batch drawer.** Draws N (default 100) at random from the pool with a recorded seed. Posts
already drawn are excluded, so a pool empties as it is worked through and batches never
overlap.

**Labelling view.** One post at a time:
- the reply text
- the root post (outlet, text, date)
- the immediate parent, when different from the root
- class buttons, keyboard-driven
- optional free-text note

Deliberately absent: incivility score, any model prediction, the moderator label — **even
when the pool was built from them.**

**Progress and stopping.** Position in batch, elapsed time, and a clean stop that preserves
partial progress. Time-per-item is recorded: unusually fast decisions are a quality signal
worth reviewing.

## Storage

An `Annotation` per label with `stage: "human"`, keeping it separate from every model pass.
Plus: annotator identifier, batch id, sampling frame, time-to-decide, and pass number (see
re-labelling).

`speechClass` (`hate` / `counter` / `neutral`) already exists. `confidence` may carry the
annotator's own certainty; `reasoning` the optional note.

## Re-labelling — the only reliability measure available

With a single annotator **Cohen's κ is unavailable** — it requires two or more raters. The
one measure obtainable is **intra-rater agreement**: label a batch, wait, label it again
blind, compare.

The tab supports re-drawing a previously-labelled batch with prior labels hidden, storing the
result as a second pass rather than overwriting. Agreement between passes is then computable
and reportable.

This is weaker than inter-rater agreement and must be described as such in any write-up. It
is not a substitute; it is what is available.

## Error handling

- **Store unavailable** (external volume) must surface as an explicit failure, never as an
  empty pool — "no store" and "no matching posts" are different facts.
- **Interrupted batch** resumes where it stopped; a partially-labelled batch is never lost
  and never silently re-drawn.
- **Empty pool** states plainly that the filter matched nothing, distinct from an exhausted
  pool where everything has already been labelled.

## Testing

- Pool filtering returns what the predicate says, verified against a fixture.
- A drawn post is never re-drawn in a later batch from the same pool.
- The recorded seed reproduces the same draw.
- Sampling frame round-trips intact.
- Re-labelling stores a second pass without overwriting the first.
- Interrupted batch resumes with partial progress intact.
- Model outputs are absent from the labelling view's data path — not merely hidden in the UI,
  but not fetched, so they cannot leak into it.

## Out of scope

- `severity` labelling.
- Multi-annotator workflows and Cohen's κ — needs a second annotator, not a UI change.
- Active learning / uncertainty sampling. Sensible later, but it requires a working model,
  and there isn't one yet.
- Any use of these labels as training data.
