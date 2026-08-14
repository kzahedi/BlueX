# Labelling and classification — full concept (2026-08-14)

How BlueX gets from 2.42M unlabelled replies to defensible hate/counter-speech measurements.
Covers every label source and model class on the table: moderator labels, automatic
labelling, human annotation, locally fine-tuned models, pre-trained local models, and
free-to-use APIs.

**Status: concept for discussion. Not approved, not a plan.**

---

## 1. The problem this must solve

Everything here is shaped by one measured result
(`docs/superpowers/notes/2026-08-13-hate-vs-rude-finetune-diagnostic.md`):

| Task | Best CV AUC |
|---|---|
| hate vs `rude` (what we trained on) | **0.959 ± 0.014** |
| hate vs **random** (what deployment is) | **0.61–0.68** |

Training on hate-versus-rude teaches *"given that this is one of these two, which is it?"*
Deployment asks *"is this hate?"* of 2.42M replies that are overwhelmingly **neither**. The
model has never seen the majority class.

**This is a distribution mismatch, not a model-quality problem.** Every proposal below is
judged primarily by whether it closes it.

### Two workarounds that are already ruled out by measurement

**Incivility as a pre-filter — no.** Hate and toxicity are *anti*-correlated on this corpus
(hate-vs-rude AUC **0.198** for generic toxicity heads). Filtering by incivility would
systematically discard the cleanly-worded hate that matters most. This is the single most
counter-intuitive fact in the project and the easiest to forget.

**Keyword lexicon as a pre-filter — no.** 0.508, indistinguishable from chance.

### One result that constrains ambition

**TF-IDF + logistic regression reached 0.943 ± 0.019** against the fine-tuned transformer's
0.959 ± 0.014 — overlapping error bars. On 1,107 examples, neural fine-tuning bought ~1.6
points over `sklearn` defaults. Any proposal claiming a transformer is *necessary* must beat
TF-IDF in the same harness, or justify itself on generalisation rather than headline AUC.

---

## 2. Label sources — what each is good for

| Source | Volume available | Cost | Distribution | Honest role |
|---|---|---|---|---|
| **Bluesky moderator labels** | 241 hate, 883 `rude`, 383 spam | free, already collected | *not* random — what was reported and actioned | Precision test; training anchors |
| **Automatic (LLM) labelling** | unlimited in principle | cents–hours | **any distribution we choose** | Volume, and the only affordable source of deployment-distribution negatives |
| **Human annotation** | a few hundred, one annotator | very scarce | our choice | Held-out gold. Never training data. |
| **Account-level labels** | 14,571 accounts (1,777 `!takedown`, 4,946 `!suspend`) | free | biased toward prolific accounts | Weak signal; **must not** be propagated to individual posts |
| **Deleted-reply set** | 10,067 | free | selected for removal | Candidate mining; ~70% of their authors are still active, so most are self-deletions |

### The key realisation

**LLM labelling is back on the table, for a different reason than before.** It was originally
proposed because the hate/rude distinction seemed unlearnable. That turned out false. Its
actual value is now clearer and narrower: it is **the only affordable way to obtain labelled
negatives from the true deployment distribution at volume** — thousands of ordinary replies,
labelled "not hate", which is exactly what the current models have never seen.

Human annotation cannot supply that (a few hundred labels, mostly negative, would be spent
almost entirely on confirming that ordinary posts are ordinary). Moderator labels cannot
supply it (they only exist where something was reported).

---

## 3. Model classes — what to use where

### 3a. Pre-trained local models, used as-is
**Verdict: only for incivility.** `unitary/unbiased-toxic-roberta#toxicity` separates `rude`
from random at **0.946** and has already scored the whole corpus (2,085,088 replies, complete,
zero failures). It is a validated incivility detector and **not** a hate detector.

### 3b. Locally fine-tuned encoders
**Verdict: the workhorse for full-corpus inference.** Measured 145 posts/sec — 2.42M replies
in ~4.5 hours, on hardware you own, repeatable at no marginal cost. This is the only model
class that can classify the entire corpus. The open question is not speed but whether it can
be trained on a deployment-matched distribution (see §4).

### 3c. Free-to-use API models
**Verdict: labelling engine and second opinion, never full-corpus.**
- **Perspective API** (Google Jigsaw) — free, purpose-built, returns `IDENTITY_ATTACK` and
  `THREAT` as distinct scores, supports German. ~1 QPS default: 2.42M posts is weeks, a
  20k sample is hours. Standard in this literature, which matters for publication.
- **OpenAI moderation endpoint** — free with a key, multilingual.
- **Cerebras free tier** — already configured in `ModelConfig`.
- Value: independent of anything we train, so genuine external validation rather than a
  second opinion from a correlated model.

### 3d. Cloud LLMs (Bedrock / local Ollama)
**Verdict: the labelling engine.** `/Volumes/Eregion/ollama` holds 57 GB of models already.
Bedrock is the org's stated direction. Full-corpus LLM inference is ~66 days locally and
uneconomic via API; sample labelling of 20–50k is affordable either way.

### 3e. TF-IDF + logistic regression
**Verdict: the baseline that every proposal must beat, and possibly the answer.** 0.943 on
the hard task. Trains in seconds, runs on anything, and is interpretable — you can read the
coefficients and see *which words* drive a decision, which no transformer offers. Do not
discard it because it is unfashionable.

---

## 4. The architecture this points to

**Stage 1 — build a deployment-matched training set.**
The current models fail because they never saw ordinary content. Fix that directly:
- Draw a **random** sample of replies (say 20–50k) — the true deployment distribution.
- Label it automatically (LLM and/or Perspective), giving mostly-negative labels at volume.
- Combine with the 241 moderator-labelled positives and 883 `rude` hard negatives, which
  supply the difficult boundary cases that a random sample would barely contain.

The resulting training set has both the right *base rate* and the right *hard cases*. Neither
source alone provides both.

**Stage 2 — train the workhorse.**
Fine-tune an encoder (and TF-IDF, in the same harness) on that set. Evaluate on **hate vs
random**, not hate vs rude — the deployment task. Report both, always.

**Stage 3 — validate against human gold.**
The few hundred human annotations, drawn from the same random distribution, held out and
never trained on. This is the only estimate of real-world performance that is not
contaminated by the LLM's own errors.

**Stage 4 — full-corpus inference.**
~4.5 hours on the Mac mini, as the incivility pass already demonstrated end to end.

### Why not a cascade (cheap filter → precise classifier)?
Considered and rejected for now: the obvious stage-1 filters are ruled out by measurement
(incivility is anti-correlated; lexicon is chance). A cascade built on a weak filter
(0.61–0.68) would discard real hate before the precise stage ever saw it, and the recall loss
would be invisible. Revisit only if a filter with measured high recall appears.

---

## 5. Human annotation — what the scarce resource is spent on

A few hundred labels, one annotator. Spend them where nothing else can substitute:

1. **A random-distribution gold set** (the majority). Validates real-world performance. No
   other source can provide this unbiased.
2. **LLM audit** — a subset where the LLM labelled, re-labelled by hand, to measure how good
   the automatic labels actually are. This is what licenses using LLM labels at all.
3. **Model failure probing** — cases the classifier is least certain about. Highest
   information per annotation, *once* a model exists.

**Do not** spend them re-labelling moderator-labelled posts; those already have a label.

**Cohen's κ is unavailable** with one annotator. The obtainable substitute is intra-rater
agreement: re-label a subset blind after a gap. Weaker, and must be described as such.

---

## 6. Counter-speech and disinformation

**Counter-speech** — deferred by decision, and the direction is chosen: identify accounts
that habitually counter-speak, then examine their replies to hate. It is relational (a reply
is counter-speech relative to what it answers), so it needs hate identified first. Zero
external labels exist.

**Disinformation** — the complete sweep of 1,382,554 replies produced **3** relevant labels
(`misleading` 2, `rumor` 1). There is no external signal and no data path. **A scope decision
is needed:** either commit to human annotation from scratch, or drop it from the research
questions. Carrying it as an unstated aspiration is the worst option.

---

## 7. Sequencing

1. **Automatic labelling of a random sample** (20–50k) — the missing ingredient. Compare LLM
   and Perspective on the same sample; they disagree in informative places.
2. **Retrain on the combined set**, evaluate on hate-vs-random. Include TF-IDF.
3. **Build the labelling tab** — revised for random-distribution sampling, not only filtered
   pools. Spec at `docs/superpowers/specs/2026-08-13-manual-labelling-tab-design.md` needs
   this amendment before implementation.
4. **Human gold set**, then honest performance numbers.
5. **Full-corpus inference** once, and only once, the numbers justify it.

Steps 1 and 3 can proceed in parallel; step 2 needs step 1.

---

## 8. What would make this fail, stated in advance

- **Trusting LLM labels without auditing them.** Step 5.2 exists for this. Without it the
  whole pipeline rests on an unmeasured assumption.
- **Evaluating on hate-vs-rude because the number is prettier.** 0.96 is the wrong task.
- **Forgetting that toxicity is anti-correlated with hate**, and reintroducing an incivility
  filter somewhere in the pipeline.
- **Treating moderator labels as ground truth for recall.** They record what was reported and
  actioned. A model scoring badly against them may be finding hate nobody reported.
- **Spending the scarce human labels on the wrong thing** — anything a cheaper source could
  have labelled.
