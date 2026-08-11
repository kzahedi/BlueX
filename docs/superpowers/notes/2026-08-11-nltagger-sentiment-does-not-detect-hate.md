# NLTagger sentiment does not detect hate — measured, 2026-08-11

**Result: AUC 0.508 against moderator-labelled hate. Chance is 0.500.**

Apple's `NLTagger` sentiment score carries **no information** about whether a reply was
labelled `intolerant` / `threat` by a Bluesky moderator. This is not a weak signal to be
calibrated — the two distributions have the same median.

## Method

- **Positives (n=235):** replies carrying a moderator label in
  `{intolerant, threat, extremist, intolerant-race}`, taken from the completed post-label
  sweep (`/Volumes/Eregion/bluex-labels/label-harvest-posts-2026-08-10T124533Z.jsonl`,
  1,382,554 subjects processed, 0 failed batches). Negated labels excluded.
  238 such posts existed; 235 had non-empty text in the store.
- **Controls (n=952):** replies drawn at random from the corpus, excluding every
  label-carrying post, at a 4:1 ratio.
- **Scoring:** the exact configuration the app uses —
  `NLTagger(tagSchemes: [.sentimentScore])`, `unit: .paragraph`, plus
  `NLLanguageRecognizer` — mirroring `BlueX/Services/Annotation/NLTaggerAnalyser.swift`.
- Store read `?mode=ro` while a scrape was running; no writes.

## Results

| | Hate (n=235) | Control (n=952) |
|---|---|---|
| Mean | −0.525 | −0.484 |
| **Median** | **−0.600** | **−0.600** |
| sd | 0.454 | 0.518 |
| score < 0 | 83.0% | 77.6% |
| score > 0 | 8.9% | 14.4% |
| score == 0 | 8.1% | 8.0% |

**AUC (lower sentiment ⇒ hate): 0.508.**

Language mix: hate 89% en / 8% de; control 82% en / 14% de.

## Why it fails

Replies to news accounts are **already overwhelmingly negative** — the control group
averages −0.484 with 78% scoring negative. Negativity is the *baseline* of this corpus,
not a discriminating feature within it.

Sentiment measures negativity. Hate is a small subset of negative content. A negativity
score therefore has no purchase inside a population that is negative almost everywhere.

This is a stronger and more useful finding than the anecdotal misclassifications recorded
in `docs/superpowers/specs/2026-08-04-bluex-scrape-and-sentiment-design.md` (e.g. an
insult scoring +0.4, an expulsion suggestion scoring +1.0). Those showed individual
errors. This shows the **distributions are the same shape** — no threshold, rescaling or
calibration can recover a signal that is not there.

## Consequences

1. **Do not use sentiment as a hate feature.** It would add noise and invite a spurious
   correlation. This closes the question; it does not need re-testing at a larger n.
2. **It may still serve as a descriptive covariate** — "how negative is discourse around
   outlet X over time" is a legitimate question, and at 164.5 posts/s scoring is nearly
   free. That is describing the corpus, not detecting hate.
3. **The ~4-hour full-corpus annotation pass is not justified by this result alone.**
   Scoring all 2.2M posts buys a covariate with no confirmed use. Defer until a specific
   analysis needs it.

## Caveats

- Hate positives skew slightly more English than controls (89% vs 82%). Not a direction
  that would mask a real effect, and with identical medians there is no effect to mask.
- Moderator labels are themselves a biased sample of hate: they capture what was reported
  and actioned, not all hateful content. The corpus almost certainly contains hate that
  carries no label. That biases toward *underestimating* a detector's true recall — but it
  cannot manufacture the null result seen here.
- n=235 positives is small. It is, however, the complete set of hate-labelled posts in a
  1.38M-reply sweep, not a subsample.

## Reproduction

Extraction and scoring scripts were throwaway (`/tmp/sent_input.tsv`,
`/tmp/sent_scored.tsv`). To reproduce: select label subjects in the four hate values from
the sweep JSONL, join to `ZPOST.ZTEXT`, draw a random control excluding all labelled
posts, score with the `NLTaggerAnalyser` configuration, and compute Mann-Whitney AUC.
