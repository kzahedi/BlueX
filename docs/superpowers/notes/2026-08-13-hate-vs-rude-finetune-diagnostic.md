# Fine-tuning directly on hate-vs-rude works — 0.93–0.96 CV AUC, dramatically above the 0.533 off-the-shelf ceiling. But the resulting models generalise poorly to hate-vs-random (0.61–0.68), which matters for full-corpus deployment.

**The core diagnostic question is answered: yes, moderator-labelled hate is learnable from text, separately from moderator-labelled rudeness, when a model is trained directly on that distinction.** This reframes the programme (see `docs/superpowers/specs/2026-08-12-hate-detection-programme-design.md`, architecture A): the LLM-labelling stage is not obviously necessary, and the manual-labelling tab's role shifts from "bootstrap from nothing" to "produce a held-out gold set to validate a model that already works." It does **not** mean a deployable full-corpus detector already exists — see the second finding below, which is the reason this is not yet a green light to build one.

## Method

Same eval set as the rest of `tools/benchmark/` (`/Volumes/Eregion/bluex-benchmark/eval-set-2026-08-11T101434Z.jsonl`, unchanged, not rebuilt): 235 `positive` (moderator `intolerant`/`threat`/`extremist`/`intolerant-race`), 872 `hard_negative` (moderator `rude`), 940 `easy_negative` (random, unlabelled).

- **CV, not a single split.** 235 positives is too few for one train/test split to mean anything — it would be dominated by which examples happened to land where. Every candidate (baselines and fine-tuned models alike) was run through the **identical stratified 5-fold CV harness** over the `positive`/`hard_negative` core set (n=1,107). The headline number is mean ± sd of the per-fold test AUC, never a single fold's number.
- **Trained on the distinction that matters**: label = 1 for `positive`, 0 for `hard_negative`. `easy_negative` was never in any training fold; each example was scored by all 5 fold models and the mean of those 5 scores used for the comparability number (documented in the output JSON, not hidden).
- **Baselines in the same harness**: the keyword lexicon (`tools/benchmark/detectors/lexicon.py`, scored once, CV test-fold structure applied after the fact since it has no training) and TF-IDF (1–2 grams, min_df=2) + logistic regression, genuinely refit inside every fold.
- **Fine-tuned candidates**: `xlm-roberta-base` (small multilingual encoder) and `cardiffnlp/twitter-roberta-base` (English social-media-domain encoder). Both loaded and trained successfully. A third candidate (`unitary/unbiased-toxic-roberta`, further fine-tuned) was dropped to keep the run short, per instruction to cut candidates rather than methodology when time is tight — the 5-fold CV and the TF-IDF baseline are what make the result meaningful, so those were preserved intact.
- **Overfitting control**: up to 4 epochs, early stopping (patience 1) on a 15% internal validation slice carved out of each fold's training data (never the test fold). Per-fold **train** AUC is reported next to per-fold **test** AUC specifically to make memorisation visible.
- CPU (`--device cpu`), `max_length=96`, `batch_size=16`, `lr=2e-5`, competing with a concurrent Swift build on the same machine — slower than a quiet machine, no effect on correctness.
- Metrics are computed by `tools/benchmark/metrics.py` and `evaluate.evaluate_head` — reused, not reimplemented — exactly as `evaluate.py` uses them for the rest of the benchmark, including the per-language suppression rule (`MIN_LANGUAGE_N=20`).

Full artefacts: `/Volumes/Eregion/bluex-benchmark/finetune-diagnostic-2026-08-13T120605Z.json` (per-fold detail, per-language breakdown) and `.md` (summary table). Code: `tools/benchmark/finetune_diagnostic.py`, tests in `tools/benchmark/test_finetune_diagnostic.py` (9 tests, pure-logic — fold construction, stratification, baseline plumbing — no model downloads).

## Results

### Headline: mean ± sd CV test AUC, positive vs hard_negative (the distinction that matters)

| candidate | mean CV test AUC | sd | mean train AUC | overfit gap | per-fold test AUC |
|---|---|---|---|---|---|
| lexicon (baseline, untrained) | 0.508 | 0.011 | 0.508 | ~0.000 | 0.505, 0.497, 0.505, 0.526, 0.505 |
| TF-IDF + logistic regression | 0.943 | 0.019 | 0.996 | 0.053 | 0.930, 0.917, 0.960, 0.956, 0.954 |
| `xlm-roberta-base` (fine-tuned) | 0.932 | 0.033 | 0.967 | 0.035 | 0.938, 0.881, 0.959, 0.961, 0.922 |
| `cardiffnlp/twitter-roberta-base` (fine-tuned) | **0.959** | 0.014 | 0.994 | 0.035 | 0.954, 0.938, 0.971, 0.971, 0.963 |

**Best: `cardiffnlp/twitter-roberta-base`, 0.959 ± 0.014.** Compare to the off-the-shelf ceiling: best generic detector previously measured was 0.533 (`twitter-roberta-base-hate#hate`); several were *inverted* (0.198 — rating `rude` as more toxic than hate 80% of the time). Every candidate trained directly on this distinction — including the crude keyword-count-refit TF-IDF baseline — clears 0.93. This is not a marginal improvement; it is a different regime.

**Overfitting check, stated plainly**: train AUC exceeds test AUC by 0.03–0.05 for every trained candidate, and no candidate showed the ~1.0-train/~0.5-test collapse that would indicate pure memorisation. The lexicon's near-zero gap is a sanity check on the harness, not evidence of anything (it does not train). TF-IDF's gap (0.053) is the largest of the trained candidates, consistent with a linear bag-of-words model latching onto a modest number of exact-phrase repeats in the corpus (see caveats).

### Per-language (en only meets the n≥20 threshold)

| candidate | en AUC (n=208 pos / 813 neg) | de | other |
|---|---|---|---|
| lexicon | 0.509 | suppressed (n=19) | suppressed (n=8/40) |
| TF-IDF + logreg | 0.955 | suppressed | suppressed |
| `xlm-roberta-base` | 0.926 | suppressed | suppressed |
| `cardiffnlp/twitter-roberta-base` | 0.959 | suppressed | suppressed |

**German is not reportable here — 19 positives, below `MIN_LANGUAGE_N=20`.** This confirms the gap flagged in the programme-design spec; nothing here should be read as a claim about German performance, positive or negative. `cardiffnlp/twitter-roberta-base` is English-domain-pretrained and its result is dominated by the English cell anyway (813 of 872 hard_negatives are English), so this diagnostic gives no information about whether an English-social-media encoder specifically penalises German text.

### The finding that qualifies the headline: positive vs easy_negative (pooled, comparability number)

| candidate | vs hard_negative (headline) | vs easy_negative (pooled) |
|---|---|---|
| lexicon | 0.508 | 0.511 |
| TF-IDF + logreg | 0.943 | 0.652 |
| `xlm-roberta-base` | 0.932 | 0.612 |
| `cardiffnlp/twitter-roberta-base` | 0.959 | 0.676 |

**Every trained candidate separates hate from `rude` far better than it separates hate from random text.** This is the opposite pattern from the off-the-shelf toxicity models (which were good at hate-vs-random, 0.85–0.90, and bad or inverted at hate-vs-rude). It is not a contradiction — it is the direct consequence of what these models were trained to do: distinguish `positive` from `hard_negative` specifically. `easy_negative` was never in any training fold. A plausible mechanism, consistent with the TF-IDF coefficient inspection below: these models appear to have partly learned "**absence of profanity** looks like hate" (because within the training distribution, the negative class is `rude`, which is saturated with profanity, and the positive class mostly is not) — a cue that is close to useless, and possibly actively misleading, against genuinely random corpus text that also lacks profanity for unrelated reasons.

**Consequence for the programme, stated without smoothing it over:** the full-corpus deployment scenario (`docs/superpowers/specs/2026-08-12-hate-detection-programme-design.md`: "every post classified," 2.4M posts, the overwhelming majority of which are neither `rude` nor `intolerant`) looks much more like hate-vs-easy_negative than hate-vs-hard_negative. **A model trained only on positive-vs-hard_negative, as this diagnostic did (deliberately, per the task spec — "train on positive vs hard_negative, that is the distinction that matters"), is not evidence that the same model would perform at 0.93–0.96 across the full corpus.** It is evidence that the distinction is learnable at all, which was the question. Any production model needs training exposure to `easy_negative`-like text too (e.g. a genuine three-way objective, or positive-vs-everything), which this diagnostic did not test and which is the natural next step if this direction is pursued.

## Why this is believable, not an artefact

Inspected the TF-IDF logistic regression's top coefficients directly (not the fine-tuned transformers, which are not linearly inspectable, but they were trained on the same distinction and score similarly, so this is suggestive):

- **Toward hate (positive class):** `muslim`, `jews`, `trans`, `women`, `israel`, `white`, `religion`, `kill`, `die`, `death`, `hang`, `retard(ed)`, `exist`.
- **Toward rude (hard_negative class):** `fuck`, `fuck off`, `fuck you`, `shit`, `bitch`, `asshole`, `idiot`, `bullshit`, `shut (up)`.

This is exactly the distinction the programme-design spec predicted and exactly what the inverted off-the-shelf toxicity heads (0.198) were missing: hate is marked by group-identity and violence vocabulary in otherwise clean language; rudeness is marked by profanity and generic insult, largely without group-identity content. A model that scores profanity as "more toxic" (as the generic heads do) gets this backwards. A model — or a linear bag-of-words baseline — trained directly on the moderator distinction picks up the right cue.

**Duplicate-text caveat on the CV numbers**: 117 of 1,107 core examples (10.6%) are exact duplicates of another example in the same class (e.g. "Fuck off" appears 19 times, always labelled `rude`; no duplicate group mixes classes). `StratifiedKFold` splits by index, so some of these duplicates land in different folds, letting a model partly "memorise" a common boilerplate phrase rather than generalise. This inflates the CV numbers somewhat, especially for TF-IDF. It does not explain the result away — the top-coefficient inspection above shows generalisable, semantically meaningful features, not just memorised boilerplate — but it means the true generalisation AUC is probably somewhat below the 0.93–0.96 reported here, not above it.

## Caveats (do not drop these when this note is cited)

1. **Moderator labels are a precision test, not a recall test** — same caveat as every other measurement in this benchmark (`build_eval_set.py`, `evaluate.py`, the 2026-08-11 NLTagger note). A model scoring well here has learned to reproduce what moderators reported and actioned; it says nothing about hate that was never reported.
2. **n=235 positives.** Even with 5-fold CV, sd of 0.01–0.03 on the trained candidates is a real but not enormous safety margin at this n. This is a decisive-enough result to redirect the programme, not a result precise enough to quote to two decimal places in a paper.
3. **German is unmeasured**, not measured-and-negative. 19 positives cannot support a claim in either direction.
4. **The easy_negative number is the ceiling being tested for architecture A vs B, not a verdict on it.** It shows the *specific* trained-on-hard_negative-only model doesn't generalise to random text as well as it separates hate from rude — it does not show that no encoder-based approach could reach a comparable number against random text if trained with `easy_negative` exposure too.
5. Runs used CPU (not MPS — MPS ran out of memory under concurrent system load from a live scrape/build at the time; CPU was slower but did not change correctness) and a max sequence length of 96 tokens, which truncates longer replies. Neither is expected to bias the *comparison* between candidates, since all were run identically.

## What this means for the programme

- **Architecture A (fine-tune directly on the 1,124 moderator labels) is not dead on arrival — the opposite of the concern in the design spec ("may simply overfit").** It clears an enormous margin over every off-the-shelf model and shows a controlled, modest overfit gap, not memorisation.
- **It is not yet sufficient on its own for the "every post classified" full-corpus deliverable**, because it was validated on hate-vs-rude, and the corpus is overwhelmingly neither. The natural next step, if this direction is pursued, is a model trained (or additionally validated) against a hate-vs-everything objective that includes `easy_negative`-like examples, then checked against the user's held-out gold set exactly as the validation design in the programme spec requires.
- **This closes off one framing of the open question in the programme-design spec** ("run diagnostic A before committing to B?"): diagnostic A now has a real, measured answer, and it is positive enough that committing straight to the expensive LLM-labelling architecture (B) without first trying to extend A (more moderator-label training with an `easy_negative`-aware objective) would be premature.
