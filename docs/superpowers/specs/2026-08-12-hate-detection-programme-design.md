# Hate detection programme — design in progress (2026-08-12)

**STATUS: NOT APPROVED. Decisions below are settled; the architecture is not.**
The final open question — whether to run the cheap supervised diagnostic before committing
to an LLM-labelling architecture — is still with the user. Do not implement from this
document yet.

---

## The constraint that shapes everything

Measured 2026-08-11 (`tools/benchmark/`, and
`docs/superpowers/notes/2026-08-11-nltagger-sentiment-does-not-detect-hate.md`):

**No off-the-shelf model separates moderator-labelled hate from moderator-labelled
rudeness.** Best attempt: 0.533 AUC. Several are *inverted* — a generic toxicity head
rates a `rude` post as more toxic than a hate post **80% of the time** (AUC 0.198).

| Detector head | hate vs random | **hate vs `rude`** | rude vs random |
|---|---|---|---|
| `unbiased-toxic-roberta#identity_attack` | 0.901 | 0.518 | 0.919 |
| `unbiased-toxic-roberta#toxicity` | 0.846 | **0.198** | **0.946** |
| `textdetox#toxic` | 0.829 | **0.188** | 0.944 |
| `twitter-roberta-base-hate#hate` | 0.814 | 0.533 | — |
| keyword lexicon (baseline) | 0.511 | 0.508 | — |
| Apple NLTagger sentiment | 0.523 | 0.460 | — |

Toxicity models detect profanity, insult and obscenity. `intolerant` — Bluesky's label for
"discrimination against protected groups" — is frequently expressed in clean language.
They are measuring a different construct, accurately.

**Therefore: no existing tool can be adopted. Something must be trained or prompted.**

---

## Decisions taken

| Decision | Choice | Rationale |
|---|---|---|
| Deliverable | **Every post classified** (not sample-based prevalence) | User's choice. Needed for per-author statistics across 267k authors and full-corpus event windows. |
| Scope of this design | **Hate only** | Counter-speech deferred — see below. |
| Human annotation capacity | **A few hundred, user only** | Sufficient to *validate*, insufficient to *train*. |
| Role of human labels | **Held-out gold set**, never training data | With only a few hundred, spending them on training would leave nothing to validate against. |
| Full-corpus inference | **Encoder-class model only** | LLM inference over 2.4M posts is ~66 days locally at Gemma's 2.4s/post. The incivility encoder does 145 posts/sec — 2.4M in ~4.5h. |
| Counter-speech | **Deferred to its own design** | User: *"most likely a mixture of specific counter speech accounts and their replies to hate. we need to first identify hate, which is usually easier, then decide how to classify counter later."* |

### Consequence to state plainly, not paper over

**With a single annotator there is no inter-rater reliability.** Cohen's κ requires two or
more. Any write-up must either omit κ, report intra-rater agreement from a re-annotated
subset (weaker, but honest), or recruit a second annotator for a portion. This is a real
methodological limitation, not a formality.

---

## Counter-speech — why it is deferred, and the promising direction

Counter-speech is **relational**: it responds *to* hateful content. "That's disgusting,
delete this" is counter-speech under a hateful parent and something else under a news
headline. Hate can be judged from a post alone; counter-speech generally cannot.

There are also **zero external labels**. The complete sweep of 1,382,554 replies produced
no counter-speech label of any kind — moderators label violations, not virtues.

The user's proposed direction, recorded for the later design: identify **accounts that
habitually engage in counter-speech**, then examine their replies to hate. This is far more
tractable than classifying 2.4M replies for a relational property, and it can reuse the
reply-author subsystem already built. It also gives a natural denominator: *of threads
containing hate, how many drew a response from a known counter-speaker?*

Prerequisite: hate must be identified first. Hence the ordering.

---

## Candidate architectures (undecided)

### A — Supervised fine-tune on the existing moderator labels

Fine-tune a small encoder directly on the 1,124 labels already held (241 hate, 883 `rude`)
— i.e. train on exactly the distinction that matters, rather than borrowing a model trained
for toxicity.

- **Cost:** minutes. Nearly free.
- **Risk:** 241 positives is very few; may simply overfit.
- **Why it is worth doing first:** it is *diagnostic*. If a model trained directly on
  hate-vs-rude still cannot beat chance, the distinction is not learnable from text at this
  label quality — and **no amount of LLM labelling would fix that.** If it works, the LLM
  stage may be unnecessary entirely.

### B — LLM as labeller, encoder as workhorse

Prompt an LLM with the moderator's definition, label 20–50k stratified posts, fine-tune an
encoder on those silver labels, let the encoder score all 2.4M.

- **Cost:** moderate. Sample labelling is affordable; encoder inference is ~4.5h.
- **Risk:** inherits the LLM's errors wholesale; unvalidated until measured against gold.
- **Untested premise:** nothing has yet asked an LLM to apply the definition semantically.
  Every model benchmarked so far is lexical.

### C — Combined: moderator labels as anchors, LLM labels for volume

Weight the 1,124 human-moderator labels above LLM silver labels in training.

**Recommendation: run A first as a diagnostic, then B if A is insufficient.** An afternoon's
work, and either outcome redirects the programme.

---

## Validation design (applies to any architecture)

- The user's few-hundred annotations are **held out** and never trained on.
- Report **hate vs `rude`** as the headline metric, with hate-vs-random secondary. Reporting
  only the latter is how a rudeness detector gets mistaken for a hate detector — the
  measured trap above.
- Report **per-language** (en / de). The corpus is ~82% en / ~14% de, and the German cells
  in the current benchmark hold only 19 positives — too few to conclude anything. Three of
  five outlets are German, so this gap needs closing before any German claim.
- **Moderator labels are a precision test, not a recall test.** They capture what was
  reported and actioned. A model scoring badly against them may be flagging real hate nobody
  reported. State this in any write-up.

---

## Open questions

- **Sequencing** — run diagnostic A before committing to B? (with the user)
- **Which LLM** for approach B. `/Volumes/Eregion/ollama` holds 57 GB of local models
  (`ollama list` returned empty earlier — a daemon or path issue, not an absence).
  Bedrock is the org's stated direction; `ModelConfig` also has Cerebras free-tier presets.
- **German label scarcity.** 19 German positives is not a test. Options: targeted labelling
  of German content, or accepting an English-only claim initially.
- **Whether severity is in scope.** The `Annotation` model already has a `severity` field
  (`mild`/`moderate`/`severe`), unused. Adding it multiplies annotation cost.
