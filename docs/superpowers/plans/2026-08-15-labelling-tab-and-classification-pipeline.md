# Labelling Tab + Classification Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the in-app manual labelling tab, run Stage 0 (base-rate measurement), and produce the incivility research output — the three implementable-now phases of the classification programme in `docs/proposal/bluex-classification-proposal.tex`.

**Architecture:** Labelling is a new sidebar section in the BlueX app: SwiftData models for batches and human labels, seeded deterministic sampling, SQL pool queries through the existing `AggregateReader`, and a labelling view whose data path is structurally blind to model outputs. Stage 0 and incivility aggregation are small Python tools following the `tools/` conventions.

**Tech Stack:** Swift 5.9 / SwiftUI / SwiftData (app), SQLite read-only via `AggregateReader`, Python 3.13 + pytest (tools).

## Global Constraints

- Deployment target **macOS 14.0**, `SWIFT_VERSION: "5.9"`.
- Store at `/Volumes/Eregion/bluex-data`, overridable by `BLUEX_STORE_DIR`. Python readers open `?mode=ro`, **never `?immutable=1`** (WAL-blind).
- All app-side SQL lives in `BlueX/Services/Stats/`. Every new column a query touches must be added to `AggregateReader.required` (the schema guard).
- **The labelling data path must not fetch model outputs, incivility scores, or moderation labels** — structural blindness, not UI hiding. This is the spec's central integrity requirement.
- **Every label records its sampling frame** (filter, pool size, seed, batch, pass). A label without a frame is unusable for measurement.
- Aggregation and store I/O never run on the MainActor; `Task.isCancelled` checked immediately before **every** state publish (the Task-7b lesson).
- After `xcodegen generate`, verify new files appear in `project.pbxproj` (`grep -c <file>` non-zero). Under `-quiet`, confirm test names appear in output — exit 0 alone is not proof.
- **Tasks touching `BlueX/Data/` or `BlueX/Services/Stats/` must build all four targets** (`BlueX`, `BlueXScrape`, `BlueXAnnotate`, `BlueXAuthors`) — the CLI targets compile those directories and one shipped uncompilable from a green suite before.
- **Watch each new test fail** against a deliberately broken implementation before trusting it (four tests this project wrote passed while unable to fail).
- Wait for builds with `while pgrep -x xcodebuild >/dev/null; do sleep 20; done` — never `pgrep -f "xcodebuild test"` (matches the waiting shell, never exits).
- Do NOT run `tools/install-cli.sh` or `tools/install-jobs.sh` — the nightly launchd agent (03:31) runs from the installed binaries.
- No `git stash`/`checkout`/`restore`/`clean`; never `git add -A`.
- Known pre-existing flake: `BlueskyAPIClientTests.testCreateSessionRateLimited` — report if seen, do not fix.

## Phase map — all steps, and what gates what

| Phase | Content | State |
|---|---|---|
| **A** (Tasks 1–5) | Labelling tab in the app | planned in full below |
| **B** (Task 6) | Stage 0: base-rate measurement + tooling | planned in full below |
| **C** (Task 7) | Incivility weekly aggregation — first research output | planned in full below; independent of A/B |
| **D** | Hate detector pipeline (embeddings → ensemble → abstention → calibration → full-corpus inference) | **separate plan, written after Stage 0** |

**Why D's tasks are not in this document (deliberate, not deferral):** the proposal's Stage 0 exists to *falsify* the architecture — if the base rate is far below ~1%, abstention arithmetic fails and the design changes; the embedding candidates (gensim doc2vec vs multilingual sentence encoder vs TF-IDF member) are chosen by benchmark, not in advance; and score-banded calibration pools need hate scores that do not exist yet. Writing code-level tasks now would encode guesses. Phase D's plan will cover: unsupervised embedding training on the full reply corpus, benchmark-harness extension for embedding candidates (same 5-fold CV + TF-IDF baseline discipline), ensemble training with random-as-negatives, abstention threshold from score-banded calibration batches (drawn through this tab), and the ~4.5 h full-corpus inference run following the incivility runner's conventions (resume, cool-down, honest summaries).

**Scope cuts in v1 pool filters, with reasons:** incivility-band and moderator-label pool filters are **out** — those signals live in JSONL on Eregion, not in the store, so filtering on them needs an ATTACH/import design that Phase D will introduce alongside hate-score bands. A language filter is **out** — `ZPOST` has no language column and `ZANNOTATION` is empty. Stage 0 needs none of these: it is a uniform random draw. v1 filters: uniform-random (first-class), outlet, date range, thread reply-count.

## File Structure

| File | Responsibility |
|---|---|
| `BlueX/Data/LabelBatch.swift` (new) | Batch identity: frame, seed, pool size, drawn URIs, pass number, link to source batch for re-label passes |
| `BlueX/Data/SamplingFrame.swift` (new) | Codable frame + pure pool-predicate description |
| `BlueX/Services/Labelling/LabelSampling.swift` (new) | Seeded deterministic sampling (SplitMix64 + Fisher–Yates), exclusion logic — pure, no I/O |
| `BlueX/Services/Labelling/AgreementMetrics.swift` (new) | Percent agreement + Cohen's κ between two passes — pure |
| `BlueX/Services/Stats/AggregateReader.swift` (modify) | Pool count/draw queries; blind context fetch (post+root+parent, no scores) |
| `BlueX/Data/Annotation.swift` (modify) | Optional human-labelling fields (additive; lightweight migration) |
| `BlueX/ViewModels/LabellingViewModel.swift` (new) | Batch lifecycle, label recording, resume, pass 2, agreement |
| `BlueX/Views/Labelling/LabellingHomeView.swift` (new) | Pool builder, batch list, agreement display |
| `BlueX/Views/Labelling/LabellingSessionView.swift` (new) | The labelling screen — keyboard-driven, blind |
| `BlueX/Views/RootView.swift`, `SidebarView.swift` (modify) | `.labelling` sidebar case |
| `tools/labelling/base_rate.py` (new) | Stage 0: Wilson CI base-rate report from human labels |
| `tools/incivility/aggregate_weekly.py` (new) | Weekly incivility per outlet — the research output |

---

### Task 1: Pure sampling engine — seeded, deterministic, exclusion-aware

**Files:**
- Create: `BlueX/Data/SamplingFrame.swift`
- Create: `BlueX/Services/Labelling/LabelSampling.swift`
- Test: `BlueXTests/Services/Labelling/LabelSamplingTests.swift`

**Interfaces:**
- Consumes: nothing (pure)
- Produces:
  - `struct SamplingFrame: Codable, Equatable { var kind: Kind; var outletPK: Int64?; var dateFrom: Date?; var dateTo: Date?; var minThreadReplies: Int?; var maxThreadReplies: Int?; enum Kind: String, Codable { case uniformRandom, filtered } }`
  - `struct SeededGenerator: RandomNumberGenerator { init(seed: UInt64); mutating func next() -> UInt64 }` (SplitMix64)
  - `enum LabelSampling { static func draw(from pool: [String], excluding drawn: Set<String>, count: Int, seed: UInt64) -> [String] }`

- [ ] **Step 1: Write the failing tests**

```swift
// BlueXTests/Services/Labelling/LabelSamplingTests.swift
import XCTest
@testable import BlueX

final class LabelSamplingTests: XCTestCase {
    func testSameSeedSameDraw() {
        let pool = (0..<1000).map { "at://p/\($0)" }
        let a = LabelSampling.draw(from: pool, excluding: [], count: 100, seed: 42)
        let b = LabelSampling.draw(from: pool, excluding: [], count: 100, seed: 42)
        XCTAssertEqual(a, b, "identical seed must reproduce the identical draw, in order")
    }

    func testDifferentSeedDifferentDraw() {
        let pool = (0..<1000).map { "at://p/\($0)" }
        XCTAssertNotEqual(LabelSampling.draw(from: pool, excluding: [], count: 100, seed: 1),
                          LabelSampling.draw(from: pool, excluding: [], count: 100, seed: 2))
    }

    func testExcludedURIsNeverDrawn() {
        let pool = (0..<50).map { "at://p/\($0)" }
        let drawn = Set(pool.prefix(40))
        let result = LabelSampling.draw(from: pool, excluding: drawn, count: 100, seed: 7)
        XCTAssertEqual(Set(result).intersection(drawn), [])
        XCTAssertEqual(result.count, 10, "only the 10 undrawn remain")
    }

    func testNoDuplicatesInDraw() {
        let pool = (0..<500).map { "at://p/\($0)" }
        let result = LabelSampling.draw(from: pool, excluding: [], count: 200, seed: 9)
        XCTAssertEqual(Set(result).count, result.count)
    }

    func testDrawIsOrderInsensitiveToPoolOrder() {
        // The pool arrives from SQL; row order is not guaranteed. The draw must not
        // depend on it, or "same seed" silently stops meaning "same sample".
        let pool = (0..<300).map { "at://p/\($0)" }
        let a = LabelSampling.draw(from: pool, excluding: [], count: 50, seed: 3)
        let b = LabelSampling.draw(from: pool.shuffled(), excluding: [], count: 50, seed: 3)
        XCTAssertEqual(a, b)
    }

    func testEmptyPoolAndOversizedCount() {
        XCTAssertEqual(LabelSampling.draw(from: [], excluding: [], count: 10, seed: 1), [])
        let pool = ["at://p/1", "at://p/2"]
        XCTAssertEqual(Set(LabelSampling.draw(from: pool, excluding: [], count: 10, seed: 1)), Set(pool))
    }
}
```

- [ ] **Step 2: Run to verify failure** (`-only-testing:BlueXTests/LabelSamplingTests`) — FAIL: types not found.

- [ ] **Step 3: Implement**

```swift
// BlueX/Data/SamplingFrame.swift
import Foundation

/// The recorded provenance of a labelling batch. A label without its frame is unusable
/// for measurement: labels from a filtered pool and a uniform draw are indistinguishable
/// afterwards, and any prevalence estimate across them is silently biased.
struct SamplingFrame: Codable, Equatable {
    enum Kind: String, Codable { case uniformRandom, filtered }
    var kind: Kind
    var outletPK: Int64?
    var dateFrom: Date?
    var dateTo: Date?
    var minThreadReplies: Int?
    var maxThreadReplies: Int?

    static let uniformRandom = SamplingFrame(kind: .uniformRandom, outletPK: nil,
        dateFrom: nil, dateTo: nil, minThreadReplies: nil, maxThreadReplies: nil)

    var isUniformRandom: Bool { self == .uniformRandom }
}
```

```swift
// BlueX/Services/Labelling/LabelSampling.swift
import Foundation

/// SplitMix64 — deterministic across runs and platforms, unlike
/// SystemRandomNumberGenerator, which is unseedable by design. Determinism is a spec
/// requirement: the recorded seed must reproduce the draw.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

enum LabelSampling {
    /// Deterministic sample of `count` URIs. Sorts the pool first so the result depends
    /// only on (pool contents, exclusions, count, seed) — never on SQL row order.
    static func draw(from pool: [String], excluding drawn: Set<String>,
                     count: Int, seed: UInt64) -> [String] {
        var candidates = pool.filter { !drawn.contains($0) }.sorted()
        guard candidates.count > count else { return candidates }
        var rng = SeededGenerator(seed: seed)
        // Partial Fisher–Yates: fix positions 0..<count.
        for i in 0..<count {
            let j = Int(rng.next() % UInt64(candidates.count - i)) + i
            candidates.swapAt(i, j)
        }
        return Array(candidates.prefix(count))
    }
}
```

- [ ] **Step 4: Run tests to green.**
- [ ] **Step 5: Discrimination check** — temporarily break the sort (remove `.sorted()`), confirm `testDrawIsOrderInsensitiveToPoolOrder` fails; restore. Record in report.
- [ ] **Step 6: `xcodegen generate`, verify pbxproj, build all four targets** (new file under `BlueX/Services/` — CLI targets may compile it if their source lists glob; verify rather than assume).
- [ ] **Step 7: Commit** (`feat(labelling): seeded deterministic sampling engine`).

---

### Task 2: Data model — `LabelBatch` and human-label fields on `Annotation`

**Files:**
- Create: `BlueX/Data/LabelBatch.swift`
- Modify: `BlueX/Data/Annotation.swift` (additive optional fields only)
- Modify: `BlueX/Data/BlueXSchema.swift` (register `LabelBatch`)
- Test: `BlueXTests/Data/LabelBatchTests.swift`

**Interfaces:**
- Consumes: `SamplingFrame` (Task 1)
- Produces:
  - `@Model final class LabelBatch { var id: UUID; var createdAt: Date; var frameJSON: String; var poolSizeAtDraw: Int; var seed: UInt64 → stored as Int64 bitPattern; var drawnURIs: [String]; var labelledURIs: [String]; var passNumber: Int; var sourceBatchID: UUID?; var completedAt: Date? }` with `var frame: SamplingFrame?` (decoded accessor) and `init(frame:poolSizeAtDraw:seed:drawnURIs:passNumber:sourceBatchID:)`
  - On `Annotation`: `var annotatorID: String?; var batchID: UUID?; var timeToDecideSeconds: Double?; var passNumber: Int?` — all optional, nil for every existing row.

**Key facts for the implementer:**
- Adding optional fields is a **lightweight migration**. Measured on this project: migrations silently drop hand-created indexes — which is exactly why `IndexReasserter` (already wired into `BlueXStore.openContainer()`) exists. No extra work needed; state in the report that this interaction was considered.
- `seed` stores as `Int64(bitPattern:)` — SwiftData/Core Data has no unsigned integer storage. The accessor converts back via `UInt64(bitPattern:)`.
- `frameJSON` is the canonical stored form (SwiftData cannot query into Codable blobs, and we never need to — batches are enumerated, not filtered by frame).

- [ ] **Step 1: Failing tests** — round-trip a `LabelBatch` through a **file-backed** container (in-memory hides migration behaviour): frame decodes equal, seed survives bit-pattern round-trip including values > `Int64.max`, `drawnURIs` order preserved, `sourceBatchID` links pass 2 to pass 1. Plus: an existing `Annotation` created without the new fields reads back with all four nil.
- [ ] **Step 2: Verify failure.**
- [ ] **Step 3: Implement** both models; register in `BlueXSchema.all`.
- [ ] **Step 4: Green.**
- [ ] **Step 5: Build ALL FOUR targets** — `BlueX/Data/` is compiled by every CLI target; this is the task most likely to break `blueX-scrape`'s build. Non-negotiable.
- [ ] **Step 6: Commit** (`feat(labelling): LabelBatch model and human-label fields on Annotation`).

---

### Task 3: Blind pool queries in `AggregateReader`

**Files:**
- Modify: `BlueX/Services/Stats/AggregateReader.swift`
- Modify: `BlueXTests/Services/Stats/StoreFixture.swift` (add a depth-2 reply whose parent ≠ root)
- Test: `BlueXTests/Services/Stats/AggregateReaderLabellingTests.swift`

**Interfaces:**
- Consumes: `SamplingFrame` (Task 1)
- Produces on `AggregateReader`:
  - `func labellingPoolCount(frame: SamplingFrame) throws -> Int`
  - `func labellingPoolURIs(frame: SamplingFrame) throws -> [String]`
  - `struct LabellingContext { let uri: String; let text: String; let createdAt: Date; let authorHandle: String; let rootURI: String; let rootText: String; let rootHandle: String; let parentURI: String?; let parentText: String?; let parentHandle: String? }` — **deliberately contains no score, no label, no model field; this struct is the structural-blindness guarantee**
  - `func labellingContext(uris: [String]) throws -> [LabellingContext]` (parent fields nil when parent == root)

**SQL sketch (frame → WHERE):** pool = replies (`ZISROOTPOST = 0`), joined to root for outlet/thread-size filters exactly as `rootPosts` does; uniformRandom = no extra predicate. Context fetch: reply row + root row via `ZROOTURI = r.ZURI`, parent row via `ZPARENTURI` **only when `ZPARENTURI != ZROOTURI`** (78% of replies are depth-1; measured, and the fixture must cover both cases). Add `ZPARENTURI` to `AggregateReader.required["ZPOST"]` — it is not currently guarded.

- [ ] **Step 1: Failing tests** — uniform pool counts all replies in fixture; outlet filter narrows correctly; thread-size filter uses `HAVING` on the root's reply count; context for a depth-1 reply has nil parent fields; context for the new depth-2 fixture reply carries the parent's text; **a structural test asserting `LabellingContext` exposes no member whose name contains "score"/"label"/"class" via `Mirror`** (crude but it fails loudly if someone adds one); unknown URI yields no row rather than throwing.
- [ ] **Step 2: Verify failure.** **Step 3: Implement.** **Step 4: Green; run full `AggregateReaderSchemaTests` too (the `required` map changed).**
- [ ] **Step 5: Sanity-check against the live store** (`?mode=ro`): `labellingPoolCount(.uniformRandom)` should be ≈ the current reply count (~2.13M); report the observed number.
- [ ] **Step 6: Commit** (`feat(labelling): blind pool + context queries`).

---

### Task 4: `LabellingViewModel` — batch lifecycle, recording, resume, pass 2, agreement

**Files:**
- Create: `BlueX/ViewModels/LabellingViewModel.swift`
- Create: `BlueX/Services/Labelling/AgreementMetrics.swift`
- Test: `BlueXTests/ViewModels/LabellingViewModelTests.swift`, `BlueXTests/Services/Labelling/AgreementMetricsTests.swift`

**Interfaces:**
- Consumes: Tasks 1–3, `ModelContainer`, `Decimator`-style patterns from `AuthorStatsViewModel` (cancellation, store-failure states, `@MainActor` isolation with `Task.detached` for I/O)
- Produces (`@MainActor @Observable final class LabellingViewModel`):
  - `func createBatch(frame: SamplingFrame, size: Int, reader: AggregateReader) async` — pool count, fresh random seed (recorded), `LabelSampling.draw` excluding all URIs in any existing batch, persist `LabelBatch`
  - `func openBatch(_ id: UUID, reader: AggregateReader) async` — loads contexts for **unlabelled** URIs first (resume), shuffled per-session for pass 2 so presentation order differs
  - `func record(_ speechClass: String, note: String?, context: ModelContext)` — writes `Annotation(stage: "human")` with `annotatorID`, `batchID`, `passNumber`, `timeToDecideSeconds` (measured from item presentation, injectable clock), appends to `labelledURIs`, advances; sets `completedAt` on the last item
  - `func createSecondPass(of batchID: UUID, context: ModelContext) throws -> UUID` — same URIs, `passNumber: 2`, `sourceBatchID` set; **prior labels are never loaded into the session**
  - `func agreement(batchID: UUID, context: ModelContext) throws -> AgreementReport?` — pairs pass-1/pass-2 labels by URI, returns percent agreement + Cohen's κ
  - `enum LoadState { idle, loading, loaded, failed(String) }` — store-open failure is `.failed`, never an empty pool; empty pool (`poolCount == 0`) and exhausted pool (all drawn) are distinct, named states.

```swift
// BlueX/Services/Labelling/AgreementMetrics.swift — pure, hand-testable
import Foundation

struct AgreementReport: Equatable {
    let n: Int
    let percentAgreement: Double
    let cohensKappa: Double   // between the two passes of the same annotator:
                              // intra-rater kappa. Weaker than inter-rater; report as such.
}

enum AgreementMetrics {
    /// κ = (p_o − p_e) / (1 − p_e); p_e from each pass's marginal class distribution.
    /// Returns kappa = 1 when both passes agree perfectly even if p_e == 1 (single
    /// class used throughout) — that degenerate case must not divide by zero.
    static func compute(pass1: [String: String], pass2: [String: String]) -> AgreementReport? {
        let keys = Set(pass1.keys).intersection(pass2.keys)
        guard !keys.isEmpty else { return nil }
        let pairs = keys.map { (pass1[$0]!, pass2[$0]!) }
        let n = Double(pairs.count)
        let po = Double(pairs.filter { $0.0 == $0.1 }.count) / n
        let classes = Set(pairs.flatMap { [$0.0, $0.1] })
        let pe = classes.reduce(0.0) { acc, c in
            let m1 = Double(pairs.filter { $0.0 == c }.count) / n
            let m2 = Double(pairs.filter { $0.1 == c }.count) / n
            return acc + m1 * m2
        }
        let kappa = pe >= 1.0 ? (po >= 1.0 ? 1.0 : 0.0) : (po - pe) / (1 - pe)
        return AgreementReport(n: pairs.count, percentAgreement: po, cohensKappa: kappa)
    }
}
```

- [ ] **Step 1: Failing tests.** Agreement: a hand-worked 10-item example with known κ (compute by hand in the test comment); perfect agreement → κ=1; the single-class degenerate case; disjoint URI sets → nil. ViewModel (file-backed fixture store + real reader): create-batch records frame/seed/pool-size and excludes previously drawn URIs across batches; resume opens only unlabelled items; `record` persists all four new Annotation fields and `stage == "human"`; second pass never exposes pass-1 labels (assert the session's items carry no label data); store-open failure → `.failed` with pool untouched; time-to-decide uses the injected clock.
- [ ] **Step 2: Verify failure.** **Step 3: Implement** (I/O in `Task.detached`; `Task.isCancelled` before every publish; follow `AuthorStatsViewModel` patterns exactly).
- [ ] **Step 4: Green.** **Step 5: Discrimination check on the blindness test** — temporarily make the session fetch prior labels, confirm the test fails, restore. Record.
- [ ] **Step 6: Commit** (`feat(labelling): view model — batches, recording, blind second pass, intra-rater agreement`).

---

### Task 5: Views and navigation

**Files:**
- Create: `BlueX/Views/Labelling/LabellingHomeView.swift`, `BlueX/Views/Labelling/LabellingSessionView.swift`
- Modify: `BlueX/Views/RootView.swift` (`SidebarItem.labelling` + routing), `BlueX/Views/Sidebar/SidebarView.swift` (entry "Labelling", `systemImage: "tag"`)
- Test: `BlueXTests/Views/LabellingFormattingTests.swift` (any extracted pure formatting)

**Requirements (structure, matching the app's existing idioms — colours from `BlueXColors.swift` only):**

*Home (content column):* pool builder — a **"Uniform random (Stage 0)" preset button first**, then optional outlet/date/thread-size filters; live matching count via `labellingPoolCount` (debounced, off-main-actor); batch size field (default 100); create button. Below: batch list (frame summary, progress `labelled/drawn`, pass number, created date), with actions: continue, create second pass (only when complete), show agreement (only when a pass-2 exists and is complete). Distinct empty states: "no store" (`.failed` banner), "filter matches nothing", "pool exhausted — all matching posts already drawn".

*Session (detail column):* progress (`item k of n`, elapsed); the **root post** (outlet handle + text), the **parent** when different, the **reply** prominently; class buttons `1 = hate`, `2 = counter`, `3 = neutral`, `0 = skip` (skip advances without an Annotation and leaves the URI unlabelled for resume); optional note field (does not steal number-key focus — notes begin with an explicit shortcut, `⌘N`); auto-advance on keypress; a visible "labels are recorded immediately; you can stop at any time" hint. **Nothing on this screen shows or fetches any score or model output** — it renders `LabellingContext` only.

- [ ] Steps: implement; `xcodegen generate` + pbxproj verify; unit-test extracted formatting; **build the `BlueX` app target**; full suite; state plainly in the report what is inspection-only (all SwiftUI wiring). Commit (`feat(labelling): labelling tab UI`).

---

### Task 6 (Phase B): Stage 0 tooling — base-rate report

**Files:**
- Create: `tools/labelling/base_rate.py`, `tools/labelling/test_base_rate.py`

**Interfaces:** reads the store `?mode=ro`: human annotations (`ZANNOTATION` where `ZSTAGE='human'`) joined to their batch (`ZLABELBATCH`) — **only batches whose frame is `uniformRandom` and `passNumber == 1` enter the estimate**; other frames are listed separately and excluded, with the exclusion printed (the sampling-frame discipline made machine-checkable).

Output (stdout + timestamped file in `/Volumes/Eregion/bluex-labelling/`): n, hate count, counter count, neutral count, skipped; hate prevalence with **Wilson 95% CI**:

```python
def wilson_ci(k: int, n: int, z: float = 1.96) -> tuple[float, float]:
    if n == 0: return (0.0, 0.0)
    p = k / n
    denom = 1 + z*z/n
    centre = (p + z*z/(2*n)) / denom
    half = (z / denom) * math.sqrt(p*(1-p)/n + z*z/(4*n*n))
    return (max(0.0, centre-half), min(1.0, centre+half))
```

Plus the decision rule from the proposal printed alongside: the estimated false-positives-per-true-positive at the prior work's τ=0.9 operating point (5% of neutral classified, 88% recall), so the number is interpreted, not just reported. Tests: Wilson CI against hand-worked values (k=3,n=300 → ~(0.34%, 2.9%)); non-uniform frames excluded; pass-2 labels excluded; empty store → clear message, exit non-zero.

- [ ] Steps: tests fail → implement → green → commit (`feat(labelling): Stage 0 base-rate report`). **Running Stage 0 itself is attended:** the user labels ~300 uniform-random items in the tab (≈1–2 h at their pace), then this script runs. The plan's execution ends by handing that to the user.

---

### Task 7 (Phase C): Incivility weekly aggregation — the first research output

**Files:**
- Create: `tools/incivility/aggregate_weekly.py`, `tools/incivility/test_aggregate_weekly.py`

**Interfaces:** inputs = the completed scores JSONL (`/Volumes/Eregion/bluex-incivility/incivility-scores-*.jsonl`, fields `uri, head, score`; two heads per post — use `toxicity`) + the store `?mode=ro` (reply → root → outlet via `ZROOTURI`/`ZACCOUNT`, ISO-week from `ZCREATEDAT` + 978307200). Output: timestamped CSV (`outlet, iso_week, n_scored, n_replies_total, mean_toxicity, p50, p90, share_over_050`) + a Markdown summary, written to `/Volumes/Eregion/bluex-incivility/`.

**Honesty requirements (from the measured record):** the header of both outputs must state that this measures **incivility, not hate** (anti-correlated, AUC 0.198 — cite the note), that `share_over_050` uses an arbitrary illustrative threshold pending calibration, and that weeks where `n_scored < n_replies_total` (posts scraped after the scoring run) are marked with a coverage column rather than silently mixed. Unscored replies must **never** be treated as score-0.

- [ ] Steps: tests (bucketing to ISO weeks incl. year boundary; outlet attribution via fixture sqlite; unscored-reply exclusion + coverage column; head selection ignores `identity_attack`) → implement → green → run against the real data, report the actual table → commit (`feat(incivility): weekly per-outlet aggregation`).

---

## Execution order

**1 → 2 → 3 → 4 → 5** (the tab, strictly sequential — shared files), then **6** and **7** (independent of each other). Stage 0's actual labelling session is the user's, then `base_rate.py` gates Phase D's plan.

## Self-review notes

- Spec coverage: every 2026-08-13 spec requirement maps to a task (frame recording → T1/T2; blindness → T3 struct + T4/T5 tests; resume/re-label/agreement → T4; distinct empty states → T5; uniform-random first-class → T3/T5; severity stays out per spec).
- The `Mirror`-based blindness test is crude; its real guarantee is the `LabellingContext` struct itself — the test just makes weakening it loud.
- Type consistency checked: `SamplingFrame` produced in T1 is consumed by T2 (`frameJSON`), T3 (SQL predicate), T4 (creation), T6 (uniform-only filter in Python via the JSON `kind` field — document the exact JSON key names in T2's code comments so the Python side matches).
