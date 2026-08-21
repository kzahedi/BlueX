# BlueX — where things stand and what to do next

Last updated 2026-08-11. Every number here is measured, with the source named. Where
something is an estimate or an assumption, it says so.

---

## NEXT UP — ordered, with reasons

Agreed 2026-08-13. Work top-down; each item states why it sits where it does.

**1. Index re-assertion wiring** — *in progress*
Five hand-built indexes carry the app's performance and a lightweight migration drops them
**silently**, with `PRAGMA quick_check` still reporting `ok` (measured 2026-08-07). The next
model change reverts the dashboard to 27-second queries with nothing reporting it. First
because it is small, and because the failure it prevents is one nobody would diagnose
quickly. Design in `docs/superpowers/specs/2026-08-07-bluex-authors-dashboard-design.md`;
the read-only-consumer hole is resolved below.

**2. Hate diagnostic — fine-tune on the 1,124 existing moderator labels**
An afternoon. Answers whether hate-vs-`rude` is learnable *at all* before committing to
either an LLM pipeline or hundreds of hours of annotation. **Deliberately before the
labelling tab:** if it succeeds, the tab's purpose changes from bootstrapping-from-nothing
to validating-a-working-model, which changes what should be built. Both outcomes are useful
results.

**3. Manual labelling tab**
Spec written (`docs/superpowers/specs/2026-08-13-manual-labelling-tab-design.md`), awaiting
review. Shape may change based on item 2.

**4. Incivility aggregation — weekly rate per outlet over time**
The scores exist (2,085,088 replies). This is the **first genuine research output** the
corpus can produce, and it is mostly SQL following the existing `AggregateReader` patterns.
Lower than 2 only because it is unblocked and will keep.

**Then, unscheduled:** author profile probe (enforcement latency, account age, handle-change
history — unblocked now the backfill has run); a scope decision on disinformation (3 labels
in 1.38M replies means there is no data path); the known flaky test.

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
| Account moderation labels | **CORRECTED 2026-08-14:** only **63** accounts carry an *active* `!takedown`/`!suspend` | earlier "6,723 (3.27%)" counted **negated** (retracted) labels as active — a 100× error. Active: `!suspend` 43, `!takedown` 20. Actioned accounts hold just 463 replies, killing account-level distant supervision. |
| Deleted replies (archive diff) | 10,067 | candidate mining for removed content |
| Sentiment | none — `ZANNOTATION` is empty | and NLTagger is useless for hate (AUC 0.508) |

---

## Operational debt (unglamorous, and one item is load-bearing)

- [ ] **Watchdog: alert on "successful passes collecting nothing."** The Aug 13–19
      incident: a stale-resume-cursor bug made every feed pass resume deep in 2023,
      collect zero new roots, and report "complete" — for six days, across two different
      scheduling regimes. The watchdog alerted on *failed runs* (the TCC issue) but had no
      check for *successful runs with implausible output*. Add: if N consecutive passes
      store zero new root posts across all outlets, alert — the outlets demonstrably post
      daily, so an all-zero streak is a scraper defect until proven otherwise.
      "Done · 0 new posts" must never again be readable as "caught up" without evidence.
      (Root cause fixed in e399380; this item is the missing detection layer.)

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
- [ ] **Nightly BlueX store backup to the NAS — near-term, load-bearing.** The corpus
      (2.46M posts) is irreplaceable — deleted replies can't be re-scraped; archival is
      the point of the project — and currently has **zero backup**. Add a nightly launchd
      job copying a consistent snapshot of `default.store` (`sqlite3 .backup` or
      `VACUUM INTO`, never a raw file copy of a live WAL store) plus the incivility score
      files and `social/telegram.db` to the NAS. Decided 2026-08-21 with the NAS-storage
      split: live stores stay on Eregion (SQLite never lives on a network share); the
      NAS holds shared corpora (zeitgeist PostgreSQL) and backups.
- [ ] **Telegram → NAS PostgreSQL export (later option, not now).** If cross-project
      queries ever need Telegram messages next to the zeitgeist speech/headline corpora,
      add an export job (local `telegram.db` → NAS Postgres). Deliberately an export, not
      direct writes: the always-on collector must not depend on the NAS being reachable,
      and its live SQLite stays local. Do only when an actual cross-corpus query needs it.
- [x] **VPN ↔ Bluesky 5xx interaction — KNOWN AND ACCEPTED (2026-08-21).** Since
      ProtonVPN runs permanently (hard rule: Telegram must never see the home IP), all
      traffic including Bluesky exits via the tunnel, and Bluesky's infrastructure
      intermittently returns 502/504 to VPN exit IPs. Measured: zero HTTP-5xx scrape
      errors in the twelve passes from 01:38–13:46 on 2026-08-21, then exactly one per
      pass once the VPN was up. Effect: one outlet fails per affected pass, exit 1, and
      its posts arrive on the next pass ~1.5h later — no data loss against a
      complete-history corpus. Split tunnelling is NOT available (this ProtonVPN version
      only selects `/Applications` bundles; both scrapers are CLI binaries). **User
      decision: leave as is — do not "fix" failed passes with this signature, and do not
      add retry logic without asking.** A pass failing with only
      `scrape error: Network error: HTTP 5xx` is expected background noise, not a defect.

- [ ] **Telegram job state lives on the external volume — revisit if it ever detaches.**
      `telegram-heartbeat.json` and `telegram-skip-streak.log` sit in
      `/Volumes/Eregion/bluex-data/social/`, diverging from the proven pattern of keeping
      control-plane state on the internal disk (the Bluesky agent's heartbeat does). Current
      behaviour fails *closed* — if the volume is gone the heartbeat file is missing, and the
      watchdog treats "missing heartbeat + plist installed" as STALE and alarms — so this is
      a tidiness/robustness item, not a hole. Move both to `~/Library/Application Support/BlueX/`
      if the volume is ever detached for long stretches. (Flagged 2026-08-21 by the
      watchdog-integration implementer; placement was my instruction, matching where Task 6
      put the heartbeat.)

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
