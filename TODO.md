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

## Track 1 — Incivility (start now, it works)

**Status: validated, ready to run.** `#toxicity` separates `rude` from random at **0.946**.

- [ ] Measure throughput of `unitary/unbiased-toxic-roberta` on the Mac mini (batched, MPS)
      over a few thousand posts before committing to a full pass.
- [ ] Score the corpus (2.2M replies). Store as an `Annotation` with a distinct `stage`
      so it never gets confused with a hate label.
- [ ] Weekly incivility rate per outlet, over time. This is publishable on its own.
- [ ] Report incivility and hate **separately, and show whether they dissociate.**
      "Replies got ruder but hate stayed flat" is a finding. So is the opposite.

**Do not present incivility as a hate proxy.** The 0.198 result forbids it.

---

## Track 2 — Hate (one cheap experiment before deciding)

**Status: no working detector. One obvious approach untested.**

Every model benchmarked so far is *lexical* — it scores surface features. Nothing has yet
been asked to apply the moderator's actual definition as a semantic judgement.

- [ ] **Benchmark an LLM with a definition-grounded prompt** on the same 235 vs 872 set.
      Cheap: ~1,100 posts is cents via a cloud model, or a few hours locally.
      **`ollama list` is currently empty — no local models are pulled**, despite
      `ModelConfig` presets referencing Gemma/Qwen.
  - If it reaches ≥0.75 vs `rude`: a hate pipeline exists. Proceed.
  - If it lands ~0.55 like everything else: the distinction is not recoverable from text at
    this label quality, and human annotation becomes mandatory rather than preferable.
    **That is a real result, not a failure.**
- [ ] If promising, consider fine-tuning an encoder on hate-vs-rude using these labels.
      235 positives is small for training but the task is narrow.

---

## Track 3 — Counter-speech (human annotation only)

**Status: blocked on annotation. No shortcut exists.**

Moderators label violations, not virtues. There is **no counter-speech label** anywhere in
Bluesky's vocabulary. The full sweep of 1,382,554 replies produced zero.

- [ ] Define counter-speech operationally, with examples and boundary cases.
- [ ] Stratified sample for annotation; two annotators; report Cohen's κ.
- [ ] Budget for this now — it is the long pole in the project.

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
| Corpus | 2.2M posts / 177k roots / 262k reply authors | growing ~200k posts/day |
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
- [ ] **Run `blueX-authors --backfill`.** `ZREPLYAUTHOR` is still 0. Needs the scrape
      stopped briefly to install the rebuilt CLI. Populates current handles and unblocks
      the status panel.
- [ ] **Re-run spiegel + tagesschau** — both were truncated by the old 20-hour re-auth
      ceiling, which is now fixed.
- [ ] **zeit.de is starved** at 2,997 roots vs theguardian's 56,472. Random rotation stopped
      it being permanently last but has not yet given it an early slot in two passes. If it
      misses another, switch to deterministic round-robin.
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
