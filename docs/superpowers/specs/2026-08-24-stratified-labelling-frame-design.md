# Stratified labelling with recorded weights — design

**Date:** 2026-08-24
**Status:** design, awaiting the committee's score distribution before band boundaries
are fixed
**Motivation:** measured Stage 0 result — 5 hate in 76 uniform-random labels (6.6%,
95% CI [2.8%, 14.5%]). Uniform sampling therefore spends ~93 labels in 100 on
material that teaches the classifier little, while the base rate itself is now
established well enough to anchor a weighted estimator.

## 1. What this must achieve simultaneously

1. **Concentrate labels where they are informative** — high committee score, and high
   committee disagreement.
2. **Keep prevalence estimable without bias.** A label drawn because a model liked it
   can never, on its own, tell us how common hate is. Stratified sampling with known
   weights can, because the selection probability of every labelled item is known.

Estimator (Horvitz–Thompson / stratified mean): with strata $h$ of known population
size $N_h$, sample size $n_h$, and observed positives $k_h$,

$$\hat{p} = \sum_h \frac{N_h}{N}\cdot\frac{k_h}{n_h}$$

with variance summed across strata. This is unbiased for the population prevalence
**provided** sampling within each stratum is genuinely random and the weights
$N_h/N$ are recorded at draw time — hence every requirement below.

## 2. The blindness problem, and its resolution

The labelling view is **structurally blind** to model output: `LabellingContext` has no
score fields, so nothing can leak into the annotation UI. Stratification, however,
*requires* knowing scores in order to choose what to present. Naively giving the app
access to `committee.db` would put scores one property access away from the view — and
the blindness guarantee would then rest on nobody ever adding a field, which is exactly
the kind of assurance that decays.

**Resolution: the app never sees a score.** The committee tooling (Python) produces a
**frame file** — an opaque list of URIs plus stratum metadata — and the app draws from
that list. The app learns *which* posts to show and *what to record about how they were
chosen*, never *why* they were chosen.

```json
{
  "frame_kind": "stratified",
  "created_at": "2026-08-24T…Z",
  "committee": {"db_sha256": "…", "members": ["incivility_toxicity", "tfidf_lr", "doc2vec_lr"]},
  "population_total": 2124509,
  "strata": [
    {"id": "mean_pct_top_0.1", "definition": "mean_pct >= 99.9",
     "population_size": 2124, "uris": ["at://…", "…"]},
    {"id": "spread_top_1", "definition": "spread_pct >= 99.0",
     "population_size": 21245, "uris": [...]}
  ]
}
```

- `uris` per stratum is itself a **random subsample** of that stratum, drawn in Python
  with a recorded seed, so the app's own draw order cannot reintroduce selection bias.
- `population_size` is the stratum's full size in the corpus — the number the weight
  $N_h/N$ is computed from. Without it the estimator is unusable, so the file is
  invalid without it.
- `db_sha256` pins the committee scores the strata were cut from; a later recomputation
  of the committee produces a different frame, and analyses must not mix the two.

## 3. Strata — revised 2026-08-24 against the committee's measured behaviour

The committee has been built and scored (commit `82768ce`, 2,197,431 posts). Its
measured properties change the strata from the original sketch:

**Pairwise Spearman:** toxicity–tfidf 0.031, toxicity–doc2vec 0.021, tfidf–doc2vec
0.210. **Top-1% Jaccard:** 0.0001, 0.0020, 0.0296 — and **zero posts lie in all three
members' top 1%**. The members are decorrelated far below the 0.9 redundancy line, so
the disagreement signal is genuine. But they are decorrelated *because they measure
different constructs*, which is the fact the strata must respect.

`mean_pct` is not meaningless — its top 0.1% has member medians of 92.5 / 96.9 / 98.6,
i.e. it is a **conjunction filter** selecting posts that are simultaneously uncivil and
hate-like by both supervised members. It is therefore precision-oriented, and carries a
blind spot that matters more than its precision: requiring high toxicity systematically
excludes **cleanly-worded hate**, the exact material the project exists to find (the
measured hate-vs-rude AUC of 0.198 is this blind spot quantified). A labelling set drawn
only from `mean_pct` would be full of vulgar abuse and nearly free of polite
intolerance.

| Stratum | Definition | Purpose and known bias |
|---|---|---|
| `mean_top_0.1` | `mean_pct >= 99.9` | conjunction region: highest expected precision; **skews to vulgar hate, misses clean-worded hate** |
| `tox_top_1` | toxicity percentile >= 99 | incivility's own extreme; measures how much incivility is *not* hate |
| `tfidf_top_1` | tfidf percentile >= 99 | lexical hate signal; interpretable coefficients |
| `d2v_top_1` | doc2vec percentile >= 99 | corpus-trained, bilingual — the member most likely to surface clean-worded and German hate that toxicity ignores |
| `spread_top_1` | `spread_pct >= 99` | maximum disagreement; informative per label, but "disagreement" here means the constructs differ, **not** that the post is borderline hate |
| `mid` | 25–99 percentile of `mean_pct` | the region a deployed threshold must not sweep in |
| `bottom` | below 25th percentile | bounds false negatives; small n, but without it "nothing down here" is unfalsifiable |

Because the per-member bands are near-disjoint, 59,241 posts sit in at least one
member's top 1% — a diverse candidate pool uniform sampling would take an impractical
number of labels to reach.

**The question these strata answer** is not "how much hate is there" (the uniform pass
answers that) but **which member's construct tracks the annotator's judgment**. Report
per-stratum precision by member, so a member that only ever surfaces profanity is
visibly distinguishable from one that finds the intolerance the project is about.

## 4. What each label must record

The existing `SamplingFrame` gains a `stratified` kind carrying: `stratumID`,
`stratumDefinition` (verbatim string), `populationSize`, `frameFileSHA256`, and the
Python-side `drawSeed`. `Annotation` already records `annotatorID`, `batchID`,
`passNumber` and `timeToDecideSeconds`; no change needed there.

**Analyses must partition by frame kind, always.** `tools/labelling/base_rate.py` keeps
computing the *uniform-random* estimate from `uniformRandom` pass-1 labels only — that
number stays exactly what it is today. Stratified labels feed a **separate** weighted
estimator (new subcommand), which reports $\hat{p}$ with its stratified variance and
prints the per-stratum table so the reader can see where the estimate's weight came
from. The two estimates should agree within their intervals; if they do not, that
disagreement is itself a finding about the weights and must be reported, not smoothed.

## 5. Ordering and honesty constraints

- The uniform-random pass stays the anchor. Do not delete, re-draw, or "top up" it with
  stratified labels; its value is that its selection probability was uniform.
- Stratified labels are **not** interchangeable with uniform ones for any purpose other
  than the weighted estimator and per-stratum precision/recall. Training on them is
  allowed only with the same explicit demotion rule as elsewhere: once used for
  training they leave the evaluation set permanently, recorded.
- Committee members trained on moderation labels are distant supervision, not truth. A
  stratum's *definition* therefore inherits that bias; the weighted estimate corrects
  for unequal *selection*, not for a mis-specified score.
- If the committee's members turn out to be strongly correlated (Spearman > ~0.9), the
  `spread_top_1` stratum is close to meaningless and should be dropped rather than
  reported as a disagreement sample.
