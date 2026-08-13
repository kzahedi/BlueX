# BlueX — where things stand and what to do next

Last updated 2026-08-11. Every number here is measured, with the source named. Where
something is an estimate or an assumption, it says so.

---

## The finding that reframes the project

**Off-the-shelf toxicity models detect incivility, not hate — and the two dissociate.**

Measured on the moderator-labelled benchmark (`tools/benchmark/`, eval set of 235
`intolerant`/`threat` positives, 872 `rude` hard negatives, 940 random controls):

| Detector head | hate vs random | hate vs **rude** | **rude vs random** |
|---|---|---|---|
| `unbiased-toxic-roberta#toxicity` | 0.846 | **0.198** | **0.946** |
| `unbiased-toxic-roberta#identity_attack` | 0.901 | 0.518 | 0.919 |
| `textdetox#toxic` | 0.829 | **0.188** | 0.944 |
| `twitter-roberta-base-hate#hate` | 0.814 | 0.533 | — |
| lexicon baseline | 0.511 | 0.508 | — |
| Apple NLTagger sentiment | 0.523 | 0.460 | — |

Read the middle column carefully. **AUC 0.198 means the model rates a moderator-labelled
*rude* post as more toxic than a moderator-labelled *hate* post 80% of the time.** That is
a strong, consistent anti-correlation across every generic toxicity head.

Why: toxicity models score profanity, insult and obscenity. `intolerant` — Bluesky's label
for "discrimination against protected groups" — is often expressed in clean language.
Compare the NLTagger caveat from the 2026-08-04 spec: *"Man kann den Israelis nur empfehlen,
auszuwandern"* scored **+1.0** sentiment. No rude words, hateful content.

**Methodological note worth keeping.** Without the `rude` hard-negative class we would have
seen `identity_attack` at 0.901 against random text, called it excellent, and shipped a
rudeness detector believing it detected hate. The hard negative is what made the difference
visible. Any future detector claim must be tested against `rude`, not against random text.

---

## Track 1 — Incivility (DONE for scoring; aggregation next)

**Status: corpus scored.** `#toxicity` separates `rude` from random at **0.946**.

**Completed run** (`/Volumes/Eregion/bluex-incivility/`, summary
`incivility-scores-2026-08-11T153517Z.summary.json`):

| | |
|---|---|
| Posts scored | **2,085,088** |
| Failed batches / posts | **0 / 0** |
| `run_status` | **complete** |
| Throughput | 145.8 posts/sec on MPS |
| Heads recorded | `toxicity` and `identity_attack` |
| Cooling | 445s over 89 duty-cycle triggers |
| Thermal escalations | **0 serious, 0 critical** — machine never left `nominal` |

The duty cycle (5s per 60s) alone was sufficient; the `ThermalBackoff` ladder never fired.
Future passes need not be more conservative.

- [x] Measure throughput before committing to a full pass — 124/sec sampled, 145.8/sec actual
- [x] Score the corpus — complete, JSONL only (deliberately **not** written into
      `Annotation`, whose `speechClass` field would invite hate/incivility confusion)
- [ ] **Aggregate: weekly incivility rate per outlet over time.** This is the first real
      research output the corpus can produce. Use the `AggregateReader` SQL pattern.
- [ ] Decide whether/how to ingest scores into the store for the dashboard to read.
- [ ] Weekly incivility rate per outlet, over time. This is publishable on its own.
- [ ] Report incivility and hate **separately, and show whether they dissociate.**
      "Replies got ruder but hate stayed flat" is a finding. So is the opposite.

**Do not present incivility as a hate proxy.** The 0.198 result forbids it.

---

## Track 2 — Hate (design in progress)

**Design doc: `docs/superpowers/specs/2026-08-12-hate-detection-programme-design.md`**
(NOT yet approved — architecture undecided.)

**Decisions taken:** every post must be classified (not sample-based); human annotation
capacity is a few hundred, user only, so those labels are **held-out gold, never training
data**; full-corpus inference must be encoder-class (LLM over 2.4M ≈ 66 days locally).

**Consequence to state, not paper over:** with a single annotator there is **no inter-rater
reliability** — Cohen's κ is unavailable. Options: omit it, report intra-rater agreement
from a re-annotated subset, or recruit a second annotator for a portion.

Two cheap diagnostics, either of which redirects the programme:

- [ ] **A — fine-tune a small encoder directly on the 1,124 existing moderator labels**
      (241 hate, 883 `rude`). Minutes of work. This is *diagnostic*: if a model trained on
      exactly the right distinction still cannot beat chance, the distinction is not
      learnable from text at this label quality and **no amount of LLM labelling fixes
      that**. If it works, the LLM stage may be unnecessary. **Recommended first.**
- [ ] **B — LLM with a definition-grounded prompt**, benchmarked on the same 235 vs 872 set.
      Every model tested so far is *lexical*; nothing has yet applied the definition
      semantically. `/Volumes/Eregion/ollama` holds **57 GB of models** — the earlier empty
      `ollama list` was a daemon/path issue, not an absence.
- [ ] If B works, distil: LLM labels 20–50k stratified posts → fine-tune encoder → encoder
      scores all 2.4M (~4.5h at the measured 145 posts/sec).

**Report hate-vs-`rude` as the headline metric**, hate-vs-random secondary. Reporting only
the latter is exactly how a rudeness detector gets mistaken for a hate detector.

**German label scarcity blocks any German claim:** only 19 German positives in the benchmark.
Three of five outlets are German. Needs targeted labelling or an explicit English-only scope.

---

## Track 3 — Counter-speech (deferred by decision, until hate is identified)

**Status: deliberately deferred. Direction chosen; design comes later.**

Moderators label violations, not virtues. There is **no counter-speech label** anywhere in
Bluesky's vocabulary — the full sweep of 1,382,554 replies produced zero.

It is also **relational**: it responds *to* hateful content. "That's disgusting, delete this"
is counter-speech under a hateful parent and something else under a news headline. Hate can
be judged from a post alone; counter-speech generally cannot.

**User's chosen direction** (2026-08-12): *"most likely a mixture of specific counter speech
accounts and their replies to hate. we need to first identify hate, which is usually easier,
then decide how to classify counter later."*

That is far more tractable than classifying 2.4M replies for a relational property, and it
reuses the reply-author subsystem. It also yields a natural denominator: *of threads
containing hate, how many drew a response from a known counter-speaker?*

- [ ] Blocked on Track 2 producing usable hate labels.
- [ ] Then: identify habitual counter-speaking accounts, and examine their replies to hate.

---

## Track 4 — Disinformation (effectively unlabelled)

The complete post sweep found **3** relevant labels in 1.38M replies: `misleading` 2,
`rumor` 1. There is no external signal to validate against. Same conclusion as
counter-speech: human annotation from scratch, or drop the third research target.

- [ ] Decide explicitly whether disinformation stays in scope. It currently has no data path.

---

## Data assets (all measured)

| Asset | Size | Notes |
|---|---|---|
| Corpus | **2.38M posts / 253k roots / 267k reply authors** | growing; see coverage note below |
| Reply-tree completeness | 253,166 complete, 2 in progress, **0 orphan replies** | `docs/superpowers/notes/2026-08-12-corpus-completeness-and-coverage.md` |
| Incivility scores | **2,085,088 replies**, 2 heads each | complete run, 0 failures |
| Post moderation labels | 1,754 posts labelled, of 1,382,554 swept | complete sweep, 0 failed batches |
| — hate-relevant | **241** (`intolerant` 179, `threat` 61, `extremist`/`intolerant-race`) | the benchmark positives |
| — `rude` | 883 | the hard negatives, and Track 1's target |
| — `spam` | 383 | |
| Account moderation labels | 14,571 of 205,391 (7.09%) | `!takedown` 1,777, `!suspend` 4,946 |
| Deleted replies (archive diff) | 10,067 | candidate mining for removed content |
| Sentiment | none — `ZANNOTATION` is empty | and NLTagger is useless for hate (AUC 0.508) |

---

## Operational debt (unglamorous, and one item is load-bearing)

- [ ] **Index re-assertion wiring — do this one.** Five hand-built indexes now carry the
      app's performance (`ZROOTURI`, `ZURI`, `ZAUTHORDID`, the covering index, plus Core
      Data's own). A lightweight migration **silently drops** hand-made indexes — measured
      2026-08-07, with `PRAGMA quick_check` still reporting `ok`. The next model change
      returns the dashboard to 27-second queries and nothing will report it.
      Design decided (`docs/superpowers/specs/2026-08-07-bluex-authors-dashboard-design.md`):
      re-assert `CREATE INDEX IF NOT EXISTS` on every store open. **Unresolved:** a
      read-only consumer never opens a write connection, so it would never re-assert.
- [x] **Author backfill — DONE 2026-08-13.** 267,496 authors created in **24 seconds**
      (the original SwiftData implementation ran 2h44m and wrote zero rows before being
      killed). `quick_check` ok, posts unchanged. Re-runnable and idempotent, so it can be
      re-run cheaply as the corpus grows.
- [x] **spiegel + tagesschau truncation — RESOLVED.** The re-auth fix held: the pass ending
      2026-08-13 completed cleanly (`Done · 81,689 new posts · 125,782 replies · 24h 23m`),
      the first full pass rather than an interrupted one. Zero re-auth failures across every
      pass since the fix.
- [x] **zeit.de starvation — FIXED.** 2,997 → **39,387 roots** in one pass after the rotation
      change, and it drew the *lead* slot on 2026-08-13. Random rotation is working; the
      deterministic round-robin fallback is no longer needed unless it regresses.
- [x] **Scrape floor lowered to 2023-01-01** (`21c2203`, applied to the live store
      2026-08-13). Oldest root already back to 2023-12-25 and walking further. Costs zero
      extra API calls — `FeedScraper` was already walking full history and discarding.
- [ ] Author profile probe (plan Tasks 2/3/4/6/7b) — enforcement latency, account age,
      handle-change history. Note `getProfiles` does **not** return moderation labels; the
      labeler endpoint does.
- [ ] Known flaky test: `BlueskyAPIClientTests.testCreateSessionRateLimited`, order-dependent
      via the shared `URLSession` from `8685b59`.

---

## Standing methodological rules earned the hard way

1. **Test against a hard negative, not against random text.** Four detectors looked strong
   against random and were useless against `rude`.
2. **A test nobody has watched fail is not evidence.** Four tests in this project passed
   while structurally incapable of detecting the bug they guarded. Break the implementation
   deliberately and confirm the test fails before believing it.
3. **"Tests pass" and "the product builds" are different claims.** The CLI targets enumerate
   sources explicitly while app/test targets glob directories; a green suite once shipped an
   uncompilable binary.
4. **Measure before optimising and after.** The dashboard went 27.8s → 0.16s from one
   covering index; the "obvious" fix (removing a join) was worth only 27.8s → 5.2s.
5. **Moderator labels are a precision test, not a recall test.** They capture what was
   reported and actioned. A model scoring badly may be catching real hate nobody reported.
