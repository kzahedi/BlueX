# BlueX Nightly Scrape + Apple Sentiment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore unattended nightly Bluesky scraping on `macmini.local` and replace the phi4:14b LLM annotation pass with Apple's free on-device NLTagger sentiment.

**Architecture:** Nothing on the runtime path may live on `/Volumes/Eregion` — launchd fires these jobs during DarkWake, when that external volume is unmounted (the cause of the 61-day outage from 2026-06-04). The repo stays the source of truth; `install-jobs.sh` copies job scripts to the internal disk. Two user LaunchAgents do everything — nightly at 03:31, watchdog at 06:56. No privileged component: the mini is set to never idle-sleep (`sleep 0`), so launchd fires the agent while it is awake and no `pmset` wake is needed.

**Tech Stack:** Swift 5.9 / SwiftData / `NaturalLanguage` (macOS 14 deployment target, running on macOS 26.5.1), zsh job scripts, launchd, `pmset`, XcodeGen 2.46.0, pytest for the guard tests.

**Spec:** `docs/superpowers/specs/2026-08-04-bluex-scrape-and-sentiment-design.md`

## Global Constraints

- **Job scripts live on the internal disk and must never *assume* `/Volumes/Eregion` is mounted.** launchd execs them and can fire during DarkWake, when that volume is absent — the outage. Scripts wait for the mount with a bounded timeout, then notify and exit. Guarded by a test in Task 7.
- **The store lives at `/Volumes/Eregion/bluex-data/default.store`** (moved 2026-08-04 on request; the internal disk is at 96%). Overridable via the `BLUEX_STORE_DIR` environment variable. Only the *data* moves — never the scripts.
- **Deployment target `14.0`, `SWIFT_VERSION: "5.9"`** for all targets (`project.yml`).
- **`AnnotationService.swift` is excluded from the `BlueXAnnotate` target** (`project.yml:64-66`). CLI-visible code must not live in that file.
- **Annotation stage string is exactly `"nltagger"`** — matches `Post+Annotations.swift` and the `--reset-annotations` vocabulary.
- **`pmset schedule` requires root.** Verified: `pmset: This operation must be run as root`, exit 1.
- **Only one `pmset repeat` pair exists per machine** and the user's `wakepoweron at 6:55AM` occupies it. Never call `pmset repeat`.
- **Do not change any `pmset` power setting**, including the 06:55 repeating wake.
- **Store path:** `/Volumes/Eregion/bluex-data/default.store`. Pre-move backup of the old internal store: `~/Library/Application Support/BlueX/default.store.pre-sdd-2026-08-04`.
- **Schemes:** `BlueX`, `BlueXAnnotate`, `BlueXScrape`. There is no `BlueXTests` scheme — tests run under the `BlueX` scheme.
- **Run `xcodegen generate` after adding or removing any source file**, or Xcode will not see it.
- Never commit to `main`. Work on branch `fix/nightly-scrape-and-sentiment`.

## File Structure

| File | Responsibility |
|---|---|
| `BlueX/Services/Annotation/NLTaggerPass.swift` | **new** — paged NLTagger sentiment pass. Plain struct, no `Observation`, no `@MainActor`, so the CLI target can compile it |
| `BlueX/Services/Annotation/AnnotationService.swift` | **modify** — delegate `runNLTaggerPass` to `NLTaggerPass`, keep `@Observable` progress publishing |
| `BlueXTests/Services/NLTaggerPassTests.swift` | **new** — paging, skip-already-done, limit, progress |
| `cli/annotate/main.swift` | **modify** — add `--pass nltagger` |
| `BlueX/Data/BlueXSchema.swift` | **modify** — store moves to Eregion; throws `volumeNotMounted` instead of silently creating an empty store |
| `BlueXTests/Data/BlueXStoreTests.swift` | **new** — `BLUEX_STORE_DIR` override, and a missing volume throws rather than creating a store |
| `tools/install-cli.sh` | **modify** — build to a stable `-derivedDataPath` that survives an Xcode clean |
| `tools/jobs/lib-bluex-job.sh` | **new** — shared paths, notifications, file-age helper |
| `tools/jobs/bluex-nightly.sh` | **new** — the nightly run + `--preflight` |
| `tools/jobs/bluex-watchdog.sh` | **new** — staleness notification |
| `tools/jobs/test_jobs.py` | **new** — guard tests |
| `tools/install-jobs.sh` | **new** — installs everything, retires the old agents |
| `tools/blueX-scrape-job.sh`, `tools/blueX-annotate-job.sh` | **delete** — superseded |

---

### Task 1: Extract a paged `NLTaggerPass`

The existing pass fetches all 797,253 posts and tests `post.hasNLTaggerAnnotation`, faulting each post's relationship. It cannot complete the ~794,700-post backfill. Extracting it also makes it compilable in the CLI target.

**Files:**
- Create: `BlueX/Services/Annotation/NLTaggerPass.swift`
- Modify: `BlueX/Services/Annotation/AnnotationService.swift:22` and `:39-96`
- Test: `BlueXTests/Services/NLTaggerPassTests.swift`

**Interfaces:**
- Consumes: `NLTaggerAnalyser.analyse(text:) -> Annotation` (existing), `Post.uri`, `Post.text`, `Annotation.stage`, `Annotation.post`
- Produces: `NLTaggerPass(container: ModelContainer)` with
  `run(batchSize: Int = 200, limit: Int? = nil, isCancelled: () -> Bool = { false }, progress: ((Int, Int) -> Void)? = nil) throws -> Int`
  returning the number of posts annotated. Task 2 calls this directly.

- [ ] **Step 1: Write the failing tests**

Create `BlueXTests/Services/NLTaggerPassTests.swift`:

```swift
// BlueXTests/Services/NLTaggerPassTests.swift
import XCTest
import SwiftData
@testable import BlueX

final class NLTaggerPassTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: Post.self, Annotation.self, TrackedAccount.self, AccountGroup.self,
            ScrapeLog.self, CoordinatorState.self, AccountSnapshot.self, ModelConfig.self,
            configurations: config
        )
    }

    private func insertPosts(_ n: Int, in container: ModelContainer) throws {
        let context = ModelContext(container)
        for i in 0..<n {
            let uri = String(format: "at://test/%03d", i)
            let post = Post(uri: uri,
                            text: "Ein ganz normaler Beitrag Nummer \(i)",
                            createdAt: Date(timeIntervalSince1970: Double(1_700_000_000 + i)),
                            authorDID: "did:test", authorHandle: "test.bsky.social",
                            parentURI: nil, rootURI: uri,
                            isRootPost: true, depth: 0)
            context.insert(post)
        }
        try context.save()
    }

    // batchSize deliberately smaller than the post count: the old implementation
    // never paged, so this is the regression that matters.
    func testAnnotatesEveryPostAcrossPageBoundaries() throws {
        let container = try makeContainer()
        try insertPosts(5, in: container)

        let annotated = try NLTaggerPass(container: container).run(batchSize: 2)

        XCTAssertEqual(annotated, 5)
        let fresh = ModelContext(container)
        let posts = try fresh.fetch(FetchDescriptor<Post>())
        XCTAssertEqual(posts.count, 5)
        for post in posts {
            XCTAssertEqual(post.annotations.filter { $0.stage == "nltagger" }.count, 1,
                           "post \(post.uri) should have exactly one nltagger annotation")
        }
    }

    func testSkipsPostsThatAlreadyHaveAnNLTaggerAnnotation() throws {
        let container = try makeContainer()
        try insertPosts(5, in: container)

        XCTAssertEqual(try NLTaggerPass(container: container).run(batchSize: 2), 5)
        XCTAssertEqual(try NLTaggerPass(container: container).run(batchSize: 2), 0,
                       "a second pass must be a no-op")

        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<Annotation>()).count, 5,
                       "second pass must not duplicate annotations")
    }

    func testRespectsLimit() throws {
        let container = try makeContainer()
        try insertPosts(5, in: container)

        let annotated = try NLTaggerPass(container: container).run(batchSize: 2, limit: 3)

        XCTAssertEqual(annotated, 3)
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<Annotation>()).count, 3)
    }

    func testReportsProgress() throws {
        let container = try makeContainer()
        try insertPosts(4, in: container)

        var updates: [(Int, Int)] = []
        _ = try NLTaggerPass(container: container).run(batchSize: 2) { done, total in
            updates.append((done, total))
        }

        XCTAssertEqual(updates.first?.0, 0, "should report 0 before any work")
        XCTAssertEqual(updates.last?.0, 4, "should report the final count")
        XCTAssertEqual(updates.last?.1, 4, "estimated total should be the pending count")
    }

    func testStopsWhenCancelled() throws {
        let container = try makeContainer()
        try insertPosts(6, in: container)

        var pages = 0
        let annotated = try NLTaggerPass(container: container).run(
            batchSize: 2,
            isCancelled: { pages >= 1 },
            progress: { _, _ in pages += 1 }
        )

        XCTAssertLessThan(annotated, 6, "cancellation should stop the pass early")
    }
}
```

- [ ] **Step 2: Regenerate the project so Xcode sees the new files**

Run: `cd /Volumes/Eregion/projects/bluex-v2 && xcodegen generate`
Expected: `Created project at BlueX.xcodeproj`

- [ ] **Step 3: Run the tests to verify they fail**

Run:
```bash
cd /Volumes/Eregion/projects/bluex-v2
xcodebuild test -project BlueX.xcodeproj -scheme BlueX \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:BlueXTests/NLTaggerPassTests 2>&1 | tail -30
```
Expected: FAIL — `cannot find 'NLTaggerPass' in scope`

- [ ] **Step 4: Create `NLTaggerPass`**

Create `BlueX/Services/Annotation/NLTaggerPass.swift`:

```swift
// BlueX/Services/Annotation/NLTaggerPass.swift
import Foundation
import SwiftData

/// Applies Apple's on-device NLTagger sentiment to every post lacking an "nltagger"
/// annotation.
///
/// Deliberately plain — no Observation, no @MainActor — because project.yml excludes
/// AnnotationService.swift from the BlueXAnnotate target, so the CLI cannot use that
/// class. Both the GUI service and blueX-annotate call this instead: one
/// implementation, two consumers.
///
/// Paging is the point. The store holds ~797k posts; the previous implementation
/// fetched all of them and then tested `post.hasNLTaggerAnnotation`, which faults
/// each post's `annotations` relationship. That is why a full backfill never
/// completed.
struct NLTaggerPass {
    private let container: ModelContainer
    private let tagger = NLTaggerAnalyser()

    init(container: ModelContainer) {
        self.container = container
    }

    /// Annotates pending posts and returns how many were written.
    ///
    /// - Parameters:
    ///   - batchSize: posts fetched and saved per page.
    ///   - limit: stop after this many annotations. Needed to measure throughput
    ///     before committing to a full-corpus run.
    ///   - isCancelled: polled once per page.
    ///   - progress: called after each page with (annotatedSoFar, estimatedTotal).
    @discardableResult
    func run(batchSize: Int = 200,
             limit: Int? = nil,
             isCancelled: () -> Bool = { false },
             progress: ((Int, Int) -> Void)? = nil) throws -> Int {

        // URIs that already carry an nltagger annotation. One cheap fetch (2,600 rows
        // today) instead of faulting 797k relationships — the same `alreadyDone`
        // pattern already proven at cli/annotate/main.swift:361-370.
        let indexContext = ModelContext(container)
        let doneURIs: Set<String> = Set(
            try indexContext.fetch(FetchDescriptor<Annotation>(
                predicate: #Predicate<Annotation> { $0.stage == "nltagger" }
            )).compactMap { $0.post?.uri }
        )

        let postCount = try indexContext.fetchCount(FetchDescriptor<Post>())
        let estimatedTotal = limit ?? max(0, postCount - doneURIs.count)
        progress?(0, estimatedTotal)

        var offset = 0
        var annotated = 0

        while offset < postCount {
            if isCancelled() { break }
            if let limit, annotated >= limit { break }

            // A fresh context per page keeps the object graph bounded. One long-lived
            // context would end up registering all 797k posts.
            let context = ModelContext(container)
            var page = FetchDescriptor<Post>(sortBy: [SortDescriptor(\Post.uri)])
            page.fetchOffset = offset
            page.fetchLimit = batchSize
            let posts = try context.fetch(page)
            if posts.isEmpty { break }
            // Inserting annotations never changes the Post count, so advancing the
            // offset by the page size stays correct across iterations.
            offset += posts.count

            var insertedThisPage = 0
            for post in posts {
                if let limit, annotated >= limit { break }
                guard !doneURIs.contains(post.uri) else { continue }
                let annotation = tagger.analyse(text: post.text)
                context.insert(annotation)
                annotation.post = post
                annotated += 1
                insertedThisPage += 1
            }
            if insertedThisPage > 0 { try context.save() }
            progress?(annotated, estimatedTotal)
        }

        return annotated
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run:
```bash
cd /Volumes/Eregion/projects/bluex-v2
xcodegen generate
xcodebuild test -project BlueX.xcodeproj -scheme BlueX \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:BlueXTests/NLTaggerPassTests 2>&1 | tail -30
```
Expected: PASS — 5 tests

- [ ] **Step 6: Delegate `AnnotationService` to the new type**

In `BlueX/Services/Annotation/AnnotationService.swift`, delete the now-unused tagger property on line 22:

```swift
    private let nlTagger = NLTaggerAnalyser()
```

Then replace the whole body of `runNLTaggerPass` (lines 39-96, from `@MainActor` through the closing brace of the `for try await` loop) with:

```swift
    @MainActor
    func runNLTaggerPass(batchSize: Int = 200, limit: Int? = nil) async throws {
        isRunning = true
        passLabel = "Apple sentiment"
        queueSize = 0
        processedCount = 0
        etaSeconds = nil
        defer {
            isRunning = false
            passLabel = ""
            etaSeconds = nil
        }

        // Capture only Sendable values for the detached task — @Model instances are
        // confined to the context where they were fetched and must not escape.
        let container = modelContainer

        let stream = AsyncThrowingStream<(Int, Int, Double?), Error> { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    let runStart = Date()
                    let pass = NLTaggerPass(container: container)
                    _ = try pass.run(batchSize: batchSize, limit: limit) { done, total in
                        let eta = Self.etaFromRunningAverage(
                            start: runStart, processed: done, total: total
                        )
                        continuation.yield((done, total, eta))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }

        for try await (processed, total, eta) in stream {
            queueSize = total
            processedCount = processed
            etaSeconds = eta
        }
    }
```

- [ ] **Step 7: Run the full test suite to confirm the GUI path still works**

Run:
```bash
cd /Volumes/Eregion/projects/bluex-v2
xcodebuild test -project BlueX.xcodeproj -scheme BlueX \
  -destination 'platform=macOS,arch=arm64' 2>&1 | tail -30
```
Expected: PASS — including the pre-existing `ScrapeCoordinatorAnnotationTests.testNLTaggerAnnotationCreatesSentimentAnnotation`

- [ ] **Step 8: Commit**

```bash
cd /Volumes/Eregion/projects/bluex-v2
git add BlueX/Services/Annotation/NLTaggerPass.swift \
        BlueX/Services/Annotation/AnnotationService.swift \
        BlueXTests/Services/NLTaggerPassTests.swift \
        BlueX.xcodeproj
git commit -m "refactor(annotation): extract paged NLTaggerPass

The old pass fetched all 797k posts and tested hasNLTaggerAnnotation, faulting
each post's relationship — it could not finish the ~795k backfill. NLTaggerPass
indexes done URIs with one cheap Annotation fetch, then pages Post with
fetchLimit/fetchOffset using a fresh context per page.

Extracted as a plain struct because project.yml excludes AnnotationService.swift
from the BlueXAnnotate target. Adds a limit parameter so throughput can be
measured before a full-corpus run."
```

---

### Task 2: Add `--pass nltagger` to `blueX-annotate`

**Files:**
- Modify: `cli/annotate/main.swift:20-23` (enum), `:99-107` (parsing), `:161-168` (usage), and a new dispatch block before `// ---- pick model` at `:313`

**Interfaces:**
- Consumes: `NLTaggerPass.run(batchSize:limit:isCancelled:progress:)` from Task 1; `BlueXStore.openContainer()`; `fail(_:_:)` from `cli/Shared/CLISupport.swift`
- Produces: the CLI invocation `blueX-annotate --pass nltagger [--limit N]` used by Task 5

- [ ] **Step 1: Extend the `AnnotatePass` enum**

In `cli/annotate/main.swift`, replace lines 20-23:

```swift
enum AnnotatePass: String {
    case llm                // hate / counter / neutral classification (default)
    case llmSentiment       // positive / neutral / negative sentiment
    case nltagger           // Apple on-device sentiment — no LLM, no network
}
```

- [ ] **Step 2: Accept the new value when parsing `--pass`**

Replace the `case "--pass":` block (lines 99-107) with:

```swift
            case "--pass":
                i += 1
                if i < args.count {
                    switch args[i] {
                    case "llm": a.pass = .llm
                    case "llm-sentiment", "sentiment": a.pass = .llmSentiment
                    case "nltagger": a.pass = .nltagger
                    default:
                        fail("blueX-annotate", "invalid --pass value '\(args[i])'. Valid: llm, llm-sentiment, nltagger")
                    }
                }
```

- [ ] **Step 3: Document it in the usage text**

In the `usage` string, replace the `--pass <p>` block (lines 161-168) with:

```
  --pass <p>         llm            — hate / counter / neutral classification
                                       using the model's prompt template (default)
                     llm-sentiment  — positive / neutral / negative sentiment
                                       classification, distinct prompt + class
                                       set; writes stage="llm-sentiment" so it
                                       sits alongside the NLTagger sentiment
                                       and the hate/counter annotation.
                     nltagger       — Apple's on-device NLTagger sentiment.
                                       Free, no network, no Ollama, no
                                       ModelConfig. Writes stage="nltagger".
                                       This is the pass the nightly job runs.
                                       Honours --limit; ignores --model, --pace
                                       and --concurrency.
```

- [ ] **Step 4: Add the dispatch block**

Insert immediately **before** the `// ---- pick model` comment (currently line 313), i.e. after the `list-models` block returns. It must come before model selection so a machine with no `ModelConfig` and no Ollama can still run the nightly pass:

```swift
        // ---- nltagger pass — Apple's on-device sentiment. Deliberately handled
        // before model selection: it needs no ModelConfig, no client and no
        // network, so it must not fail on a machine where Ollama is absent.
        if args.pass == .nltagger {
            if args.coverage || args.benchmarkFile != nil {
                fail("blueX-annotate", "--pass nltagger supports --limit only (not --coverage or --benchmark).")
            }
            let cancel = installSIGINTHandler(notice: "\n\nstopping after current page — please wait…\n")
            let runStart = Date()
            let annotated: Int
            do {
                annotated = try NLTaggerPass(container: container).run(
                    limit: args.limit,
                    isCancelled: { cancel.isSet },
                    progress: { done, total in
                        let pct = total == 0 ? 0.0 : Double(done) / Double(total)
                        let filled = Int((Double(barWidth) * pct).rounded())
                        let bar = String(repeating: "█", count: filled)
                                + String(repeating: "░", count: barWidth - filled)
                        let elapsed = Date().timeIntervalSince(runStart)
                        let rate = elapsed > 0 ? Double(done) / elapsed : 0
                        writeProgress(String(
                            format: "%@ %d/%d  %.0f posts/s  %@",
                            bar, done, total, rate, formatDuration(elapsed)
                        ))
                    }
                )
            } catch {
                fail("blueX-annotate", "nltagger pass failed: \(error)")
            }
            let elapsed = Date().timeIntervalSince(runStart)
            let rate = elapsed > 0 ? Double(annotated) / elapsed : 0
            writeFinalLine(String(
                format: "Apple NLTagger sentiment — %d post%@ in %@ (%.1f posts/s)",
                annotated, annotated == 1 ? "" : "s", formatDuration(elapsed), rate
            ))
            return
        }
```

These are the real helper signatures from `cli/Shared/CLISupport.swift`: `writeProgress(_ line: String)`, `writeFinalLine(_ line: String)`, `formatDuration(_ seconds: TimeInterval)`, and `CancelFlag.isSet`. The existing `progressLine(...)` helper is deliberately **not** reused — it requires `modelID` and `paceLabel`, neither of which applies to a pass with no model.
```

- [ ] **Step 5: Build the CLI**

Run:
```bash
cd /Volumes/Eregion/projects/bluex-v2
xcodebuild build -project BlueX.xcodeproj -scheme BlueXAnnotate \
  -destination 'platform=macOS,arch=arm64' -quiet 2>&1 | tail -20
```
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Verify the flag is wired**

Run:
```bash
cd /Volumes/Eregion/projects/bluex-v2
BIN="$(find "$HOME/Library/Developer/Xcode/DerivedData/BlueX-"*/Build/Products/Debug -name blueX-annotate -type f 2>/dev/null | head -1)"
"$BIN" --help | grep -A3 nltagger
"$BIN" --pass bogus 2>&1 | head -2
```
Expected: help text shows the `nltagger` entry; the bogus value errors with `Valid: llm, llm-sentiment, nltagger`

- [ ] **Step 7: Smoke-test against the real store with a tiny limit**

Run:
```bash
"$BIN" --pass nltagger --limit 20
```
Expected: a progress bar, then `Apple NLTagger sentiment — 20 posts in …` and a throughput line.

This writes 20 real annotations. That is intended and additive — it annotates posts that have none.

- [ ] **Step 8: Commit**

```bash
cd /Volumes/Eregion/projects/bluex-v2
git add cli/annotate/main.swift
git commit -m "feat(annotate): add --pass nltagger for Apple on-device sentiment

Dispatches before model selection so it needs no ModelConfig, no Ollama and no
network. This is the pass the nightly job runs; at 797k posts the on-device
Foundation Models route would need 66h-9d, so NLTagger is the only viable
option for full-corpus sentiment."
```

---

### Task 3: Build the CLIs to a stable path

The symlinks at `~/.local/bin` pointed into `DerivedData/BlueX-cdfwtjmm…`, which got cleaned — the second cause of the outage.

**Files:**
- Modify: `tools/install-cli.sh`

**Interfaces:**
- Produces: executable `~/.local/bin/blueX-scrape` and `~/.local/bin/blueX-annotate`, symlinked into `~/.local/share/bluex-build/Build/Products/Debug`. Tasks 5 and 7 depend on these paths.

- [ ] **Step 1: Rewrite `tools/install-cli.sh`**

Replace the whole file with:

```bash
#!/usr/bin/env bash
# tools/install-cli.sh
#
# Build the BlueX command-line tools and put them on PATH at ~/.local/bin.
# Safe to re-run after every change.
#
# Builds into a STABLE derived-data path rather than Xcode's default. The default
# location is disposable: cleaning DerivedData on 2026-06 broke both symlinks and
# the nightly jobs failed silently for 61 days.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${HOME}/.local/share/bluex-build"
BUILD_DIR="${BUILD_ROOT}/Build/Products/Debug"
DEST_DIR="${HOME}/.local/bin"

mkdir -p "$DEST_DIR" "$BUILD_ROOT"

echo "==> building (derivedDataPath: $BUILD_ROOT)"
for scheme in BlueXAnnotate BlueXScrape; do
  xcodebuild build \
    -project "$REPO_ROOT/BlueX.xcodeproj" \
    -scheme "$scheme" \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$BUILD_ROOT" \
    -quiet
  echo "  ✓ $scheme"
done

install_one() {
  local name="$1"
  local bin="$BUILD_DIR/$name"
  if [[ ! -f "$bin" ]]; then
    echo "✗ $name not found at $bin after a successful build." >&2
    return 1
  fi
  # SYMLINK instead of cp: newer macOS (Sequoia+ with the provenance xattr)
  # SIGKILLs binaries that have been copied out of their build location when
  # they link statically-included SPM products via package-internal rpaths.
  # The original at the build location works; the bytewise-identical copy does
  # not. Symlinking sidesteps the check entirely, and rebuilds are picked up
  # without re-running this script.
  ln -sfn "$bin" "$DEST_DIR/$name"
  echo "✓ symlinked: $DEST_DIR/$name → $bin"
}

install_one blueX-annotate
install_one blueX-scrape

case ":$PATH:" in
  *":$DEST_DIR:"*) ;;
  *)
    echo
    echo "NOTE: $DEST_DIR is not on your PATH."
    echo "Add this to your shell rc (~/.zshrc):"
    echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
    ;;
esac
```

- [ ] **Step 2: Run it**

Run: `cd /Volumes/Eregion/projects/bluex-v2 && tools/install-cli.sh`
Expected: two `✓ symlinked:` lines pointing into `~/.local/share/bluex-build`

- [ ] **Step 3: Verify the symlinks resolve and execute**

Run:
```bash
ls -la ~/.local/bin/blueX-scrape ~/.local/bin/blueX-annotate
~/.local/bin/blueX-annotate --help | head -3
~/.local/bin/blueX-scrape --list-accounts | head -5
```
Expected: both resolve, `--help` prints usage, `--list-accounts` prints accounts. The last one also proves Keychain access works.

- [ ] **Step 4: Commit**

```bash
cd /Volumes/Eregion/projects/bluex-v2
git add tools/install-cli.sh
git commit -m "fix(tools): build CLIs to a stable derivedDataPath

Symlinks pointed into Xcode's disposable DerivedData; cleaning it silently
broke the nightly jobs for 61 days. Build into ~/.local/share/bluex-build
instead, and build rather than merely locating the binaries."
```

---

### Task 4: Move the store to the Eregion volume

Added on request 2026-08-04. The internal disk is at 96% (18Gi free) holding a 456MB store about to gain ~795k annotation rows plus 61 days of recovered reply trees; Eregion has 627Gi free.

`BlueXStore` is the only place that resolves the store path — the GUI and both CLIs route through `openContainer()`, and `BlueXStore.url` is referenced once, in an error message.

**Files:**
- Modify: `BlueX/Data/BlueXSchema.swift:20-44`
- Test: `BlueXTests/Data/BlueXStoreTests.swift`

**Interfaces:**
- Produces: `BlueXStore.directory` (URL, honours `BLUEX_STORE_DIR`), `BlueXStore.url`, `BlueXStore.isAvailable` (Bool), `BlueXStore.StoreError.volumeNotMounted(URL)`. Task 5's mount-wait mirrors `isAvailable` in shell.

**Do NOT migrate the store data.** Write the code, test it against temporary directories, commit, and stop. Moving the real 456MB store is an attended step the controller performs with the human — a subagent must not touch it. Do not run any CLI against the default store path in this task.

- [ ] **Step 1: Write the failing tests**

Create `BlueXTests/Data/BlueXStoreTests.swift`:

```swift
// BlueXTests/Data/BlueXStoreTests.swift
import XCTest
@testable import BlueX

final class BlueXStoreTests: XCTestCase {

    private var savedOverride: String?

    override func setUp() {
        super.setUp()
        savedOverride = ProcessInfo.processInfo.environment["BLUEX_STORE_DIR"]
    }

    override func tearDown() {
        if let savedOverride {
            setenv("BLUEX_STORE_DIR", savedOverride, 1)
        } else {
            unsetenv("BLUEX_STORE_DIR")
        }
        super.tearDown()
    }

    // Pins the constant. The whole point of the change is that the data lives on the
    // external volume, so a silent revert to the internal disk must fail the suite.
    func testDefaultDirectoryIsOnTheEregionVolume() {
        unsetenv("BLUEX_STORE_DIR")
        XCTAssertEqual(BlueXStore.directory.path, "/Volumes/Eregion/bluex-data")
        XCTAssertEqual(BlueXStore.url.lastPathComponent, "default.store")
    }

    func testDirectoryHonoursEnvironmentOverride() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bluex-store-override", isDirectory: true)
        setenv("BLUEX_STORE_DIR", tmp.path, 1)
        XCTAssertEqual(BlueXStore.directory.path, tmp.path)
    }

    // The critical guard. With the drive detached, creating the directory would
    // produce a SECOND, empty store — which looks like success and silently
    // orphans 797k posts.
    func testOpenContainerThrowsWhenTheVolumeIsMissing() {
        let missing = "/Volumes/NotMounted-\(UUID().uuidString)/bluex-data"
        setenv("BLUEX_STORE_DIR", missing, 1)

        XCTAssertFalse(BlueXStore.isAvailable)
        XCTAssertThrowsError(try BlueXStore.openContainer()) { error in
            guard case BlueXStore.StoreError.volumeNotMounted = error else {
                return XCTFail("expected volumeNotMounted, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing),
                       "must not create the store directory when the volume is absent")
    }

    func testOpenContainerSucceedsWhenTheParentExists() throws {
        let parent = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bluex-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        setenv("BLUEX_STORE_DIR", parent.appendingPathComponent("bluex-data").path, 1)
        XCTAssertTrue(BlueXStore.isAvailable)
        _ = try BlueXStore.openContainer()
        XCTAssertTrue(FileManager.default.fileExists(atPath: BlueXStore.url.path))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
cd /Volumes/Eregion/projects/bluex-v2
xcodegen generate
xcodebuild test -project BlueX.xcodeproj -scheme BlueX \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:BlueXTests/BlueXStoreTests 2>&1 | tail -30
```
Expected: FAIL — `BlueXStore` has no member `directory` / `isAvailable` / `StoreError`

- [ ] **Step 3: Rewrite `BlueXStore`**

In `BlueX/Data/BlueXSchema.swift`, replace the whole `BlueXStore` enum (lines 20-44, including its doc comment) with:

```swift
/// Store location + container builder for every process that opens the BlueX
/// database: the GUI, `blueX-scrape` and `blueX-annotate`.
///
/// The store lives on the external Eregion volume. The internal disk was at 96%
/// (18Gi free) holding a 456MB store about to gain ~795k annotation rows plus 61
/// days of recovered reply trees; Eregion has 627Gi.
///
/// Only the DATA lives there. The launchd job scripts stay on the internal disk,
/// because launchd execs them and can fire during DarkWake, when this volume is not
/// mounted — that is exactly what killed scraping for 61 days from 2026-06-04.
enum BlueXStore {
    enum StoreError: LocalizedError {
        case volumeNotMounted(URL)

        var errorDescription: String? {
            switch self {
            case .volumeNotMounted(let dir):
                return "The BlueX store directory is unavailable: \(dir.path). "
                     + "Attach the Eregion drive, or set BLUEX_STORE_DIR to another location."
            }
        }
    }

    /// Store directory. `BLUEX_STORE_DIR` overrides it, so the location can change
    /// without a rebuild and tests can point at a temporary directory.
    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["BLUEX_STORE_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: "/Volumes/Eregion/bluex-data", isDirectory: true)
    }

    static var url: URL {
        directory.appendingPathComponent("default.store", isDirectory: false)
    }

    /// True when the store directory's PARENT exists — i.e. the volume is mounted.
    ///
    /// Checking the parent rather than the directory itself is deliberate: if the
    /// drive is detached, `createDirectory` would happily build the whole path under
    /// an empty /Volumes and SwiftData would create a second, empty store. That
    /// looks like success while orphaning 797k posts, so it must be impossible.
    static var isAvailable: Bool {
        var isDirectory: ObjCBool = false
        let parent = directory.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }

    /// Creates the store directory if needed and returns a configured ModelContainer.
    static func openContainer() throws -> ModelContainer {
        guard isAvailable else { throw StoreError.volumeNotMounted(directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let config = ModelConfiguration(
            schema: BlueXSchema.all,
            url: url,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: BlueXSchema.all, configurations: config)
    }
}
```

`BlueXStore.url` changes from a stored to a computed property. Its one caller — `BlueX/BlueXApp.swift:11`, inside a `fatalError` message — is source-compatible and needs no edit. The GUI still fails loudly with the drive detached, and now the message names the drive.

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
cd /Volumes/Eregion/projects/bluex-v2
xcodegen generate
xcodebuild test -project BlueX.xcodeproj -scheme BlueX \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:BlueXTests/BlueXStoreTests 2>&1 | tail -30
```
Expected: PASS — 4 tests

- [ ] **Step 5: Confirm both CLIs and the app still build**

Run:
```bash
cd /Volumes/Eregion/projects/bluex-v2
for scheme in BlueX BlueXAnnotate BlueXScrape; do
  xcodebuild build -project BlueX.xcodeproj -scheme "$scheme" \
    -destination 'platform=macOS,arch=arm64' -quiet 2>&1 | tail -5
  echo "  built $scheme"
done
```
Expected: three successful builds

- [ ] **Step 6: Run the full suite**

Run:
```bash
cd /Volumes/Eregion/projects/bluex-v2
xcodebuild test -project BlueX.xcodeproj -scheme BlueX \
  -destination 'platform=macOS,arch=arm64' 2>&1 | tail -30
```
Expected: PASS — all tests, including `NLTaggerPassTests` and `ScrapeCoordinatorAnnotationTests`

- [ ] **Step 7: Commit**

```bash
cd /Volumes/Eregion/projects/bluex-v2
git add BlueX/Data/BlueXSchema.swift BlueXTests/Data/BlueXStoreTests.swift BlueX.xcodeproj
git commit -m "feat(store): move the SwiftData store to the Eregion volume

The internal disk is at 96% (18Gi free) with a 456MB store about to gain ~795k
annotation rows plus 61 days of recovered reply trees; Eregion has 627Gi.

openContainer() now throws volumeNotMounted rather than creating the directory
when the drive is detached — otherwise SwiftData would build a second, empty
store that looks like success while orphaning 797k posts. Path is overridable
via BLUEX_STORE_DIR.

Only the data moves. The launchd job scripts stay on the internal disk because
launchd can fire them during DarkWake, when this volume is unmounted."
```

**No data migration follows this task.** The human chose a clean slate on 2026-08-04: the old corpus is archived at `/Volumes/Eregion/bluex-archive/default.store.2026-08-04-preclean` (verified 797,253 posts / 6 accounts) and BlueX starts from an empty store on Eregion, which `AccountSeeder` auto-seeds. See Task 8.

---

### Task 5: The nightly job

**Files:**
- Create: `tools/jobs/lib-bluex-job.sh`, `tools/jobs/bluex-nightly.sh`

**Interfaces:**
- Consumes: `~/.local/bin/blueX-scrape`, `~/.local/bin/blueX-annotate --pass nltagger`; `BLUEX_STORE_DIR` semantics from Task 4
- Produces: `bluex-nightly.sh --preflight` (exit 0 ok, 1 problems); `bluex_wait_for_store TIMEOUT` and the `BLUEX_*` variables in `lib-bluex-job.sh`; heartbeat at `~/Library/Logs/BlueX/last-run.json` with keys `finishedAt`, `scrapeExit`, `sentimentExit`, `log`. Tasks 6 and 7 depend on these.

- [ ] **Step 1: Create the shared library**

Create `tools/jobs/lib-bluex-job.sh`:

```zsh
# tools/jobs/lib-bluex-job.sh — shared helpers for the BlueX launchd jobs.
# Sourced, never executed.
#
# These scripts are installed to the internal disk on purpose. launchd fires them
# during DarkWake, when /Volumes/Eregion is not mounted — that is what caused the
# 61-day outage beginning 2026-06-04. Nothing here may reference /Volumes.

BLUEX_LOG_DIR="$HOME/Library/Logs/BlueX"
BLUEX_HEARTBEAT="$BLUEX_LOG_DIR/last-run.json"
BLUEX_LOCK="$BLUEX_LOG_DIR/bluex-store.lock"
BLUEX_BIN="$HOME/.local/bin"

# The DATA lives on the external volume; logs, locks and the heartbeat stay on the
# internal disk so they remain writable even when the drive is detached. Exported so
# the Swift CLIs resolve the same path this script checked.
export BLUEX_STORE_DIR="${BLUEX_STORE_DIR:-/Volumes/Eregion/bluex-data}"
BLUEX_STORE="$BLUEX_STORE_DIR/default.store"

mkdir -p "$BLUEX_LOG_DIR"

# Mirrors BlueXStore.isAvailable in Swift: the store directory's PARENT must exist,
# which is what "the volume is mounted" means. A full wake mounts external volumes
# asynchronously and the 03:31 job can win the race, so wait rather than fail.
# Timeout 0 = check once and return immediately.
bluex_wait_for_store() {
  local timeout="${1:-180}" waited=0
  local parent="${BLUEX_STORE_DIR:h}"
  while [ ! -d "$parent" ]; do
    if [ "$waited" -ge "$timeout" ]; then
      return 1
    fi
    sleep 5
    waited=$(( waited + 5 ))
  done
  return 0
}

# Desktop notification. Requires the user's Aqua session, so this works from a
# LaunchAgent and NOT from the root arm-wake daemon.
bluex_notify() {
  local title="$1" message="$2"
  osascript -e "display notification \"${message//\"/\\\"}\" with title \"${title//\"/\\\"}\"" \
    >/dev/null 2>&1 || true
}

bluex_log_path() {
  echo "$BLUEX_LOG_DIR/$1_$(date "+%Y-%m-%d_%H%M%S").log"
}

# Age of a file in seconds. Missing files report a huge age so callers can treat
# "absent" and "ancient" identically — the outage produced both.
bluex_age_seconds() {
  local f="$1"
  if [ ! -e "$f" ]; then
    echo 999999999
    return
  fi
  echo $(( $(date +%s) - $(stat -f %m "$f") ))
}
```

- [ ] **Step 2: Create the nightly job**

Create `tools/jobs/bluex-nightly.sh`:

```zsh
#!/bin/zsh
# tools/jobs/bluex-nightly.sh — the BlueX nightly run. User LaunchAgent, 03:31.
#
# Fires on a one-shot pmset wake armed at 07:00 the previous morning by the root
# arm-wake daemon. Holds a power assertion for the whole run: with `pmset sleep 1`
# the mini sleeps one minute after going idle, which would cut the run short.
#
# Runs as a user agent (not root) because the scrape reads Bluesky credentials
# from the user Keychain and alerting uses osascript.
set -u

JOBS_DIR="${0:A:h}"
source "$JOBS_DIR/lib-bluex-job.sh"

SCRAPE="$BLUEX_BIN/blueX-scrape"
ANNOTATE="$BLUEX_BIN/blueX-annotate"
# Reply-tree refresh window. A post's tree freezes once the previous scrape falls
# outside this window of the post's createdAt.
MAX_WINDOW_DAYS=7

preflight() {
  local problems=0
  local bin
  for bin in "$SCRAPE" "$ANNOTATE"; do
    if [ ! -x "$bin" ]; then
      echo "✗ missing or not executable: $bin"
      echo "  fix: run tools/install-jobs.sh from the repo"
      problems=1
    fi
  done
  if ! bluex_wait_for_store 0; then
    echo "✗ store volume not mounted: ${BLUEX_STORE_DIR:h}"
    echo "  fix: attach the Eregion drive"
    problems=1
  fi
  if [ ! -e "$BLUEX_STORE" ]; then
    echo "✗ store not found: $BLUEX_STORE"
    problems=1
  fi
  # --list-accounts opens the store and reads Keychain credentials, so a zero exit
  # proves the unattended path works. This is the one thing that cannot be checked
  # any other way before 03:30.
  if [ -x "$SCRAPE" ] && ! "$SCRAPE" --list-accounts >/dev/null 2>&1; then
    echo "✗ blueX-scrape --list-accounts failed — Keychain credentials or store?"
    problems=1
  fi
  [ "$problems" -eq 0 ] && echo "✓ preflight ok"
  return $problems
}

if [ "${1:-}" = "--preflight" ]; then
  preflight
  exit $?
fi

LOG="$(bluex_log_path nightly)"

# The store lives on an external volume, so wait for the mount before anything else.
# Bounded: a launchd job that hangs forever is worse than one that reports and exits.
if ! bluex_wait_for_store 180; then
  echo "$(date): store volume ${BLUEX_STORE_DIR:h} not mounted after 180s — skipped." >>"$LOG"
  bluex_notify "BlueX nightly skipped" "Eregion not mounted after 180s — see $LOG"
  exit 75
fi

if ! preflight >>"$LOG" 2>&1; then
  bluex_notify "BlueX nightly" "Preflight failed — see $LOG"
  exit 78
fi

# Reclaim a lock left behind by a crashed, killed or slept run (older than 18h —
# longer than any expected run). Bounds the damage of a never-released lock.
if [ -d "$BLUEX_LOCK" ] && [ -n "$(find "$BLUEX_LOCK" -maxdepth 0 -mmin +1080 2>/dev/null)" ]; then
  echo "$(date): reclaiming stale store-lock." >>"$LOG"
  rmdir "$BLUEX_LOCK" 2>/dev/null
fi

# Atomic mkdir lock — CoreData is not safe for concurrent multi-process writes.
if ! mkdir "$BLUEX_LOCK" 2>/dev/null; then
  echo "$(date): store busy ($BLUEX_LOCK) — nightly skipped." >>"$LOG"
  exit 0
fi

caffeinate -i -s -w $$ &
CAFFEINATE_PID=$!
trap 'kill "$CAFFEINATE_PID" 2>/dev/null; rmdir "$BLUEX_LOCK" 2>/dev/null' EXIT

scrape_rc=0
annotate_rc=0

# A brace group, not a subshell — the exit codes below must survive into the
# heartbeat written afterwards.
{
  echo "=== nightly $(date) ==="
  echo "--- scrape (gentle, max-window-days $MAX_WINDOW_DAYS) ---"
  "$SCRAPE" --pace gentle --max-window-days "$MAX_WINDOW_DAYS"
  scrape_rc=$?
  [ "$scrape_rc" -ne 0 ] && echo "✗ scrape failed (exit $scrape_rc)."

  echo "--- Apple NLTagger sentiment ---"
  "$ANNOTATE" --pass nltagger
  annotate_rc=$?
  [ "$annotate_rc" -ne 0 ] && echo "✗ sentiment failed (exit $annotate_rc)."

  echo "=== done $(date) ==="
} >>"$LOG" 2>&1

# Heartbeat. Lets the watchdog tell "ran but found nothing new" from "never ran".
cat >"$BLUEX_HEARTBEAT" <<JSON
{
  "finishedAt": "$(date -u "+%Y-%m-%dT%H:%M:%SZ")",
  "scrapeExit": $scrape_rc,
  "sentimentExit": $annotate_rc,
  "log": "$LOG"
}
JSON

if [ "$scrape_rc" -ne 0 ] || [ "$annotate_rc" -ne 0 ]; then
  bluex_notify "BlueX nightly failed" "scrape=$scrape_rc sentiment=$annotate_rc — see $LOG"
  exit 1
fi
exit 0
```

- [ ] **Step 3: Check the syntax**

Run:
```bash
cd /Volumes/Eregion/projects/bluex-v2
zsh -n tools/jobs/lib-bluex-job.sh && zsh -n tools/jobs/bluex-nightly.sh && echo "syntax ok"
```
Expected: `syntax ok`

- [ ] **Step 4: Run the preflight from the repo copy**

Run:
```bash
cd /Volumes/Eregion/projects/bluex-v2
chmod +x tools/jobs/bluex-nightly.sh
tools/jobs/bluex-nightly.sh --preflight; echo "exit=$?"
```
Expected: `✓ preflight ok`, `exit=0`. If it reports a missing binary, Task 3 did not complete.

- [ ] **Step 5: Commit**

```bash
cd /Volumes/Eregion/projects/bluex-v2
git add tools/jobs/lib-bluex-job.sh tools/jobs/bluex-nightly.sh
git commit -m "feat(jobs): nightly scrape + Apple sentiment job

One job replaces the two that raced on the store lock: sequential order is now
structural rather than a race, with one caffeinate assertion and one lock
acquisition. Holds a power assertion because pmset sleep is 1 minute. Adds
--preflight so Keychain access can be verified before trusting a 03:30 run."
```

---

### Task 6: The staleness watchdog

The outage went unnoticed for 61 days. This is the part that would have caught it.

**Files:**
- Create: `tools/jobs/bluex-watchdog.sh`

**Interfaces:**
- Consumes: `lib-bluex-job.sh` (`bluex_age_seconds`, `bluex_notify`, `BLUEX_HEARTBEAT`, `BLUEX_STORE`)
- Produces: exit 0 when fresh, 1 when stale; appends to `~/Library/Logs/BlueX/watchdog.log`

- [ ] **Step 1: Create the watchdog**

Create `tools/jobs/bluex-watchdog.sh`:

```zsh
#!/bin/zsh
# tools/jobs/bluex-watchdog.sh — staleness check. User LaunchAgent, 06:56.
#
# Rides the existing 06:55 wakepoweron. Notification only: arming the nightly wake
# belongs to the root daemon, which runs off that same wakepoweron rather than off
# the previous night's job, so there is no chain a failed run can break.
#
# Exists because the 2026-06-04 outage failed silently for 61 days. Checking BOTH
# the heartbeat and the store mtime distinguishes "ran but wrote nothing" from
# "never ran at all" — the outage was the second kind.
set -u

JOBS_DIR="${0:A:h}"
source "$JOBS_DIR/lib-bluex-job.sh"

STALE_AFTER=$(( 48 * 3600 ))
LOG="$BLUEX_LOG_DIR/watchdog.log"

heartbeat_age=$(bluex_age_seconds "$BLUEX_HEARTBEAT")
store_age=$(bluex_age_seconds "$BLUEX_STORE")

echo "$(date): heartbeat=${heartbeat_age}s store=${store_age}s threshold=${STALE_AFTER}s" >>"$LOG"

if [ "$heartbeat_age" -gt "$STALE_AFTER" ] || [ "$store_age" -gt "$STALE_AFTER" ]; then
  days=$(( store_age / 86400 ))
  bluex_notify "BlueX is stale" "No successful run in ${days}d — check $BLUEX_LOG_DIR"
  echo "$(date): STALE — notified (${days}d)." >>"$LOG"
  exit 1
fi

echo "$(date): fresh." >>"$LOG"
exit 0
```

- [ ] **Step 2: Check the syntax**

Run: `cd /Volumes/Eregion/projects/bluex-v2 && zsh -n tools/jobs/bluex-watchdog.sh && echo "syntax ok"`
Expected: `syntax ok`

- [ ] **Step 3: Verify it detects the current staleness**

The store has not been written since 2026-06-04, so right now it must report stale — a live end-to-end check of the alerting path.

Run:
```bash
cd /Volumes/Eregion/projects/bluex-v2
chmod +x tools/jobs/bluex-watchdog.sh
tools/jobs/bluex-watchdog.sh; echo "exit=$?"
tail -2 ~/Library/Logs/BlueX/watchdog.log
```
Expected: `exit=1`, a desktop notification appears, and the log records `STALE`.

Note: Task 2 step 7 wrote annotations, which may have bumped the store mtime. If so the heartbeat is still absent, so the check must still report stale via `heartbeat_age`.

- [ ] **Step 4: Commit**

```bash
cd /Volumes/Eregion/projects/bluex-v2
git add tools/jobs/bluex-watchdog.sh
git commit -m "feat(jobs): staleness watchdog with desktop notification

Checks heartbeat age and store mtime against a 48h threshold. Using both
distinguishes a run that found nothing from a run that never happened; the
61-day outage was the latter and nothing surfaced it."
```

---

### Task 7: Installer and the regression guard

The root arm-wake daemon was **removed from this plan on 2026-08-04**: the mini is set to `sleep 0` (never idle-sleep), so launchd fires the 03:31 agent while the machine is awake and no `pmset` wake is needed. That deletes the only privileged component and the only `sudo` step.

**Files:**
- Create: `tools/jobs/test_jobs.py`, `tools/install-jobs.sh`
- Delete: `tools/blueX-scrape-job.sh`, `tools/blueX-annotate-job.sh`, `tools/net.pulsschlag.bluex.scrape.plist`, `tools/net.pulsschlag.bluex.annotate.plist`

**Interfaces:**
- Consumes: everything from Tasks 3-6 — `~/.local/bin/blueX-{scrape,annotate}`, `tools/jobs/lib-bluex-job.sh`, `tools/jobs/bluex-nightly.sh`, `tools/jobs/bluex-watchdog.sh`
- Produces: `tools/install-jobs.sh`, which installs the job scripts to `~/Library/Application Support/BlueX/jobs/` and writes two user LaunchAgents, `net.pulsschlag.bluex.nightly` (03:31) and `net.pulsschlag.bluex.watchdog` (06:56)

**Do NOT run `tools/install-jobs.sh` in this task.** A multi-hour initial scrape is writing to the store; bootstrapping the 03:31 agent could start a second scrape and put two CoreData writers on the same store. Write it, syntax-check it, commit it. The controller runs it later, once the initial scrape has converged.

- [ ] **Step 1: Write the failing guard tests**

Create `tools/jobs/test_jobs.py`:

```python
"""Guards against the fault that caused the 2026-06-04 outage.

launchd was told to run the job scripts from /Volumes/Eregion — an external
volume that is not mounted during DarkWake — so every run died with
"can't open input file" and exit 127, silently, for 61 days.

The store data was later moved onto that same volume deliberately, so the rule is
not "no /Volumes anywhere". It is: the DATA may live there, the CODE may not.
"""

import os
import plistlib
import subprocess
from pathlib import Path

import pytest

JOBS_SRC = Path(__file__).parent
RUNTIME_SCRIPTS = [
    "lib-bluex-job.sh",
    "bluex-nightly.sh",
    "bluex-watchdog.sh",
]
AGENTS_DIR = Path.home() / "Library/LaunchAgents"
NIGHTLY_PLIST = AGENTS_DIR / "net.pulsschlag.bluex.nightly.plist"
WATCHDOG_PLIST = AGENTS_DIR / "net.pulsschlag.bluex.watchdog.plist"


@pytest.mark.parametrize("name", RUNTIME_SCRIPTS)
def test_volumes_is_used_only_for_the_store_data_path(name):
    """Data on Eregion is fine. CODE on Eregion is what broke.

    launchd execs these scripts and can fire during DarkWake, when the volume is
    unmounted. A /Volumes path may therefore only ever be the store DATA directory,
    whose availability bluex_wait_for_store checks explicitly — never a script,
    source target or exec target.
    """
    offenders = []
    for line in (JOBS_SRC / name).read_text().splitlines():
        if "/Volumes" not in line or line.lstrip().startswith("#"):
            continue
        if "BLUEX_STORE_DIR" not in line:
            offenders.append(line)
    assert not offenders, (
        f"{name}: /Volumes used for something other than the store directory: {offenders}"
    )


@pytest.mark.parametrize("name", RUNTIME_SCRIPTS)
def test_nothing_is_sourced_or_executed_from_an_external_volume(name):
    for line in (JOBS_SRC / name).read_text().splitlines():
        stripped = line.lstrip()
        if stripped.startswith("#") or "/Volumes" not in stripped:
            continue
        if "source " in stripped or stripped.startswith(". "):
            pytest.fail(f"{name} sources from an external volume: {line}")


@pytest.mark.parametrize("name", RUNTIME_SCRIPTS)
def test_runtime_script_parses(name):
    result = subprocess.run(
        ["zsh", "-n", str(JOBS_SRC / name)], capture_output=True, text=True
    )
    assert result.returncode == 0, result.stderr


def test_installer_needs_no_privilege_escalation():
    """The design deliberately has no privileged component.

    The mini never idle-sleeps, so no pmset wake is needed, so nothing requires root.
    A sudo call reappearing here means someone reintroduced the daemon.
    """
    text = (JOBS_SRC.parent / "install-jobs.sh").read_text()
    offenders = [
        line
        for line in text.splitlines()
        if "sudo" in line and not line.lstrip().startswith("#")
    ]
    assert not offenders, f"install-jobs.sh must not require sudo: {offenders}"


@pytest.mark.parametrize("plist_path", [NIGHTLY_PLIST, WATCHDOG_PLIST])
def test_installed_agent_points_at_an_existing_internal_script(plist_path):
    if not plist_path.exists():
        pytest.skip(f"{plist_path.name} not installed — run tools/install-jobs.sh")
    with plist_path.open("rb") as handle:
        data = plistlib.load(handle)
    script = data["ProgramArguments"][-1]
    assert "/Volumes" not in script, f"points at an external volume: {script}"
    assert os.path.exists(script), f"points at a missing script: {script}"


def test_superseded_agents_are_removed():
    if not NIGHTLY_PLIST.exists():
        pytest.skip("new agents not installed yet — run tools/install-jobs.sh")
    for old in ("net.pulsschlag.bluex.scrape", "net.pulsschlag.bluex.annotate"):
        assert not (
            AGENTS_DIR / f"{old}.plist"
        ).exists(), f"{old}.plist should have been removed by install-jobs.sh"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd /Volumes/Eregion/projects/bluex-v2/tools/jobs && python -m pytest test_jobs.py -v 2>&1 | tail -20`
Expected: FAIL — `install-jobs.sh` does not exist yet, so `test_installer_needs_no_privilege_escalation` errors. The two installed-plist tests and `test_superseded_agents_are_removed` SKIP (nothing installed yet) — that is correct, not a failure.

- [ ] **Step 3: Create the installer**

Create `tools/install-jobs.sh`:

```bash
#!/usr/bin/env bash
# tools/install-jobs.sh — install the BlueX nightly jobs on this machine.
#
# Runtime artefacts must NOT live on /Volumes/Eregion: launchd fires these jobs
# during DarkWake, when that external volume is unmounted. That is exactly what
# broke scraping for 61 days from 2026-06-04. Everything the jobs need is copied
# to the internal disk here. Only the STORE DATA lives on Eregion.
#
# No privileged component: the mini is set to never idle-sleep (`sleep 0`), so
# launchd fires the 03:31 agent while it is awake and no pmset wake — and therefore
# no root daemon — is needed. This script must never call sudo; a test enforces that.
#
# Idempotent — safe to re-run after every rebuild.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOBS_SRC="$REPO_ROOT/tools/jobs"
JOBS_DEST="$HOME/Library/Application Support/BlueX/jobs"
AGENTS_DIR="$HOME/Library/LaunchAgents"
UID_NUM="$(id -u)"

echo "==> building CLIs"
"$REPO_ROOT/tools/install-cli.sh"

echo "==> installing job scripts to $JOBS_DEST"
mkdir -p "$JOBS_DEST" "$AGENTS_DIR" "$HOME/Library/Logs/BlueX"
install -m 644 "$JOBS_SRC/lib-bluex-job.sh"  "$JOBS_DEST/"
install -m 755 "$JOBS_SRC/bluex-nightly.sh"  "$JOBS_DEST/"
install -m 755 "$JOBS_SRC/bluex-watchdog.sh" "$JOBS_DEST/"

echo "==> retiring the superseded scrape/annotate agents"
for old in net.pulsschlag.bluex.scrape net.pulsschlag.bluex.annotate; do
  launchctl bootout "gui/$UID_NUM/$old" 2>/dev/null || true
  rm -f "$AGENTS_DIR/$old.plist"
  echo "  ✓ removed $old"
done

write_agent() {   # label script hour minute
  local label="$1" script="$2" hour="$3" minute="$4"
  cat >"$AGENTS_DIR/$label.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/zsh</string>
        <string>$JOBS_DEST/$script</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key><integer>$hour</integer>
        <key>Minute</key><integer>$minute</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/BlueX/launchd.$label.out.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/BlueX/launchd.$label.err.log</string>
    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
PLIST
  launchctl bootout "gui/$UID_NUM/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$UID_NUM" "$AGENTS_DIR/$label.plist"
  echo "  ✓ $label"
}

echo "==> installing user agents"
write_agent net.pulsschlag.bluex.nightly  bluex-nightly.sh  3 31
write_agent net.pulsschlag.bluex.watchdog bluex-watchdog.sh 6 56

echo
echo "Installed. Verify with:"
echo "  \"$JOBS_DEST/bluex-nightly.sh\" --preflight"
echo "  launchctl print gui/$UID_NUM/net.pulsschlag.bluex.nightly | head -20"
echo
echo "NOTE: pmset is deliberately untouched. This relies on the mini never"
echo "idle-sleeping (pmset -g custom | grep '^ sleep'). If sleep is re-enabled,"
echo "launchd replays a missed 03:31 event on the next wake."
```

- [ ] **Step 4: Syntax-check and run the guard tests**

Run:
```bash
cd /Volumes/Eregion/projects/bluex-v2
chmod +x tools/install-jobs.sh
bash -n tools/install-jobs.sh && echo "installer syntax ok"
cd tools/jobs && python -m pytest test_jobs.py -v 2>&1 | tail -20
```
Expected: `installer syntax ok`, and pytest passes with **3 skips** — the two installed-plist tests and `test_superseded_agents_are_removed`, because nothing is installed yet. Those skips are expected and must not be "fixed" by installing.

- [ ] **Step 5: Remove the superseded job scripts and plists**

Run:
```bash
cd /Volumes/Eregion/projects/bluex-v2
git rm tools/blueX-scrape-job.sh tools/blueX-annotate-job.sh
git rm tools/net.pulsschlag.bluex.scrape.plist tools/net.pulsschlag.bluex.annotate.plist
```
Expected: four files staged for deletion.

- [ ] **Step 6: Commit**

```bash
cd /Volumes/Eregion/projects/bluex-v2
git add tools/install-jobs.sh tools/jobs/test_jobs.py
git commit -m "feat(jobs): installer and /Volumes regression guard

install-jobs.sh copies the job scripts onto the internal disk, writes the two
user LaunchAgents (nightly 03:31, watchdog 06:56) and retires the two old
agents. No sudo and no privileged component: the mini never idle-sleeps, so
launchd fires the agent while it is awake and no pmset wake is needed.

test_jobs.py fails if any runtime script uses a /Volumes path for anything but
the store data directory — the exact fault that hid for 61 days — and fails if
sudo ever reappears in the installer."
```

---
### Task 8: Phase 1 attended rollout

**Attended — do not run unsupervised.** Nothing here is irreversible: the old corpus is archived, so the worst case is scraping again. But the initial scrape is a multi-day job and Step 3 is the first real test of unattended Keychain access.

**Files:** none — operational

**Clean slate, decided 2026-08-04.** The old corpus is NOT migrated. It is archived at `/Volumes/Eregion/bluex-archive/default.store.2026-08-04-preclean` (verified 797,253 posts, 6 accounts, `nltagger` 2,600 / `llm-sentiment` 30,854 / `llm` 1,179). BlueX starts from an empty store on Eregion.

Why this is safe for reply trees: `RescrapingPolicy` guarantees *"every post is scraped completely at least once"* — a post whose `replyTreeStatus` is not `.complete` is due on every run regardless of age, and `Post.init` sets `.pending`. So `--max-window-days` does not apply to never-scraped posts and there is no one-way door.

- [ ] **Step 1: Retire the old internal store**

With the BlueX GUI closed and no job running:

```bash
ls -la "$HOME/Library/Application Support/BlueX/"
sqlite3 "file:/Volumes/Eregion/bluex-archive/default.store.2026-08-04-preclean?mode=ro" \
  "SELECT 'archive posts', COUNT(*) FROM ZPOST;"
```
Expected: the archive reports 797,253 posts. **Only once that is confirmed:**
```bash
rm "$HOME/Library/Application Support/BlueX/default.store"
df -h "$HOME" | tail -1
```
Expected: ~456MB freed on the internal disk.

- [ ] **Step 2: Verify the fresh store is created and seeded**

Run:
```bash
~/.local/bin/blueX-scrape --list-accounts
ls -la /Volumes/Eregion/bluex-data/
```
Expected: the store is created at `/Volumes/Eregion/bluex-data/default.store` and 6 accounts are listed — bbcnews.bsky.social, theguardian.com, nytimes.com, tagesschau.bsky.social, zeit.de, spiegel.de.

**If zero accounts are listed, STOP.** Scraping with an empty account list would silently do nothing and look like success. `AccountSeeder.seed(into:)` only seeds when the account list is empty, so investigate before proceeding.

Verified 2026-08-04: all three groups (All Media, German Media, International Media) are recreated identically to the archive, along with 9 ModelConfigs. Nothing to re-add.

- [ ] **Step 3: Verify the unattended path end to end**

Run:
```bash
"$HOME/Library/Application Support/BlueX/jobs/bluex-nightly.sh" --preflight; echo "exit=$?"
```
Expected: `✓ preflight ok`, `exit=0`. This is the first real test that Keychain credentials are readable outside an interactive terminal session — an interactive `--list-accounts` success does **not** establish it.

- [ ] **Step 4: Start the initial scrape**

The default 14-day window is correct; `--max-window-days` has no effect on never-scraped posts.

```bash
~/.local/bin/blueX-scrape --pace gentle 2>&1 | tee ~/Library/Logs/BlueX/initial_$(date +%Y-%m-%d).log
```
Expected: order of 27+ hours for ~48k root threads at 2s per thread request, so this will span several nightly windows rather than finishing in one sitting. Safe to interrupt — Ctrl-C stops at the next post boundary, and `.pending` trees are retried on the next run.

- [ ] **Step 5: Run sentiment over what has been scraped**

```bash
time ~/.local/bin/blueX-annotate --pass nltagger 2>&1 | tail -5
```
Record the reported `posts/s` and **write the measured figure into the spec's Open Items section**, replacing the "unmeasured" note. Verify:
```bash
sqlite3 "file:/Volumes/Eregion/bluex-data/default.store?mode=ro" \
  "SELECT (SELECT COUNT(*) FROM ZPOST) AS posts, ZSTAGE, COUNT(*) FROM ZANNOTATION GROUP BY ZSTAGE;"
```
Expected: `nltagger` count equals the post count. No separate backfill phase is needed — sentiment is cheap and keeps pace with the scrape.

- [ ] **Step 5: Dry-run the nightly job under launchd**

Run:
```bash
launchctl kickstart -k "gui/$(id -u)/net.pulsschlag.bluex.nightly"
sleep 60
ls -lat ~/Library/Logs/BlueX/nightly_*.log | head -2
cat ~/Library/Logs/BlueX/last-run.json
```
Expected: a fresh `nightly_*.log`, and a heartbeat with `scrapeExit: 0` and `sentimentExit: 0`.

- [ ] **Step 6: Confirm the watchdog now reports fresh**

Run:
```bash
"$HOME/Library/Application Support/BlueX/jobs/bluex-watchdog.sh"; echo "exit=$?"
```
Expected: `exit=0`, no notification, log line ends `fresh.`

- [ ] **Step 7: Check the first real overnight run**

The morning after, run:
```bash
cat ~/Library/Logs/BlueX/last-run.json
pmset -g custom | grep -E "^ sleep"
```
Expected: a heartbeat with both exits `0`, `sleep 0` still in force, and a fresh `nightly_*.log`. There is no wake event to check for — the mini stays awake.

- [ ] **Step 8: Commit the measured numbers**

```bash
cd /Volumes/Eregion/projects/bluex-v2
git add docs/superpowers/specs/2026-08-04-bluex-scrape-and-sentiment-design.md
git commit -m "docs(spec): record measured NLTagger throughput and first-run results"
```

---

## Verification checklist

- [ ] `xcodebuild test -project BlueX.xcodeproj -scheme BlueX -destination 'platform=macOS,arch=arm64'` passes
- [ ] `cd tools/jobs && python -m pytest test_jobs.py` passes (the two installed-plist tests skip until the attended install)
- [ ] `blueX-annotate --pass nltagger --limit 5` writes annotations
- [ ] No installed plist references `/Volumes`, and job scripts use it only for `BLUEX_STORE_DIR`
- [ ] `pmset -g sched` still shows `wakepoweron at 6:55AM every day`
- [ ] Both old agents are gone from `~/Library/LaunchAgents`
- [ ] Heartbeat shows `scrapeExit: 0` and `sentimentExit: 0` after a kickstart
