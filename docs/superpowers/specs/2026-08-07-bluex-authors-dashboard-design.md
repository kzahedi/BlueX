# BlueX — Authors Dashboard and Shared Aggregation Layer (2026-08-07)

Surface the reply-author population in the BlueX app, and fix the chart slowness that
makes the existing dashboards painful to use. Both come from one root cause — aggregates
are computed by materialising SwiftData objects — so they get one solution.

## Why now

Two measurements, taken 2026-08-07 against the live store at
`/Volumes/Eregion/bluex-data/default.store` (892,855 posts, 48,353 roots):

| Path | Time | Result |
|---|---|---|
| `AuthorBackfill` — SwiftData paged fold over all posts | **2h44m, did not finish** | 0 rows written |
| `SELECT ... GROUP BY ZAUTHORDID` in SQLite | **0.50s** | 146,541 |

Same question, same answer, four orders of magnitude apart. The SwiftData run was not
stuck — 95.7% CPU, 145 min CPU time, 120 MB RSS, flat memory. Materialising ~892k
managed objects simply costs that much. It was killed after this was measured; the store
passed `PRAGMA quick_check` afterwards with all 892,855 posts intact.

The same defect makes the existing charts freeze. `AccountChartsView.recompute()`
(`BlueX/Views/Account/AccountChartsView.swift:31-37`) fetches replies with
`rootURIs.contains($0.rootURI)` — a 29,710-element `Set` predicate evaluated against
844,502 reply rows with **no index on `ZROOTURI`** (the store's only index is
`ZPOST_ZACCOUNT_INDEX`) — builds an array of ~874,000 `Post` objects, then
`ChartsViewModel.computeBuckets` runs eight `.filter` passes per week bucket plus a
relationship fault per post for sentiment. All on the MainActor, to produce twelve numbers.

**Chart-point decimation does not fix this.** Buckets are weekly and the default window is
12 weeks, so the chart draws 12 points. The cost is entirely upstream. Decimation is still
adopted, but for the places where point counts genuinely reach six figures — see
*Rendering*.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Aggregation | **Read-only SQL** against the store file | 0.5s vs 2h44m, measured |
| Write path | **Unchanged — SwiftData only** | One writer; the reader never writes |
| Scope of stats | **Population and per-author** | Explicit user scope: "stats about all accounts and individual accounts" |
| Candidate workflow | **Out** — no flagging, export, or queue push | Dropped by the user; the dashboard reads and summarises |
| Moderation panels | **Deferred**, layout reserved | No probe data exists; shipping empty charts is worse than not shipping them |
| Sentiment | **Excluded** | `ZANNOTATION` has 0 rows — nothing to show |
| Author list | **Ranked and capped**, cap visible | 146,541 rows is not scrollable; an invisible cap misrepresents coverage |
| Backfill | **Rewritten on SQL**, with progress output | A job that runs for hours must not be silent |

## Data reality (measured 2026-08-07)

- 892,855 posts; 48,353 roots; 844,502 replies
- **146,541** distinct reply-author DIDs
- `ZREPLYAUTHOR` and `ZAUTHOROBSERVATION` exist and are **empty**
- `ZANNOTATION` is **empty** — no sentiment, no speech class
- Corpus spans 2018-01-01 → 2026-08-06
- Posts per account: one account holds 29,710 roots; 844,502 replies carry no account
  relationship (replies are scoped only via `rootURI`)

Every author created by the backfill has `currentStatus = "unknown"`, `lastProbedAt = nil`,
and zero observations. Handle is `nil` until a probe runs.

## Architecture

### `AggregateReader` — `BlueX/Services/Stats/`

A read-only SQLite connection opened on the same file with `mode=ro`, running `GROUP BY`
queries and returning plain Swift structs. Never returns SwiftData objects. Never writes.

It queries Core Data's private `Z`-prefixed schema, which Apple does not contract to keep
stable. Two mitigations, both required:

1. **All SQL lives in this one file.** No SQL anywhere else in the app.
2. **A schema-guard test** asserts every table and column the reader depends on still
   exists, so a model change fails a test instead of silently returning wrong numbers.

Opened `mode=ro` on a WAL store: reads see committed data. `?immutable=1` must **not** be
used — it is WAL-blind and previously reported 0 accounts on a store holding 6.

### Consumers

| Consumer | Change |
|---|---|
| `AuthorStatsViewModel` (new) | Population and per-author stats |
| `ChartsViewModel` | Retrofitted onto the reader; the eight-filter bucket loop deleted |
| `AccountChartsView.recompute()` | Deleted, with its `contains` scan |
| `GroupChartsView` | Same retrofit |
| `AuthorBackfill` | SQL fold, then batched SwiftData insert |

All aggregation runs off the MainActor.

### Indexes

Add indexes on `ZAUTHORDID` and `ZROOTURI`. The store has one index today
(`ZPOST_ZACCOUNT_INDEX`), which is why the reply scan is a full table scan.

**SETTLED 2026-08-10 by measurement.** Evidence:
`docs/superpowers/notes/2026-08-07-index-route-measurement.md`. Both candidate routes were
tested and both failed in the form this spec originally proposed:

1. **`@Attribute(.indexed)` does not exist on this SDK.** `Schema.Attribute.Option` has no
   `.indexed` case — it is a compile error, not a silently-ignored no-op as this spec
   assumed. SwiftData's actual mechanism is the `#Index<Model>` macro, which requires
   **macOS 15+**, above this project's `deploymentTarget: macOS 14.0`. Unavailable.
2. **A one-time `CREATE INDEX IF NOT EXISTS` did not survive a model change.** After
   adding an optional property to `Post` and reopening, **all three hand-created indexes
   were gone**; only Core Data's own `ZPOST_ZACCOUNT_INDEX` remained, with
   `PRAGMA quick_check` still `ok`. The loss is silent — queries revert to full scans with
   nothing reporting it.

   **Caveat on the mechanism, recorded honestly.** The probe store held **zero `Post`
   rows**, so data survival — the strongest evidence of an *in-place* migration — was
   never observable. It is therefore NOT established whether SwiftData migrated the store
   and dropped the indexes, or simply rebuilt it from scratch. The observed *outcome*
   (indexes absent after a model change) is solid; the *mechanism* is not. Anyone
   re-testing should use a probe store containing rows, so data survival distinguishes the
   two cases.

   This does not change the decision: under either mechanism the indexes vanish silently
   after a model change, and the mitigation is identical.

**Decision: assert the indexes idempotently on every store open**, from a short-lived
write connection opened before any `AggregateReader` read connection.
`CREATE INDEX IF NOT EXISTS` against an already-indexed table is a `sqlite_master` lookup,
not a rebuild, so it costs nothing in the normal case and self-heals exactly when a
migration has dropped them. This is the same pattern Core Data uses for its own index.

Applying this to the live store is an **attended** step. A corpus scrape and a label
harvester write to `/Volumes/Eregion/bluex-data` continuously; building an index under an
active writer risks lock contention on 1.5M rows of irreplaceable research data.

**Open hole in this design, raised by Task 3's review and not yet solved.** Re-assertion
needs a *write* connection, but `AggregateReader` is read-only by construction and the
dashboard's whole point is to read. A process that only ever reads — the app opening the
dashboard without the scrape or a CLI having run first — would never trigger the
re-assertion and would run unindexed **silently**, which is the same silent-degradation
failure the migration experiment exposed. Candidate answers, to be decided when this is
wired up:

1. Re-assert from `BlueXStore.openContainer()`, which every process calls before reading.
   Covers the app and all three CLIs, but couples store-opening to index maintenance.
2. Have `AggregateReader` *detect* the missing index (`sqlite_master` lookup, cheap) and
   surface it as a visible degraded state rather than fixing it — a reader that cannot
   write should not pretend it can.

Option 2 is the honest one for a read-only type; option 1 is what actually keeps the
indexes present. They are not exclusive, and doing both is probably right: fix on open,
detect and report on read.

### Navigation

`SidebarItem` gains an `authors` case, alongside the existing non-model `.queue` and
`.settings` cases — additive, no restructure. Content column: the author list. Detail
column: per-author charts, or the population overview when no author is selected.

## Screens

### Population overview

- Summary chips: total authors, total replies, median replies per author, authors active
  in the last 30 days
- Participation histogram, log bins: 1, 2–9, 10–99, 100–999, 1000+
- New authors per week, by first-seen cohort
- Replies and authors per outlet; count of authors reaching 1, 2, 3+ outlets
- Activity-span distribution (days between first and last reply)
- Status breakdown — reads 146,541 `unknown` today; becomes the moderation panel once the
  probe subsystem ships

Cross-outlet figures are **confounded** while the corpus is dominated by one outlet, and
the view must label them as such rather than presenting them as a finding.

### Author list (content column)

Sortable columns: handle-or-DID, reply count, first seen, last seen, span in days, outlets
touched. Filters: minimum replies, date range, outlet.

**Capped at the top 500 by the active sort**, adjustable, with the cap displayed. Sorting
and filtering happen in SQL, so the cap selects from the whole population rather than from
a preloaded subset.

### Individual author (detail column)

- DID, handle if known, status
- Chips: total replies, first seen, last seen, span, outlets engaged
- Replies per week
- Outlet breakdown
- Their replies, paged, each showing the root post it answered, linking into the existing
  `ThreadView`

## Rendering

Decimation applies where point counts are large, not to the weekly buckets:

- Per-author weekly series spans 2018→2026 — up to ~450 points. Downsample to the chart's
  pixel width.
- Population distributions bin rather than plot individual authors.
- The author list is capped, as above.

Weekly account and group buckets are left undecimated; at 12–450 points they are not the
problem.

## Error handling

- **Store unavailable.** The reader fails the same way `BlueXStore` does — the Eregion
  volume may be unmounted. Surface it as a visible state, never as zeroes, which would
  read as "no authors" rather than "no store".
- **Schema drift.** A missing table or column raises at open, not per query, so the
  failure is one clear message rather than a screen of empty charts.
- **Empty subsystem.** With `ZREPLYAUTHOR` empty (before the backfill runs), the dashboard
  states that the backfill has not run — distinct from "0 authors found".
- **Cancellation.** Aggregation runs in a cancellable task; switching authors quickly
  cancels in-flight work rather than queueing it.

## Testing

- `AggregateReader` against a fixture store: per-author counts, min/max dates, outlet
  attribution, bin boundaries, empty-store behaviour.
- **Schema-guard test** — fails loudly if a depended-on table or column disappears.
- **Equivalence test** — the reader's per-author aggregate matches a SwiftData-computed
  result on a small fixture, proving the SQL says the same thing as the object graph.
- Backfill idempotency preserved: a second run creates 0 and extends ranges.
- Decimation: a downsampled series preserves first and last points and monotonic ordering.
- Cap honesty: a capped list reports the true total alongside the displayed count.

## Out of scope

- Moderation panels (takedown rate, enforcement latency, coverage, labels, followers,
  account age) — needs the probe subsystem: plan Tasks 2, 3, 4, 6, 7b.
- Anything sentiment- or speech-class-derived — no annotations exist.
- Flagging, notes, export, or pushing authors into the annotation queue.
- Thread-level deletion probing.
- Any change to the scrape or annotate write paths.

## Open questions

- **Backfill insert time is unmeasured.** The SQL fold is 0.5s; inserting 146,541
  `ReplyAuthor` rows through SwiftData is expected to take minutes, but that is an
  estimate. The first real run replaces it.
- **Index creation route — RESOLVED 2026-08-10** by measurement; see *Indexes* above and
  `docs/superpowers/notes/2026-08-07-index-route-measurement.md`. `@Attribute(.indexed)`
  does not exist on this SDK, and hand-created indexes do not survive a lightweight
  migration. Resolution: re-assert them idempotently on every store open.
- **Index build cost on the live store is still unmeasured.** The 874 MB store has never
  had these indexes built. Expected seconds to low minutes, but that is an estimate, and
  it must be done with the store idle — not under the active scrape and label harvester.
- **Cross-outlet participation stays confounded** until spiegel, zeit and theguardian are
  fully scraped.
