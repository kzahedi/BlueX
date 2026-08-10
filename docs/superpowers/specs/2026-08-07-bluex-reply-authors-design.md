# BlueX — Reply Authors and Moderation-Outcome Probing (2026-08-07)

Model the people who reply to tracked news accounts, and track what happens to them
over time. The goal is not a user directory: it is to make **platform moderation
outcomes measurable** — takedown rate, enforcement latency, and enforcement coverage —
and to give per-author behavioural statistics that the hate/counter/disinformation
analysis needs as covariates.

## Why now

A reply that disappears is not noise; it is a moderation event, and it is currently
invisible. Two measurements motivated this spec:

1. **Replies erode.** Comparing the 2026-06-04 archive against a fresh scrape over the
   same 27,961 root posts: **654,023 → 646,947 replies, −1.08%**. 4,782 threads (17.1%)
   lost at least one reply; 1,103 gained one. Older data therefore systematically
   under-reports whatever moderation removes.
2. **Removal is often account-level, and the platform says why.** Probing the authors of
   deleted replies returns `AccountTakedown`, `AccountDeactivated`, or an unresolvable
   DID — distinct outcomes with different meanings. `AccountTakedown` is a **human
   moderator's judgement that the account violated policy**, generated independently of
   any classifier this project builds.

That last point is the prize. It supplies an external validation signal for a
classifier, and a source of true-positive hate candidates — which the current benchmark
set lacks entirely (it contains zero genuine hate positives, so hate recall is
unmeasurable).

## Population, measured

From 842,369 reply rows in the live store:

| | |
|---|---|
| Distinct author DIDs | **146,422** |
| Distinct handles | 146,336 (86 fewer — handles are reused or changed) |
| Authors with 1 reply | 71,873 (49%) |
| Authors with 2–9 | 59,685 (41%) |
| Authors with 10–99 | 13,953 (9.5%) |
| **Authors with 100+** | **911 (0.6%)** |
| Most replies by one author | 4,898 |

The distribution is a power law. Whether hate concentrates in the 0.6% or is diffuse is
a directly testable, policy-relevant question this data answers.

Cross-outlet participation: 139,074 authors (95%) reply to a single outlet. **This is
currently confounded** — the corpus is 94.8% nytimes.com — and should be re-measured once
spiegel, zeit and theguardian are fully scraped.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Scope | Author entity + status/profile probing only | Thread-level deletion probing is a separate spec that depends on this one |
| Identity key | **DID**, never handle | 86 more DIDs than handles; handles change and are reused |
| History model | **Write-on-change** observations | Full snapshots would be 7.6M rows/year, ~99% identical |
| `Post` relationship | **None** — join on DID | A relationship means rewriting 842,369 rows in a migration for what a join gives free |
| Derived stats | **Computed on demand**, not materialised | Reply counts and spans change on every scrape; storing them means invalidating them |
| Probe cadence | **Weekly sweep of active authors**; gone accounts re-checked every 4th sweep | ~5,900 batched calls at full population, ~100 min; ±7-day resolution on takedown timing |
| Host | **Own launchd agent** | Never competes with the 03:31 nightly scrape window |
| Profile fields | Full, including bio | Bio is self-declared affiliation signal, and far less revealing than the reply text already stored |
| Auth | **None** | `getProfiles` works unauthenticated — removes the Keychain from this subsystem entirely |

## API facts (verified 2026-08-07)

- `app.bsky.actor.getProfiles` accepts **25 actors per call** and works **unauthenticated**
  against `https://public.api.bsky.app`.
- Returned fields: `did`, `handle`, `displayName`, `avatar`, `createdAt`,
  `followersCount`, `followsCount`, `postsCount`, `indexedAt`, `labels`, `associated`.
  `description` (bio) appears only when set.
- **Gone accounts are silently omitted from a batch response.** The difference between
  DIDs requested and DIDs returned *is* the signal — there is no error per actor.
- The **reason** requires a single-actor `app.bsky.actor.getProfile`, which returns HTTP
  400 with `AccountTakedown`, `AccountDeactivated`, or `InvalidRequest` (DID no longer
  resolvable, i.e. deleted).
- `labels` on a `getProfiles` response does **NOT** carry Bluesky's moderation labels.
  **Corrected 2026-08-10 by measurement.** Across 500 sampled reply authors, every label
  returned by `getProfiles` was a user *self-applied* privacy flag (`!no-unauthenticated`)
  — zero moderation labels. A probe built on `getProfiles` would have collected no
  moderation signal at all while appearing to work.

  Moderation labels come from the labeler service, queried directly and unauthenticated:

  ```
  GET https://mod.bsky.app/xrpc/com.atproto.label.queryLabels
      ?uriPatterns=<did-or-at-uri>&uriPatterns=...&limit=250
  ```

  Measured against this corpus on 2026-08-10:

  | Subject | Sample | Carrying ≥1 label |
  |---|---|---|
  | Reply authors (accounts) | 600 | **46 (7.7%)** — `needs-review` 27, `!suspend` 16, `!takedown` 4, `spam` 2, `rude` 1, `!hide` 1 |
  | Replies (posts) | 600 | **1 (0.17%)** — `intolerant` |

  Post-level labels are rare but are the highest-value signal in the project: a moderator's
  judgement on specific content. The relevant vocabulary from `moderation.bsky.app`:
  `intolerant` (discrimination against protected groups), `extremist`, `threat`, `rude`,
  and for disinformation `misinformation`, `misleading`, `rumor`, `inauthentic`,
  `impersonation`, `engagement-farming`.

  There is **no counter-speech label** — moderators label violations, not virtues — so
  counter-speech still requires human annotation.

## Architecture

Two new `@Model` types, registered in `BlueXSchema.all`. Nothing about `Post`,
`TrackedAccount`, `Annotation` or the scrape/annotate paths changes.

### `ReplyAuthor` — stable identity, current state

```
did              String   unique key
firstSeenAt      Date     earliest reply by this DID in the corpus
lastSeenAt       Date     latest reply by this DID in the corpus
currentHandle    String?  denormalised from the newest observation, for convenience
currentStatus    String   active | takedown | deactivated | deleted | unknown
lastProbedAt     Date?    nil until first probed
observations     [AuthorObservation]  cascade
```

`currentStatus` and `currentHandle` are caches of the newest observation, kept so the
common query ("which authors are still active?") does not require a join. They are
derived, never authoritative.

### `AuthorObservation` — an immutable point-in-time record

```
observedAt       Date
status           String   active | takedown | deactivated | deleted | unknown
statusReason     String?  raw API error string when not active
handle           String?
displayName      String?
profileDescription String?   the bio
accountCreatedAt Date?    from the profile — enables "account age at time of reply"
followersCount   Int?
followsCount     Int?
postsCount       Int?
labels           String?  comma-joined label values, empty string when none
hasAvatar        Bool
author           ReplyAuthor?  nullify
```

Written **only when something material changed** since the last observation. Change is
defined precisely as a difference in: `status`, `handle`, `labels`, `displayName`,
`profileDescription`, or `accountCreatedAt`.

**Counts are recorded but do not trigger an observation.** Follower and post counts drift
continuously for active accounts, so including them in change detection would write ~146k
rows every sweep and defeat the design. Counts are captured in whatever observation a real
change produces. This means an account that never changes status has counts only from its
baseline observation — accepted, because no stated research question needs a follower time
series for 146k members of the public. If one emerges, it is a separate decision.

The first sweep therefore writes ~146k baseline rows; subsequent sweeps write far fewer.

Nullable numeric fields matter: a gone account has no counts, and `0` would be a lie.

## Components

| Component | Location | Purpose |
|---|---|---|
| `ReplyAuthor`, `AuthorObservation` | `BlueX/Data/` | The models above |
| `AuthorBackfill` | `BlueX/Services/Authors/` | Populate `ReplyAuthor` from existing `Post` rows; idempotent |
| `AuthorProbe` | `BlueX/Services/Authors/` | Batch + reason-lookup logic; pure, no store access |
| `AuthorProbeRunner` | `BlueX/Services/Authors/` | Drives probe over the store, applies write-on-change |
| `blueX-authors` | `cli/authors/` | New CLI: `--backfill`, `--probe`, `--stats` |
| `bluex-authors-job.sh` | `tools/jobs/` | Weekly job wrapper, sources `lib-bluex-job.sh` |
| `net.pulsschlag.bluex.authors.plist` | installed by `install-jobs.sh` | Weekly agent |

`AuthorProbe` is deliberately separated from `AuthorProbeRunner` so the batching, the
requested-vs-returned diff, and the reason classification can be unit-tested against a
mock session with no SwiftData involved. That is the same split that made
`ScrapeSession` testable after the token-refresh bug proved untestable in place.

## Data flow

```
blueX-authors --backfill        (once, then cheap on re-run)
  SELECT DISTINCT authorDID over Post where isRootPost = false
  upsert ReplyAuthor(did, firstSeenAt, lastSeenAt)

blueX-authors --probe           (weekly agent, ~100 min)
  select authors due for probe
    - status active or unknown   -> every sweep
    - status takedown/deleted    -> every 4th sweep (deactivation is reversible)
  for each chunk of 25:
      GET getProfiles(actors)                       [unauthenticated]
      returned DIDs      -> build observation, status = active
      requested-not-returned -> GET getProfile(did) -> status + reason
  write observation only if changed vs newest existing
  update ReplyAuthor.lastProbedAt / currentStatus / currentHandle always
```

## What this enables

- **Takedown rate** in the population, not a biased sample. An ad-hoc probe of the 40
  authors with the most deleted replies found 31 gone — but that sample was selected for
  exactly the property being measured, so it estimates nothing. The full sweep does.
- **Enforcement latency** — time from an account's first reply, or first hateful reply
  once a classifier exists, to its takedown. ±7 days.
- **Enforcement coverage** — the fraction of hate-producing accounts ever actioned.
- **Survival curves by cohort**, e.g. accounts created during an event window.
- **Account age at time of reply** — the throwaway-account signature.
- **Handle-change history** — an evasion signal.
- **True-positive hate candidates** for the benchmark set, drawn from taken-down accounts.

## Error handling

- **Rate limiting:** reuse `BlueskyAPIClient`'s existing 429 back-off. The job is
  bounded by a wall-clock deadline in the same way the nightly job is, and a sweep that
  runs out of time resumes next week — `lastProbedAt` makes progress durable, so no
  sweep state needs persisting.
- **Transient absence is not deletion.** A DID missing from one batch is only recorded
  as gone if the single-actor lookup confirms it with a specific reason. An unclassified
  absence is recorded as `unknown`, never as `deleted`.
- **Reversibility:** `AccountDeactivated` can revert to active. Statuses are therefore
  observations, never terminal, and gone accounts are re-probed periodically.
- **Partial failure:** one failed chunk must not abort the sweep. Errors are counted and
  the job exits non-zero if any occurred, consistent with the scrape's behaviour.
- **The store is never mutated by a failed probe** beyond `lastProbedAt`.

## Testing

- `AuthorProbe` unit tests with a mock session: a full batch; a batch with omissions; the
  requested-vs-returned diff; each reason code mapped correctly; an unclassifiable
  absence becoming `unknown`, not `deleted`.
- Write-on-change: an unchanged profile writes no observation; a changed handle, status,
  label set or count does.
- `AuthorBackfill` idempotency: running twice produces the same row count and does not
  duplicate authors.
- Nullable counts: a gone account stores `nil`, not `0`.
- Job script tests extend `tools/jobs/test_jobs.py`: `/Volumes` used only for the store
  path, no `sudo`, paths redirect under a test `HOME`.

## Privacy and retention

This stores identifiable personal data about 146,422 people — handles, bios, and the
political speech already held as reply text. Under GDPR political opinion is
special-category data. The controls that matter are lawful basis, retention, and what is
published — not field minimisation, since the reply text already held is far more
revealing than a profile bio.

**Recorded as an explicit decision, not a default:** full profiles including bio are
stored, because the bio is genuine analytic signal (self-declared affiliation) and is
less revealing than data already retained. Pseudonymisation is a **publication-time**
concern, and the analysis outputs — not this store — are where it must be applied.

## Out of scope

- **Thread-level deletion probing.** Separate spec; depends on the author status this one
  produces to distinguish "reply deleted" from "account removed".
- **Enriching the existing 10,067-record deleted-reply dataset** with author status. A
  natural follow-up once the backfill and first sweep exist; not part of this spec.
- Classifier work, gold-set construction, and the hate/counter/disinformation passes.
- Materialised per-author statistics.
- Any change to the scrape or annotate paths.

## Open questions

- **Sweep duration is estimated, not measured.** ~100 minutes assumes one call per
  second and no rate limiting. The first real sweep replaces this estimate.
- **How many authors are already gone is unknown.** The 31/40 figure is from a
  deliberately biased sample and must not be quoted as a rate.
- **Label vocabulary is unsurveyed.** `labels` is captured as raw values; deciding which
  matter is analysis work, not collection work.
