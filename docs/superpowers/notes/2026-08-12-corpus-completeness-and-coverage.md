# Corpus completeness and coverage — measured 2026-08-12

Answers the question "do we have all replies and reply trees?" with numbers, and records
what is structurally missing and why.

## Reply trees: essentially complete

| | |
|---|---|
| Trees walked to completion (`replyTreeStatus = complete`) | **253,166** |
| Still `inProgress` | **2** |
| Replies whose root post is missing from the store | **0** |

Perfect referential integrity — every reply belongs to a root also held.

## Per-outlet coverage

| Outlet | Roots | Zero-reply roots | Span held |
|---|---|---|---|
| spiegel.de | 81,360 | 38,952 (48%) | 2024-01-23 → 2026-08-04 |
| theguardian.com | 57,303 | 6,897 (12%) | 2024-11-15 → 2026-08-05 |
| zeit.de | 39,387 | 25,072 (64%) | 2024-01-01 → 2026-08-05 |
| nytimes.com | 39,063 | 1,281 (3%) | 2024-01-01 → 2026-08-04 |
| tagesschau.bsky.social | 36,087 | 8,985 (25%) | 2024-01-01 → 2026-08-04 |

**81,167 roots (32%) have zero replies.** These are not gaps — the tree *was* walked and
found empty. But the variation is large and analytically important: NYT draws replies on 97%
of posts, zeit on 36%. "Replies per outlet" and "replies per *engaged* post" will therefore
tell different stories; the analysis must state which it uses.

## zeit.de starvation: cause and fix, confirmed

zeit sat at **2,997 roots** for weeks while theguardian reached 56,472. Cause: accounts were
scraped in strict alphabetical order (`sortBy: [SortDescriptor(\.handle)]`), passes routinely
ran 20+ hours and were interrupted, so the alphabetically-last outlet was never reached.

Fixed by randomly rotating the account queue (`ScrapeOrder.rotated`, commit `4c425cf`).
Outcome: **zeit went 2,997 → 39,387 roots in one pass**, a 13× increase. The German-media
comparison is now defensible rather than an artifact of queue position.

Caveat: random rotation removes *systematic* starvation but does not guarantee fairness —
zeit drew a late slot in two consecutive passes before finally being reached. If it recurs,
a deterministic round-robin would guarantee each outlet the lead position in turn.

## What is structurally missing

### 1. History before the configured floor — now fixed

`AccountSeeder` set every account's `startAt` to 2024-01-01, and the corpus reflected it
exactly. **There is no API history limit.** Measured 2026-08-12: walking tagesschau's feed
with `getAuthorFeed` took **406 pages / 40,544 posts / 6.5 minutes** and terminated on "no
cursor" at **2023-09-14** — precisely that account's first post per its PDS repo.

Each outlet's true first post:

| Outlet | First post ever | Was missing |
|---|---|---|
| nytimes.com | 2023-06-22 | ~6 months |
| tagesschau.bsky.social | 2023-09-14 | ~3.5 months (**+4,457 roots** reachable) |
| spiegel.de | 2023-10-02 | ~4 months |
| zeit.de | 2023-10-23 | ~2 months |
| theguardian.com | 2024-11-15 | **none — that is their first post** |

The Guardian's late start was never a gap; they joined Bluesky on 2024-11-15.

Floor lowered to 2023-01-01 in commit `21c2203`. A single early date is correct because the
walk terminates naturally when history is exhausted.

**Important discovery from that work:** `FeedScraper.scrape` uses `startAt` only as a
*storage filter* (`postDate >= account.startAt`); the page walk has **no independent cap**
and runs until the cursor is nil. So every pass was *already* walking each account's full
history and discarding pre-2024 posts. Lowering the floor therefore costs **zero additional
API calls** — and it partly explains why passes take 12+ hours per account.

Applying it to the live store requires `AccountSeeder.reconcileStartDates` to run, which
happens on app launch via `resetToSeedSet`. `startAt` can only move **earlier**, never later.

### 2. Replies deleted before we scraped — unrecoverable

Comparing the June 2026 archive against a re-scrape over the same 27,961 roots:
**654,023 → 646,947 replies, −1.08%**, with 4,782 threads (17.1%) losing at least one reply.

Moderation removes the most extreme content first, so this erosion is **biased against
exactly the material the project studies**. Older content is the most eroded — which is a
caveat on the newly-recovered 2023 slice specifically.

### 3. Accounts whose content is gone entirely

Verified 2026-08-10: for `AccountTakedown`, `AccountDeactivated` and deleted (unresolvable
DID) accounts, **both** `getAuthorFeed` (AppView) **and** `com.atproto.repo.listRecords`
(the account's own PDS) return HTTP 400. The PLC directory entry survives, so the account's
prior existence and its PDS are provable, but no content is retrievable.

This is why prospective archiving matters: content from accounts that are later removed can
only be held if it was captured beforehand.
