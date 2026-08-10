# Index route measurement: authorDID / rootURI

**Question this settles:** the dashboard's outlet join (`ZPOST p JOIN ZPOST r ON
p.ZROOTURI = r.ZURI`) is a full scan today — measured 6.35s on 2026-08-07, reconfirmed
below at 3.41s on 2026-08-10 (same store, grown, still no relevant index). Two candidate
routes were proposed to fix it. Neither survives contact with SwiftData/Core Data as
naively described. This note records the exact evidence for both, and what is actually
recommended.

All measurements below were taken against **throwaway stores only** — a store built by
`SQLiteWriteHelper`/`StoreFixture` under `NSTemporaryDirectory()`, and a store created by
running `blueX-authors --stats` with `BLUEX_STORE_DIR` pointed at a `mktemp -d`
directory. The real store at `/Volumes/Eregion/bluex-data` was touched **read-only**
exactly twice (`?mode=ro`, never `?immutable=1`), for a baseline timing and an
`EXPLAIN QUERY PLAN`, while the nightly scrape was actively writing to it (confirmed by
`default.store` mtime matching the current run). No write, no lock, no migration was
performed against it. Applying a route to that store is deliberately deferred to a
session where a human can confirm the scrape is idle — this note stops short of that.

## Route 1 — `@Attribute(.indexed)` on `Post.authorDID` / `Post.rootURI`

Added to `BlueX/Data/Post.swift`:

```swift
@Attribute(.indexed) var authorDID: String
...
@Attribute(.indexed) var rootURI: String
```

Built the real `BlueXAuthors` CLI target (deployment target macOS 14.0, SDK is Xcode
26.6 / MacOSX26.5.sdk in this environment):

```
$ xcodegen generate
$ xcodebuild build -project BlueX.xcodeproj -scheme BlueXAuthors \
    -destination 'platform=macOS,arch=arm64' -quiet
...
/Volumes/Eregion/projects/bluex-v2/BlueX/Data/Post.swift:17:17: error:
  type 'Schema.Attribute.Option' has no member 'indexed'
    @Attribute(.indexed) var authorDID: String
** BUILD FAILED **
```

**Route 1 is dead, and more decisively than the brief anticipated.** The brief warned
SwiftData's indexing support "may silently ignore" the attribute on macOS 14 — implying
the API exists but has no effect. It does not even exist. `Schema.Attribute.Option` has
no `.indexed` case on this SDK. What SwiftData actually ships for indexing is a separate
mechanism — `Schema.Index` / the `#Index<Model>(...)` macro — confirmed present in the
SDK's `SwiftData.tbd` (`Schema.Index`, `Schema.Index.CodingKeys`, etc. all resolve), but
that macro requires macOS 15+, above this project's `deploymentTarget: macOS 14.0`
(`project.yml`). So even upgrading to the real API is not an option without raising the
deployment target, which is out of scope here. Route 1 was reverted; `git diff
BlueX/Data/Post.swift` is empty.

## Route 2 — hand-created `CREATE INDEX IF NOT EXISTS`

### Step A: build once, works

Built a throwaway store by running the real app-facing CLI (not SwiftData API calls in a
test — the actual container-creation path):

```
$ export BLUEX_STORE_DIR="$(mktemp -d)/probe"; mkdir -p "$BLUEX_STORE_DIR"
$ blueX-authors --stats
authors: 0
  (probed at least once: 0)
$ sqlite3 "file:$BLUEX_STORE_DIR/default.store?mode=ro" \
    "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='ZPOST';"
ZPOST_ZACCOUNT_INDEX
```

Confirms the throwaway store's baseline matches the real store exactly: one index, the
one Core Data creates for the `TrackedAccount` relationship. Added the hand-made indexes
with a **write** connection (the read-only `SQLiteConnection` cannot do this by design):

```
$ sqlite3 "$BLUEX_STORE_DIR/default.store" "
CREATE INDEX IF NOT EXISTS IDX_ZPOST_ZAUTHORDID ON ZPOST(ZAUTHORDID);
CREATE INDEX IF NOT EXISTS IDX_ZPOST_ZROOTURI ON ZPOST(ZROOTURI);
CREATE INDEX IF NOT EXISTS IDX_ZPOST_ZURI ON ZPOST(ZURI);"
$ sqlite3 "file:$BLUEX_STORE_DIR/default.store?mode=ro" \
    "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='ZPOST';"
ZPOST_ZACCOUNT_INDEX
IDX_ZPOST_ZAUTHORDID
IDX_ZPOST_ZROOTURI
IDX_ZPOST_ZURI
```

All four indexes present. Core Data tolerates indexes it did not create — no error on
the next open.

### Step B: does it survive a lightweight migration?

Added a scratch optional property to `Post` (`var scratchMigrationProbe: String?`) to
force SwiftData to run a lightweight migration on next open — an add-optional-column
change is exactly the kind of migration Core Data performs by rebuilding tables (it does
not merely `ALTER TABLE`). Rebuilt `BlueXAuthors` and reran it against the **same**
store directory (no fixture wipe):

```
$ xcodebuild build -project BlueX.xcodeproj -scheme BlueXAuthors \
    -destination 'platform=macOS,arch=arm64' -quiet
$ BLUEX_STORE_DIR="$BLUEX_STORE_DIR" blueX-authors --stats
authors: 0
  (probed at least once: 0)
$ sqlite3 "file:$BLUEX_STORE_DIR/default.store?mode=ro" \
    "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='ZPOST';"
ZPOST_ZACCOUNT_INDEX
$ sqlite3 "file:$BLUEX_STORE_DIR/default.store?mode=ro" "PRAGMA quick_check;"
ok
```

**All three hand-made indexes were dropped.** Only `ZPOST_ZACCOUNT_INDEX` — the one Core
Data itself owns — survived. This confirms the brief's suspicion: a lightweight
migration rebuilds `ZPOST` and does not carry over indexes it doesn't know about. The
store's `quick_check` is `ok` afterward, so this isn't corruption, just index loss.
Reverted the scratch property afterward (`git diff BlueX/Data/Post.swift` is empty) and
deleted the throwaway store directory.

### Conclusion on Route 2

A one-time `CREATE INDEX IF NOT EXISTS` is **not** migration-durable. But the mechanism
itself works fine and is cheap: `CREATE INDEX IF NOT EXISTS` on an already-indexed table
is a no-op check, not a rebuild, so re-asserting the three indexes on every store open
(via a short-lived write connection, before any `AggregateReader` read connection is
opened) is safe to run unconditionally — it costs a `sqlite_master` lookup when the index
already exists, and a one-time index build only right after a migration actually dropped
it. This is the same pattern Core Data itself uses for its own index (recreated
automatically on every schema-compatible open) — we just do it by hand for the two
columns SwiftData has no `@Attribute` option for on this deployment target.

## Decision

**Route 2, applied idempotently on every store open — not created once.** Route 1 is not
just risky but non-existent on this SDK+deployment-target combination (compile error).
Route 2's raw form ("create once by hand") measurably fails across the one migration
path this project actually uses (adding an optional field), so the recommendation is
narrower than "hand-create the indexes": it is "hand-create the indexes as an idempotent
step every time the store is opened for writing," most naturally as a small helper called
from `BlueXStore.openContainer()` (or the CLI entry points) right after the
`ModelContainer` is constructed, using a short-lived write connection separate from
`AggregateReader`'s read-only one. **That wiring, and applying it to
`/Volumes/Eregion/bluex-data`, is Step 6 of the task-3 brief and is deliberately not done
in this session** — a live scrape and label harvester are writing to that store and its
sibling directory right now, and creating an index under an active writer risks lock
contention on 1.5M rows of irreplaceable research data. This note is the evidence a human
can check before that step is taken with the store idle.

## Baseline timing and plan, real store (read-only only)

```
$ cd /Volumes/Eregion/bluex-data && time sqlite3 "file:default.store?mode=ro" \
  "SELECT r.ZACCOUNT, COUNT(DISTINCT p.ZAUTHORDID) FROM ZPOST p
   JOIN ZPOST r ON p.ZROOTURI = r.ZURI AND r.ZISROOTPOST=1
   WHERE p.ZISROOTPOST=0 GROUP BY r.ZACCOUNT;"
1|183045
2|19694
4|1171
5|10129
6|11473
sqlite3 "file:default.store?mode=ro"   1.51s user 1.06s system 75% cpu 3.414 total

$ sqlite3 "file:default.store?mode=ro" \
  "EXPLAIN QUERY PLAN SELECT r.ZACCOUNT, COUNT(DISTINCT p.ZAUTHORDID) FROM ZPOST p
   JOIN ZPOST r ON p.ZROOTURI = r.ZURI AND r.ZISROOTPOST=1
   WHERE p.ZISROOTPOST=0 GROUP BY r.ZACCOUNT;"
QUERY PLAN
|--SCAN r USING INDEX ZPOST_ZACCOUNT_INDEX
|--BLOOM FILTER ON p (ZISROOTPOST=? AND ZROOTURI=?)
|--SEARCH p USING AUTOMATIC PARTIAL COVERING INDEX (ZISROOTPOST=? AND ZROOTURI=?)
`--USE TEMP B-TREE FOR count(DISTINCT)

$ sqlite3 "file:default.store?mode=ro" \
  "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='ZPOST';"
ZPOST_ZACCOUNT_INDEX
```

3.41s (vs. the 6.35s measured 2026-08-07 — the earlier number is the recorded baseline
for the plan; the delta is consistent with page-cache warmth and store growth between
runs, not with any index change: `sqlite_master` still lists only `ZPOST_ZACCOUNT_INDEX`).
The "automatic partial covering index" SQLite builds on the fly for this join is a
transient, in-memory structure recomputed per query — not a persistent index — which is
exactly the cost route 2 removes.

## Fixture-level before/after (illustrative, matches `IndexPlanTests`)

Before (no relevant indexes), on a two-row fixture matching `ZPOST`'s shape:

```
QUERY PLAN
|--SCAN p
|--BLOOM FILTER ON r (ZISROOTPOST=? AND ZURI=?)
|--SEARCH r USING AUTOMATIC PARTIAL COVERING INDEX (ZISROOTPOST=? AND ZURI=?)
|--USE TEMP B-TREE FOR GROUP BY
`--USE TEMP B-TREE FOR count(DISTINCT)
```

After `CREATE INDEX IDX_ZPOST_ZURI/ZROOTURI/ZAUTHORDID`:

```
QUERY PLAN
|--SCAN p
|--SEARCH r USING INDEX IDX_ZPOST_ZURI (ZURI=?)
|--USE TEMP B-TREE FOR GROUP BY
`--USE TEMP B-TREE FOR count(DISTINCT)
```

The join side switches from an ad-hoc bloom-filter/automatic-index combination to a
direct `SEARCH ... USING INDEX`. `BlueXTests/Services/Stats/IndexPlanTests.swift`
exercises the same before/after against the real `StoreFixture`/`AggregateReader.explainQueryPlan`
path and is part of this commit; it does not exercise the (dead) `@Attribute(.indexed)`
route since there is nothing left to test for it.

## Test run

```
$ xcodegen generate   # confirmed IndexPlanTests.swift present in project.pbxproj (grep -c: 4)
$ xcodebuild test -project BlueX.xcodeproj -scheme BlueXTests \
    -destination 'platform=macOS,arch=arm64' -only-testing:BlueXTests/IndexPlanTests
Test Case '-[BlueXTests.IndexPlanTests testIndexOnRootURIIsUsed]' passed (0.017 seconds).
Test Case '-[BlueXTests.IndexPlanTests testUnindexedFixtureScans]' passed (0.009 seconds).
Test Suite 'IndexPlanTests' passed at 2026-08-10 16:04:35.742.
	 Executed 2 tests, with 0 failures (0 unexpected) in 0.026 (0.027) seconds
** TEST SUCCEEDED **
```

## Schema guard

`AggregateReader.required` already listed `ZAUTHORDID` and `ZROOTURI` for `ZPOST` before
this task (added in Task 2's schema guard). `explainQueryPlan` reads no column the guard
didn't already cover, so `required` needed no extension.
