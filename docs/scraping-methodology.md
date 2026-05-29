# BlueX Scraping Methodology

This file documents the scraping algorithm — what BlueX fetches from the Bluesky public API, how it decides what to fetch, and how it handles failures. It complements `ARCHITECTURE.md` (which describes the code layout) by describing the behaviour.

The scraping pipeline is the data foundation of every downstream analysis (sentiment, hate/counter-speech classification, charts). The guarantees below — completeness, idempotency, resumability — are deliberate; later analysis trusts them.

---

## What gets scraped

For every active `TrackedAccount`:

1. **Root posts** — every post authored by the account, back to the account's `startAt` cutoff (default `2024-01-01`). Reposts and replies-to-others are excluded; we want only original threads. Source: `app.bsky.feed.getAuthorFeed` with `filter=posts_no_replies`.
2. **Reply trees** — for every root post, the entire reply subtree (all depths). Reply authors are NOT tracked accounts — they're members of the public engaging with the news outlet. We don't follow reply-of-reply chains across accounts; the tree we capture is rooted at one of our accounts. Source: `app.bsky.feed.getPostThread` with `depth=10`.

Each post (root or reply) carries:
- Identity: AT URI, author DID + handle.
- Content: text and `createdAt`.
- Engagement counters: like / reply / quote / repost.
- Tree position: `parentURI`, `rootURI`, `isRootPost`, `depth`.
- Scrape lineage: `replyTreeStatus`, `replyTreeLastChecked` (root posts only).

---

## The completeness guarantee

> Every root post in a tracked account's history is eventually scraped completely, no matter how many sessions the work is spread across.

This is the load-bearing invariant. Three rules cooperate to enforce it:

### 1. Status as the "scraped at least once" signal

`Post.replyTreeStatus` has three values:

| Status | Meaning |
|---|---|
| `.pending` | Stored by the feed scraper, thread scrape never attempted. |
| `.inProgress` | Thread scrape started but didn't finish — either a transient API failure or the run was interrupted. |
| `.complete` | Thread scrape finished successfully, OR the post was confirmed dead (`.notFound` / `.badRequest`) and frozen. |

Only `.complete` counts as "we got everything we could." Anything else is unfinished business.

### 2. RescrapingPolicy: incomplete ⇒ always due

```text
replyTreeStatus != .complete  →  ALWAYS scrape, regardless of age
replyTreeStatus == .complete  →  scrape only while inside the rescrape window
```

A 2-year-old root post that's still `.pending` (e.g. the historical backfill hadn't reached it yet) is just as due as a post from yesterday. There is no age cutoff on the "first scrape" — the window only applies once we've successfully scraped a post once.

### 3. ThreadScraper continues on per-post failure

When `scrapeAllThreads` walks the rescrapable set, one failing post does NOT abort the rest of the account. Each post is wrapped in its own try/catch:

- **Terminal failure** (`.notFound`, `.badRequest`): the post is gone (deleted / blocked / malformed URI). Mark it `.complete` with `replyTreeLastChecked = Date()` so we don't loop on a dead URI forever. The reply tree we capture for it is empty, which matches reality.
- **Transient failure** (`.networkError`, `.rateLimited`-after-retries, token expired): leave the post as `.inProgress`. The next run picks it up via Rule 1.

The net effect: a long backfill that's split across many runs (because of rate limits, network drops, Ctrl-C) converges to full coverage over those runs. No single failure can permanently exclude a post.

---

## The rescraping window

Once a post is `.complete`, the policy decides whether to refresh its reply tree on the next run:

```text
needsRescrape(post)  ⟺  post.replyTreeLastChecked  ≤  post.createdAt + window
```

`window` defaults to **14 days** (overridable via `scraping.maxRescrapeWindowDays`). The reasoning:

- Reply velocity on Bluesky drops sharply after a few days. Beyond ~14 days, a refresh almost never finds new replies.
- The "≤" comparison gives one *final* catch-up scrape just after the window closes: a post scraped on day 5 will be re-scraped one more time on day 30, capturing replies that landed between the two probes. After that catch-up, `lastChecked` advances past `createdAt + window` and the tree is frozen.

So the lifecycle of a root post's tree is:

```
day 0:  scraped (inside window) → .complete, lastChecked = 0
day 1:  scraped again (inside window) → lastChecked = 1
…
day 14: window closes
day 30: scraped one final time (lastChecked still < 14) → lastChecked = 30
day 31+: frozen (lastChecked > 14)
```

---

## Failure handling

Everything below happens transparently — the caller (`ScrapeCoordinator`, the CLIs) never has to special-case rate limits or one-off failures.

### Rate limiting (HTTP 429)

Bluesky's public API budget is ~3,000 requests/hour. Sustained scraping on a high-volume account (e.g. NYT, ~1,500 root posts × 1 thread call each) routinely hits this.

`BlueskyAPIClient.perform` handles 429 reactively:

1. Read `Retry-After` (defaults to 60 s if absent).
2. Fire `onRateLimited(retryAfter, attempt)` — the CLI prints `⏸ rate limited — waiting 60s (retry 1)…`; the GUI sets `ScrapeCoordinator.rateLimitWaiting`.
3. `Task.sleep` for `retryAfter` seconds.
4. Re-issue the same request.

Up to `maxRateLimitRetries` (default 5) consecutive 429s are absorbed this way. Past that, `.rateLimited` surfaces to the caller — at which point we treat it as a transient failure (the post stays `.inProgress`, picked up next run).

The point of in-client retry: a long-running scrape never *loses its place* on a rate limit. Without it, a 429 would propagate up through `scrapeThread` → `scrapeAllThreads` → `ScrapeCoordinator.runScrape` and the remaining un-visited posts would be silently skipped for that run. With it, we just pause and resume.

### Terminal failures (HTTP 400 / 404)

`.badRequest` is what Bluesky returns for:
- Posts whose author deleted their account.
- Quoted posts whose owner blocked the scraper.
- Malformed AT URIs (shouldn't happen from us, but defensive).

`.notFound` is the same shape — the post was once there, isn't anymore.

For both, the post will never become scrapable. We mark it `.complete` to take it out of the rescrape pool. We don't delete it from the store — it stays as a record of an account-authored URI, just with an empty reply tree.

### Transient failures (network, decoding, exhausted 429s)

Left as `.inProgress`. Picked up by the policy on the next run. There's no exponential back-off or retry counter at this level — runs are usually triggered by the user or a cron, so "retry next time" is fine cadence.

### Token expiry (HTTP 401)

Currently treated as a transient failure (i.e. `.inProgress`, retry next run). Re-authentication happens at run start, so the next run gets a fresh token. If mid-run token expiry becomes a problem, we'd add an in-flight refresh — but Bluesky access tokens last ~1 h, and a single account's scrape rarely exceeds that.

---

## Order of operations per account

`ScrapeCoordinator.runScrape` does, for each tracked account:

1. **Refresh phase** (`ThreadScraper.scrapeAllThreads`): walk every stored root post for the account. Any that the policy says is due gets its tree re-scraped. This is where `.pending` posts from earlier interrupted runs finally get visited, and where in-window roots get one more refresh.
2. **Discovery phase** (`FeedScraper.scrape`): paginate the author feed back to `startAt`. For each NEW root post (not already in the store), insert it and immediately call `ThreadScraper.scrapeThreadIfDue` so the tree is captured in the same pass — depth-first. Cursor is persisted after every page so a mid-pagination crash can resume.

The two phases are disjoint: phase 1 visits already-stored posts the policy says are due; phase 2 visits never-stored posts. No root is scraped twice in one run.

---

## What we deliberately don't do

- **No post deletion.** Once stored, a post stays in the store. Bluesky API may stop returning it (deletion, block), but our copy of the text and engagement counts is preserved for analysis. The corresponding root just gets frozen as `.complete` with whatever tree we last had.
- **No retroactive policy changes.** Tightening the window doesn't re-freeze posts that have already passed the old window. The state machine is monotonic: once a post is `.complete`, it doesn't go back to `.inProgress` (except by manual intervention).
- **No automatic re-annotation.** Scraping refreshes posts; the LLM annotation pass is a separate, user-triggered step. A post that gets a new reply during the window does not invalidate the existing annotations of older replies in the same tree.
- **No deduplication across accounts.** If the same reply URI appears under two different tracked accounts (rare but possible — a public reply to NYT that was also a reply to BBC's quote of the same NYT post), it's stored once but referenced from whichever root's tree we processed first.

---

## Files

- `BlueX/Services/Scraping/RescrapingPolicy.swift` — the `needsRescrape` predicate.
- `BlueX/Services/Scraping/ThreadScraper.swift` — terminal vs transient classification, per-post try/catch, `PassSummary`.
- `BlueX/Services/Scraping/FeedScraper.swift` — pagination with cursor-resume.
- `BlueX/Services/Scraping/ScrapeCoordinator.swift` — orchestration, rate-limit observable.
- `BlueX/Services/API/BlueskyAPIClient.swift` — `perform` with auto-retry 429, observer callback.
- `BlueX/Services/API/BlueskyError.swift` — the error taxonomy this methodology branches on.
