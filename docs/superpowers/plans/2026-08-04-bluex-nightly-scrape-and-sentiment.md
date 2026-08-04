# BlueX Nightly Scrape + Apple Sentiment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore unattended nightly Bluesky scraping on `macmini.local` and replace the phi4:14b LLM annotation pass with Apple's free on-device NLTagger sentiment.

**Architecture:** Nothing on the runtime path may live on `/Volumes/Eregion` — launchd fires these jobs during DarkWake, when that external volume is unmounted (the cause of the 61-day outage from 2026-06-04). The repo stays the source of truth; `install-jobs.sh` copies job scripts to the internal disk. A root LaunchDaemon at 07:00 arms a one-shot `pmset` wake for 03:30 (`pmset` requires root); a user LaunchAgent at 03:31 does the work, keeping Keychain and notification access.

**Tech Stack:** Swift 5.9 / SwiftData / `NaturalLanguage` (macOS 14 deployment target, running on macOS 26.5.1), zsh job scripts, launchd, `pmset`, XcodeGen 2.46.0, pytest for the guard tests.

**Spec:** `docs/superpowers/specs/2026-08-04-bluex-scrape-and-sentiment-design.md`

## Global Constraints

- **No runtime artefact may reference `/Volumes`.** This is the regression that caused the outage. Guarded by a test in Task 6.
- **Deployment target `14.0`, `SWIFT_VERSION: "5.9"`** for all targets (`project.yml`).
- **`AnnotationService.swift` is excluded from the `BlueXAnnotate` target** (`project.yml:64-66`). CLI-visible code must not live in that file.
- **Annotation stage string is exactly `"nltagger"`** — matches `Post+Annotations.swift` and the `--reset-annotations` vocabulary.
- **`pmset schedule` requires root.** Verified: `pmset: This operation must be run as root`, exit 1.
- **Only one `pmset repeat` pair exists per machine** and the user's `wakepoweron at 6:55AM` occupies it. Never call `pmset repeat`.
- **Do not change any `pmset` power setting**, including the 06:55 repeating wake.
- **Store path:** `~/Library/Application Support/BlueX/default.store` (internal disk).
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
| `tools/install-cli.sh` | **modify** — build to a stable `-derivedDataPath` that survives an Xcode clean |
| `tools/jobs/lib-bluex-job.sh` | **new** — shared paths, notifications, file-age helper |
| `tools/jobs/bluex-nightly.sh` | **new** — the nightly run + `--preflight` |
| `tools/jobs/bluex-watchdog.sh` | **new** — staleness notification |
| `tools/jobs/bluex-arm-wake.sh` | **new** — the only privileged component; arms the next wake |
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
- Produces: the CLI invocation `blueX-annotate --pass nltagger [--limit N]` used by Task 4

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
- Produces: executable `~/.local/bin/blueX-scrape` and `~/.local/bin/blueX-annotate`, symlinked into `~/.local/share/bluex-build/Build/Products/Debug`. Tasks 4 and 6 depend on these paths.

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

### Task 4: The nightly job

**Files:**
- Create: `tools/jobs/lib-bluex-job.sh`, `tools/jobs/bluex-nightly.sh`

**Interfaces:**
- Consumes: `~/.local/bin/blueX-scrape`, `~/.local/bin/blueX-annotate --pass nltagger`
- Produces: `bluex-nightly.sh --preflight` (exit 0 ok, 1 problems); heartbeat at `~/Library/Logs/BlueX/last-run.json` with keys `finishedAt`, `scrapeExit`, `sentimentExit`, `log`. Tasks 5 and 6 depend on both.

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
BLUEX_STORE="$HOME/Library/Application Support/BlueX/default.store"
BLUEX_HEARTBEAT="$BLUEX_LOG_DIR/last-run.json"
BLUEX_LOCK="$BLUEX_LOG_DIR/bluex-store.lock"
BLUEX_BIN="$HOME/.local/bin"

mkdir -p "$BLUEX_LOG_DIR"

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

### Task 5: The staleness watchdog

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

### Task 6: Arm-wake daemon, installer, and the regression guard

**Files:**
- Create: `tools/jobs/bluex-arm-wake.sh`, `tools/jobs/test_jobs.py`, `tools/install-jobs.sh`
- Delete: `tools/blueX-scrape-job.sh`, `tools/blueX-annotate-job.sh`

**Interfaces:**
- Consumes: everything from Tasks 3-5
- Produces: installed agents `net.pulsschlag.bluex.{nightly,watchdog}`, daemon `net.pulsschlag.bluex.armwake`

- [ ] **Step 1: Write the failing guard tests**

Create `tools/jobs/test_jobs.py`:

```python
"""Guards against the fault that caused the 2026-06-04 outage.

launchd was told to run the job scripts from /Volumes/Eregion — an external
volume that is not mounted during DarkWake — so every run died with
"can't open input file" and exit 127, silently, for 61 days. Nothing on the
runtime path may reference /Volumes.
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
    "bluex-arm-wake.sh",
]
AGENTS_DIR = Path.home() / "Library/LaunchAgents"
NIGHTLY_PLIST = AGENTS_DIR / "net.pulsschlag.bluex.nightly.plist"
WATCHDOG_PLIST = AGENTS_DIR / "net.pulsschlag.bluex.watchdog.plist"


@pytest.mark.parametrize("name", RUNTIME_SCRIPTS)
def test_runtime_script_has_no_external_volume_path(name):
    text = (JOBS_SRC / name).read_text()
    offenders = [
        line
        for line in text.splitlines()
        if "/Volumes" in line and not line.lstrip().startswith("#")
    ]
    assert not offenders, f"{name} references /Volumes outside a comment: {offenders}"


@pytest.mark.parametrize("name", RUNTIME_SCRIPTS)
def test_runtime_script_parses(name):
    result = subprocess.run(
        ["zsh", "-n", str(JOBS_SRC / name)], capture_output=True, text=True
    )
    assert result.returncode == 0, result.stderr


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
Expected: FAIL — `bluex-arm-wake.sh` does not exist yet; installed-plist tests skip

- [ ] **Step 3: Create the arm-wake daemon script**

Create `tools/jobs/bluex-arm-wake.sh`:

```zsh
#!/bin/zsh
# tools/jobs/bluex-arm-wake.sh — arms the next BlueX nightly wake.
# Root LaunchDaemon, 07:00.
#
# Why root: `pmset schedule` refuses to run otherwise ("This operation must be run
# as root"). Why one-shot rather than repeating: `man pmset` allows only ONE pair of
# repeating events per machine, and the user's `wakepoweron at 6:55AM` already
# occupies it.
#
# Why 07:00: just after that wakepoweron, when the machine is reliably awake. Arming
# therefore never depends on the previous night's job having succeeded — there is no
# chain a single failure can break.
#
# This is the ONLY privileged component. It holds no credentials and never opens the
# SwiftData store.
set -u

LOG=/var/log/bluex-armwake.log
WAKE_TIME="03:30:00"
OWNER="BlueX"

# Cancel today's already-fired event before arming tomorrow's, so one-shot events
# cannot pile up if the machine is off for a stretch. Scoped to our owner string so
# the user's own pmset events are never touched.
stale="$(date "+%m/%d/%y") $WAKE_TIME"
pmset schedule cancel wake "$stale" "$OWNER" >>"$LOG" 2>&1 || true

target="$(date -v+1d "+%m/%d/%y") $WAKE_TIME"

if pmset schedule wake "$target" "$OWNER" >>"$LOG" 2>&1; then
  echo "$(date): armed wake for $target" >>"$LOG"
  exit 0
fi

echo "$(date): FAILED to arm wake for $target" >>"$LOG"
exit 1
```

- [ ] **Step 4: Create the installer**

Create `tools/install-jobs.sh`:

```bash
#!/usr/bin/env bash
# tools/install-jobs.sh — install the BlueX nightly jobs on this machine.
#
# Runtime artefacts must NOT live on /Volumes/Eregion: launchd fires these jobs
# during DarkWake, when that external volume is unmounted. That is exactly what
# broke scraping for 61 days from 2026-06-04. Everything the jobs need is copied
# to the internal disk here.
#
# Idempotent — safe to re-run after every rebuild.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOBS_SRC="$REPO_ROOT/tools/jobs"
JOBS_DEST="$HOME/Library/Application Support/BlueX/jobs"
AGENTS_DIR="$HOME/Library/LaunchAgents"
DAEMON_PLIST="/Library/LaunchDaemons/net.pulsschlag.bluex.armwake.plist"
LIBEXEC="/usr/local/libexec/bluex"
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

echo "==> installing the root arm-wake daemon (sudo: pmset requires root)"
sudo mkdir -p "$LIBEXEC"
sudo install -m 755 -o root -g wheel "$JOBS_SRC/bluex-arm-wake.sh" "$LIBEXEC/"
sudo tee "$DAEMON_PLIST" >/dev/null <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>net.pulsschlag.bluex.armwake</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/zsh</string>
        <string>$LIBEXEC/bluex-arm-wake.sh</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key><integer>7</integer>
        <key>Minute</key><integer>0</integer>
    </dict>
    <key>StandardErrorPath</key>
    <string>/var/log/bluex-armwake.log</string>
    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
PLIST
sudo chown root:wheel "$DAEMON_PLIST"
sudo chmod 644 "$DAEMON_PLIST"
sudo launchctl bootout system/net.pulsschlag.bluex.armwake 2>/dev/null || true
sudo launchctl bootstrap system "$DAEMON_PLIST"
echo "  ✓ net.pulsschlag.bluex.armwake"

echo "==> arming tonight's wake now, so the first run does not wait a day"
sudo "$LIBEXEC/bluex-arm-wake.sh"

echo
echo "Installed. Verify with:"
echo "  \"$JOBS_DEST/bluex-nightly.sh\" --preflight"
echo "  pmset -g sched"
echo "  launchctl print gui/$UID_NUM/net.pulsschlag.bluex.nightly | head -20"
```

- [ ] **Step 5: Run the installer**

Run:
```bash
cd /Volumes/Eregion/projects/bluex-v2
chmod +x tools/install-jobs.sh tools/jobs/bluex-arm-wake.sh
tools/install-jobs.sh
```
Expected: builds, installs, removes both old agents, bootstraps two agents and one daemon, and arms a wake. It will prompt for the sudo password.

- [ ] **Step 6: Run the guard tests to verify they pass**

Run: `cd /Volumes/Eregion/projects/bluex-v2/tools/jobs && python -m pytest test_jobs.py -v 2>&1 | tail -20`
Expected: PASS — no skips now that the agents are installed

- [ ] **Step 7: Verify launchd and pmset state**

Run:
```bash
launchctl print "gui/$(id -u)/net.pulsschlag.bluex.nightly" | grep -E "state|program|last exit"
sudo launchctl print system/net.pulsschlag.bluex.armwake | grep -E "state|program"
pmset -g sched
```
Expected: both loaded; `pmset -g sched` lists a `wake at …03:30:00` event owned by `BlueX`, alongside the untouched `wakepoweron at 6:55AM every day`.

- [ ] **Step 8: Remove the superseded job scripts**

Run:
```bash
cd /Volumes/Eregion/projects/bluex-v2
git rm tools/blueX-scrape-job.sh tools/blueX-annotate-job.sh
git rm tools/net.pulsschlag.bluex.scrape.plist tools/net.pulsschlag.bluex.annotate.plist
```
Expected: four files staged for deletion

- [ ] **Step 9: Commit**

```bash
cd /Volumes/Eregion/projects/bluex-v2
git add tools/install-jobs.sh tools/jobs/bluex-arm-wake.sh tools/jobs/test_jobs.py
git commit -m "feat(jobs): arm-wake daemon, installer, and /Volumes guard test

pmset schedule requires root and the single pmset repeat slot is taken by the
user's 06:55 wakepoweron, so a root LaunchDaemon arms a one-shot 03:30 wake at
07:00 while the working agent stays unprivileged and keeps Keychain and
notification access.

install-jobs.sh copies everything onto the internal disk and retires the two old
agents. test_jobs.py fails if any runtime artefact ever references /Volumes
again — the exact fault that hid for 61 days."
```

---

### Task 7: Phase 1 attended rollout

**Attended — do not run unsupervised.** Step 3 is a one-way door and the throughput numbers are genuinely unknown.

**Files:** none — operational

- [ ] **Step 1: Verify the unattended path end to end**

Run:
```bash
"$HOME/Library/Application Support/BlueX/jobs/bluex-nightly.sh" --preflight; echo "exit=$?"
```
Expected: `✓ preflight ok`, `exit=0`. This is the first real test that Keychain credentials are readable outside a terminal session.

- [ ] **Step 2: Measure NLTagger throughput**

Run:
```bash
time ~/.local/bin/blueX-annotate --pass nltagger --limit 2000
```
Record the reported `posts/s`. Extrapolate to the remaining backlog and **write the measured figure into the spec's Open Items section**, replacing the "unmeasured" note.

- [ ] **Step 3: Reply-tree catch-up — ONE-WAY DOOR**

This must run **before** any `--max-window-days 7` scrape. A normal run permanently freezes reply trees for every post created during the 61-day gap.

Run:
```bash
~/.local/bin/blueX-scrape --pace gentle --max-window-days 70 2>&1 | tee ~/Library/Logs/BlueX/catchup_$(date +%Y-%m-%d).log
```
Expected: hours of gentle-paced scraping. Do not interrupt unless necessary; Ctrl-C stops cleanly at the next post boundary and already-fetched work is saved.

- [ ] **Step 4: Full sentiment backfill**

Run:
```bash
time ~/.local/bin/blueX-annotate --pass nltagger 2>&1 | tail -5
```
Expected: the remaining backlog annotated. Verify:
```bash
sqlite3 "file:$HOME/Library/Application Support/BlueX/default.store?immutable=1" \
  "SELECT ZSTAGE, COUNT(*) FROM ZANNOTATION GROUP BY ZSTAGE;"
```
Expected: `nltagger` now close to the total post count.

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
pmset -g log | grep -Ei "Wake from" | grep "03:3" | tail -3
cat ~/Library/Logs/BlueX/last-run.json
tail -20 /var/log/bluex-armwake.log
grep -ci "Thermal" <(pmset -g log) || true
```
Expected: a full wake near 03:30, a heartbeat with both exits `0`, a fresh arm-wake line, and no thermal emergency during the run window.

- [ ] **Step 8: Commit the measured numbers**

```bash
cd /Volumes/Eregion/projects/bluex-v2
git add docs/superpowers/specs/2026-08-04-bluex-scrape-and-sentiment-design.md
git commit -m "docs(spec): record measured NLTagger throughput and first-run results"
```

---

## Verification checklist

- [ ] `xcodebuild test -project BlueX.xcodeproj -scheme BlueX -destination 'platform=macOS,arch=arm64'` passes
- [ ] `cd tools/jobs && python -m pytest test_jobs.py` passes with no skips
- [ ] `blueX-annotate --pass nltagger --limit 5` writes annotations
- [ ] No installed plist or job script references `/Volumes`
- [ ] `pmset -g sched` still shows `wakepoweron at 6:55AM every day`
- [ ] Both old agents are gone from `~/Library/LaunchAgents`
- [ ] Heartbeat shows `scrapeExit: 0` and `sentimentExit: 0` after a kickstart
