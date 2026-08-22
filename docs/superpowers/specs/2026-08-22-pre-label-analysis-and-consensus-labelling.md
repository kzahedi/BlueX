# What we can measure before any labels, and how consensus fits into labelling

**Date:** 2026-08-22
**Status:** design for discussion; labelling starts Monday 2026-08-24
**Context:** Bluesky corpus 2,466,165 replies / 273,315 trees (complete to each
outlet's first post). Telegram corpus 285,294 messages, 14/33 channels backfilled,
spanning 2018-06 → 2026-08. Zero human labels so far.

## 0. The rule that governs everything here

Stage 0 is a **uniform random** sample, and its value comes entirely from being
unbiased. Therefore:

- No analysis in this document may change **which** posts are drawn for Stage 0.
  Uniform random sampling is unaffected by anything computed below, so all of it
  is safe — but any *future* filtered sampling must record its frame.
- No model output may reach the annotation view. The labelling data path is
  structurally blind (`LabellingContext` has no score fields) and must stay so.
- Everything below is descriptive or unsupervised. Nothing here produces "labels"
  that could later be mistaken for ground truth.

## 1. Signals already measured (today, SQL only)

These are not proposals; they are results, obtained in minutes.

### Bluesky: participation is extremely concentrated
- 273,066 distinct reply authors, **median 2 replies**, maximum **18,711** replies
  by a single account.
- **The top 1% of authors produce 35.9% of all replies.**
- Thread sizes: 2,800 threads (1% of threads) with 100+ replies hold 460,208
  replies (21% of the corpus); 39,978 threads have exactly one reply.

Why it matters: if incivility or hate is concentrated in prolific accounts, then
*author-level* modelling is far more powerful than post-level — which is precisely
the structure the 2020 Reconquista work exploited (membership as supervision). We
can test that concentration hypothesis with the incivility scores we already have,
before any hate labels exist.

### Telegram: the milieu splits into producers and amplifiers
Share of a channel's messages that are forwards from elsewhere:

| Channel | Messages | Forwarded share | Role |
|---|---|---|---|
| auf1tv | 19,575 | 0.7% | producer |
| epochtimesde | 19,555 | 0.4% | producer |
| CompactMagazin | 42,810 | 8.6% | producer |
| DerDritteWeg | 9,170 | 8.4% | producer |
| EvaHermanOffiziell | 97,244 | 21.0% | mixed, and the network's biggest hub |
| dierechteinfo | 3,443 | 43.8% | amplifier |
| AllesAusserMainstream | 45,780 | 52.5% | amplifier |
| ReinerFuellmich | 15,105 | 72.3% | amplifier |

Most-forwarded-from sources: `EvaHermanOffiziell` (17,977 forwards from 7 tracked
channels), `rosenbusch` (1,616), `COMPACTMagazinTV` (1,429), `icic_law_news`
(1,053), `uncut_news` (900), `freiesachsen` (884 from 11 distinct channels — the
widest reach). 209 candidate channels already cross the snowball threshold.

Why it matters: producer/amplifier is a structural role assignment derived purely
from forward metadata — no text classification, no labels. It gives us a defensible
way to talk about influence and to sample "originating" vs "amplifying" content
separately.

## 2. Analyses runnable now, in priority order

Priority is by (evidential value) ÷ (cost), and by whether the result stands
without any labels.

### P1 — Incivility × structure on Bluesky (days of work, no new data)
The 2,085,088 already-scored replies plus corpus structure answer questions that
need no hate labels:
1. **Is incivility concentrated in accounts?** Author-level mean/max incivility vs
   reply volume; Gini of incivility mass across authors. Decides whether
   author-level detection is the right unit.
2. **Escalation dynamics.** Conditional probability that a reply is uncivil given
   its parent is uncivil, vs base rate; by depth. This is the mechanism question
   from *Impact and dynamics of hate and counter speech* — and it is answerable
   with incivility alone.
3. **Does incivility predict moderation?** We hold 1,734 active post labels and 63
   actioned accounts. Survival/latency analysis: time from post to label, and what
   fraction of the highest-incivility decile ever got labelled. This measures
   *Bluesky's* moderation coverage, which is a finding in its own right, and gives
   a weak-supervision signal.
4. **Deletion as signal.** We measured −1.08% reply erosion over two months, biased
   toward extreme content. Re-scraping a fixed cohort and comparing incivility of
   *deleted* vs *surviving* replies estimates what moderation removes — a proxy for
   severity that needs no annotation.

### P2 — Keyword and distinctive-language extraction (cheap, immediately useful)
5. **Log-odds ratio with informative Dirichlet prior** (Monroe et al.) for
   outlet-vs-outlet and period-vs-period vocabulary. This is the correct method for
   "which words distinguish these groups" — plain TF-IDF over-rewards rare terms.
6. **Marker-term time series.** Track dogwhistle/marker vocabulary per week per
   outlet (same instrument Zeitgeist uses for adoption lag). Interpretable, robust,
   and directly comparable across the two projects.
7. **Near-duplicate detection on Telegram** (MinHash/SimHash): copypasta and
   near-simultaneous identical posting across channels is the standard signature of
   coordinated amplification. Needs no labels and is hard to argue with.

### P3 — Topic modelling (moderate cost, interpretation-heavy)
8. **BERTopic on Telegram German text first**, not Bluesky. Reason: Bluesky replies
   are 82% English / 14% German and extremely short (reply register), which makes
   topics muddy; the Telegram corpus is long-form, single-language, and thematically
   coherent, so topics will be sharper and validate the pipeline before we spend
   4.5 GPU-free hours on 2.4M short replies.
9. If Bluesky topics are wanted: cluster within language, and cluster *threads*
   rather than individual replies (a thread has enough text to be a document).

### P4 — Network analysis on Telegram (high value, low cost)
10. **Forward graph**: 2,002 source channels, 27,757 edges already. Communities
    (Louvain), centrality, and the producer/amplifier split above. This is
    publishable descriptive work today, and it grows as the backfill completes.
11. **Cross-corpus propagation**: do URLs/domains shared in Telegram appear in
    Bluesky replies, and with what lag? A URL join is exact, cheap, and directly
    addresses the propagation question — no classifier needed.

### What NOT to do yet
- Any supervised hate/counter-speech model. The base rate is unknown; this is the
  measured constraint the whole programme rests on.
- Any "quick LLM pass to see what's in there" whose outputs get stored next to
  human labels. Automatic labels are fine as *data*, never as truth, and they need
  their own recorded provenance (§3.4).

## 3. Consensus in the labelling process

The earlier design put a consensus committee in the *classifier*. The question now
is how consensus fits the *labelling*, starting Monday.

### 3.1 Stage 0 stays purely human, and blind
Monday's session must be exactly what it is: uniform random draws, human judgment,
no model output visible. Any model assistance here would bias the one unbiased
number the project has. Non-negotiable.

### 3.2 Pre-registered model predictions (free rigour)
Before the session, run the available models (incivility encoder, TF-IDF, later
doc2vec, optionally a local LLM) over the Stage 0 batch and **store the predictions
sealed** — written to a separate table/file the labelling UI cannot read. After
labelling, compare. This yields:
- an unbiased estimate of each model's accuracy on the deployment distribution,
- inter-model agreement statistics on a random (not curated) sample,
- and it costs nothing but disk, because the labels are collected anyway.

Pre-registration matters: predictions made *after* seeing labels are worthless as
evidence, and the temptation to "check what the model said" during annotation is
exactly what the blind data path prevents.

### 3.3 Consensus-directed sampling from Stage 1 onward
Once the base rate exists, the committee earns its keep by *directing* effort:
- **High-disagreement (spread) items**: maximally informative per label.
- **Unanimous-positive items**: measure precision where correlated error hides —
  all current members share the incivility-vs-hate construct bias (the measured
  0.198 dissociation), so unanimity can be confidently wrong in one direction.
- **Unanimous-negative items**: bound the false-negative rate; without this,
  "the committee found nothing" is unfalsifiable.

Each of these is a distinct `SamplingFrame` kind, recorded per label, so no later
analysis can mistake a disagreement-drawn label for a random one.

### 3.4 Adjudication rules, agreed in advance
- Where the committee unanimously contradicts the human label, that item goes into
  a **review queue** — sometimes the annotator slipped, sometimes the models found
  something. Resolution is recorded with a reason, and the human label remains
  authoritative unless the annotator themselves changes it.
- Committee-drawn labels are spent on **validation and calibration**, not training.
  If they are ever used for training, that conversion is recorded explicitly and
  they leave the evaluation set permanently.
- Automatic (LLM/committee) labels live in their own table with model id, revision,
  prompt hash, and timestamp — never in the human annotation table.

### 3.5 A second annotator, if one ever becomes available
With one annotator we can only report intra-rater agreement (blind re-label after
an interval), which is weaker than Cohen's κ and must be described as such. If a
second annotator appears later, the design already supports it: `Annotation` carries
`annotatorID`, so κ becomes computable retroactively on overlapping items. Worth
drawing a small overlap set from the start — say 10% of Stage 0 re-served blind —
so that option stays open at negligible cost.

## 4. Recommended order for next week

1. **Monday:** Stage 0 labelling session (~300 labels), pre-registered model
   predictions sealed beforehand.
2. **Immediately after:** `tools/labelling/base_rate.py` → Wilson CI base rate,
   plus the model-vs-human comparison from §3.2. This decides the detector design.
3. **In parallel, independent of labels:** P1 items 1–3 (incivility × structure ×
   moderation) and P4 item 10 (forward network). Both produce standalone results.
4. **Then:** Phase D detector plan, written against a measured base rate rather
   than an assumed one.
