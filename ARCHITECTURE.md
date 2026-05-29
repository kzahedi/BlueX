# BlueX Architecture

BlueX is a single-window macOS research instrument for analysing hate speech and counter speech on Bluesky. It scrapes posts and their reply trees, classifies every post with a sentiment model and one or more LLMs, and presents the results as live weekly charts and an interactive thread graph.

This document describes how the app is laid out so a new contributor (or a fresh-context AI) can find their way around without reading every file.

---

## Tech stack

- **macOS 14+**, SwiftUI, Swift 5.9
- **SwiftData** as the persistence layer (CoreData under the hood)
- **`@Observable`** (Observation framework) for view models — no `ObservableObject` / `@Published`
- **`async`/`await`** structured concurrency; no Combine, no callbacks
- **Apple `NaturalLanguage` (`NLTagger`)** for sentiment + language detection
- **Local LLM runners** over HTTP — Ollama (default), MLX / LM Studio / any OpenAI-compatible server via the same protocol
- **Swift Charts** for analytics
- **xcodegen** generates `BlueX.xcodeproj` from `project.yml`; no human-edited project file

---

## Module layout

Code lives under `BlueX/` and falls into four layers, top to bottom:

```
Views/             SwiftUI views, no business logic
ViewModels/        @Observable transient state, no persistence
Services/          Scraping + annotation pipelines, networking
Data/              @Model classes, seeding, dedup, shared accessors
```

Views read SwiftData via `@Query` and dispatch actions through view-model methods or via closures owned by `ScrapeCoordinator` / `AnnotationService`. ViewModels never touch the network or persistence directly. Services never know about SwiftUI.

Two sibling top-level directories support the GUI:

- **`cli/`** — two headless tools that reuse the GUI's services and `@Model` schema directly (no logic duplication). `cli/annotate/` builds `blueX-annotate`; `cli/scrape/` builds `blueX-scrape`. `cli/Shared/CLISupport.swift` carries the shared utilities (Ctrl-C handler, progress writer, duration formatter, fail()). Both tools open the same SwiftData store as the GUI via `BlueXStore.openContainer()` (see `Data/BlueXSchema.swift`), so a long-running annotation pass writes back to the same store the GUI is reading. Pace + thermal back-off are reused unchanged.
- **`tools/`** — dev-time scripts (currently the app-icon generator).

---

## Data model

Every entity is a SwiftData `@Model`. Schema is registered once in `BlueXApp.swift` via `.modelContainer(for:)`.

| Model | Purpose |
|---|---|
| `TrackedAccount` | A Bluesky account being followed. `posts` cascades on delete; `groups` is a nullify-inverse M:N. |
| `AccountGroup` | User-defined grouping of accounts (e.g. "German Media"). |
| `Post` | A scraped post — root or reply. `parentURI` is nil for roots; `rootURI` is always set. `replyTreeStatus` (.pending / .inProgress / .complete) records thread-scraping progress. `account` is set only for root posts; replies have no account (the author isn't a tracked entity). |
| `Annotation` | A classification. `stage` is `"nltagger"` for Apple sentiment, `"llm"` for an LLM run. A post can carry many annotations — one NLTagger plus one per LLM model. `modelName` / `modelVersion` / `promptHash` identify the lineage; `rawResponse` preserves the original output for audit. |
| `AccountSnapshot` | Periodic counters per account (planned for time-series snapshots). |
| `ScrapeLog` | One row per scrape session: type / status / postCount / `resumeCursor` (for mid-scrape resume). |
| `ModelConfig` | An LLM endpoint + model id + prompt. The Annotation Queue's model picker enumerates these. Multiple presets seeded on first launch (Qwen 2.5/3.6, Gemma 4); `qwen3.6:27b` is the default after the 2026-05 prompt revision (HICC-style three-class classification, see `Research/LLM_Hate_Counter_Speech_Classification_from_CC.md` in the vault for the comparison). |
| `CoordinatorState` | A singleton row persisting the last coordinator phase for crash recovery. |

### Data-layer helpers

- **`AccountSeeder`** — `resetToSeedSet(in:)` and `ensureModelConfigs(in:)`. Both run from `RootView.task` on every launch; idempotent. The model-configs sync replaces stale presets (e.g. removing the now-uninstalled `llama3.2`) and pushes the latest `defaultPromptTemplate` onto preset configs while leaving user-added configs alone.
- **`AnnotationDedup.dedupLLM(in:)`** — also runs every launch. Groups every `stage="llm"` annotation by `(post.uri, modelName)`, keeps the newest, deletes the rest. Idempotent once the store is clean. Necessary because earlier code stored a fresh annotation per `(model, prompt)` and a prompt revision produced duplicates.
- **`Post+Annotations.swift`** — the single source of truth for "which annotation currently represents this post". Returns the most-recent-by-`createdAt` per stage:
  - `post.currentLLMAnnotation` / `post.currentSpeechClass`
  - `post.nlTaggerAnnotation`
  - `post.hasLLMAnnotation` / `post.hasNLTaggerAnnotation`

  Used everywhere instead of `annotations.last/.first(where:)` because SwiftData relationship arrays are unordered.
- **`ATProtoDate.parse(_:)`** — shared, robust ISO-8601 parser (with/without fractional seconds). Avoids per-post `ISO8601DateFormatter` instantiation in the scrapers.
- **`LLMPace`** — pace + `ThermalBackoff` helpers for inter-request sleep on long runs.

---

## Services

### API (`Services/API/`)

- **`BlueskyAPIClient`** — stateless `struct` over `URLSessionProtocol`. Implements `createSession`, `resolveHandle`, `getProfile`, `getAuthorFeed`, `getPostThread`. Every method returns `Result<T, BlueskyError>` so call sites can pattern-match the failure (auth, rate-limit + Retry-After, network, decoding, not-found).
- **`KeychainCredentials`** — wraps Security framework `SecItem*` for storing the Bluesky handle + app password. Service key `net.pulsschlag.BlueX`. No credentials ever touch UserDefaults or the SwiftData store.
- **`BlueskyStructs`** — Codable types matching ATProto JSON. `ATProtoThreadView` recursively reflects the reply tree.

### Scraping (`Services/Scraping/`)

- **`FeedScraper`** — paginates `getAuthorFeed` for one account, saves each new root post, supports an `onNewRootPost` callback for depth-first interleaving (see below), resumes from `ScrapeLog.resumeCursor` if a previous run was interrupted.
- **`ThreadScraper`** — pulls `getPostThread` for one root post, recursively walks the returned `ATProtoThreadView` and stores every reply. Two entry points: `scrapeThreadIfDue(post:token:window:)` for the depth-first callback, `scrapeAllThreads(for:token:window:)` to catch up existing posts.
- **`RescrapingPolicy`** — a single rule: a post's reply tree is refreshed only while its previous scrape happened within `createdAt + window` (default **14 days**, surfaced as the `scraping.maxRescrapeWindowDays` setting). Newly-discovered posts always get one scrape regardless of age; once the window closes, the tree is frozen.
- **`ScrapeCoordinator`** — the state machine. `@Observable`. Public API: `startScrape()`, `startScrape(accountDID:)`, `cancel()`, `runNLTaggerAnnotation()`, `runLLMAnnotation(using:saveEvery:pace:)`, `cancelAnnotation()`. Owns one long-lived `AnnotationService`. Exposes `phase`, `accountStatuses` (per-DID), `totalPostsThisRun`, `lastError` for the sidebar.

### Annotation (`Services/Annotation/`)

- **`NLTaggerAnalyser`** — wraps `NLTagger` for sentiment score + language detection; sets `speechClass = "neutral"` (Apple doesn't classify hate/counter).
- **`LocalModelClient`** protocol — `classify(text:language:) -> LLMAnnotation`, plus `modelName` / `modelVersion` / `promptHash`.
- **`OllamaClient`** — Ollama HTTP API. Calls `/api/generate`, parses the response JSON via `LLMResponseParser`.
- **`MLXClient`** — OpenAI-compatible `/v1/chat/completions`. `OpenAICompatibleClient` is a typealias.
- **`LLMResponseParser`** — extracts the JSON object from the raw model output, validates `class ∈ {hate, counter, neutral}`, normalises the literal string `"null"` for severity back to nil.
- **`AnnotationService`** — `@Observable`, owned by the coordinator. Drives both passes:
  - **`runNLTaggerPass`** — fetches every post without an `"nltagger"` annotation, classifies on a detached `Task` with its own background `ModelContext`, saves in batches of 200, streams progress (processed / total / eta) back to `@Observable` properties.
  - **`runLLMPass(saveEvery:pace:)`** — builds the pending set once via `(post.uri ∉ alreadyClassifiedByThisModel)`, then iterates in chunks of `saveEvery`. After each post: pace delay + thermal back-off (`ProcessInfo.thermalState`). `Task.checkCancellation` at every loop point. Streams progress + thermal state via `AsyncThrowingStream<LLMPassEvent, Error>`.

---

## ViewModels

`@Observable` final classes with transient state and pure functions. None persist anything.

| Class | Used by | Notes |
|---|---|---|
| `SidebarViewModel` | `SidebarView` | Mirrors coordinator state for sidebar rendering. |
| `AccountViewModel` | `AccountContentView` | Filter / sort / counts derived from a `[Post]`. |
| `GroupViewModel` | `GroupContentView` | Per-account aggregation across a group. |
| `ThreadViewModel` | `ThreadView` | Builds the parent→children map, supports class filter, derived counts. |
| `ChartsViewModel` | `AccountChartsView`, `GroupChartsView` | ISO-week bucketing, `WeekBucket` (root + reply counts per class + avg sentiment), running totals. |
| `QueueViewModel` | `QueueView` | Pending counts via `fetchCount` (not full fetches — opening the queue used to hang on relationship faulting). |

---

## Views

Three SwiftUI columns inside a `NavigationSplitView`:

1. **Sidebar** — groups, accounts (each with a live status dot + context-menu "Scrape this account"), the Annotation Queue, Settings. Bottom bar has "Scrape All" / "Stop".
2. **Content** — depends on the sidebar selection: a group's account list, an account's post list, a thread's message list, or the queue.
3. **Detail** — group charts, account analytics charts, thread tree graph, or settings tabs.

`SidebarItem` (defined in `RootView.swift`) wires these together:

| SidebarItem | Content column | Detail column |
|---|---|---|
| `.group(g)`    | `GroupContentView`   | `GroupChartsView` |
| `.account(a)`  | `AccountContentView` | `AccountChartsView` |
| `.post(p)`     | `ThreadView` (message list) | `ThreadGraphView` (tree graph) |
| `.queue`       | — | `QueueView` |
| `.settings`    | — | `SettingsView` |

### Notable views

- **`ThreadGraphView`** — top-down tree of colored circles connected by curves, one per post. Color source is a `Menu` next to the legend: **Apple sentiment** (smooth red→gray→green gradient on the score) or any `(modelName, promptHash)` lineage found in the thread (hate-red / counter-green / neutral-gray). Tapping a node opens `PostInspectorView` as a popover.
- **`PostInspectorView`** — the click-popover shared by the thread message list and the graph. Full post text, sentiment bar, every LLM annotation (class / severity / confidence / reasoning / disclosable raw response + prompt hash), engagement counts, AT URI.
- **`AccountChartsView`** — Posts-by-week, Replies-by-week, Sentiment-by-week (Apple), Hate-ratio. Stacked area charts use `.foregroundStyle(by: .value("Stage", …))` so each stage is a continuous series; the cumulative-y trick from an earlier version produced a sawtooth at every weekly sample. Recompute is debounced to ~300 ms so per-post saves during a scrape don't peg the main thread.
- **`QueueView`** — model picker, pace picker, **Start LLM / Stop** toggle, live progress with ETA, current-post preview, and a thermal badge (`warm — cooling` / `hot — long cool-down`) that appears only when `ProcessInfo.thermalState` is non-nominal.

---

## Concurrency model

Three places where work runs off the main thread:

1. **Scraping** — `ScrapeCoordinator.runScrape` is a non-isolated `async` method. The work runs on a background `Task`; every state mutation is wrapped in `await MainActor.run { … }`. Uses a freshly-created `ModelContext` bound to that task's lifetime. UI stays responsive even on long runs.
2. **NLTagger pass** — `runNLTaggerPass` is `@MainActor` for state setup, but the actual loop runs in a `Task.detached(priority: .userInitiated)` with its own `ModelContext`. Progress flows back through an `AsyncThrowingStream<(Int, Int, Double?), Error>`.
3. **LLM pass** — same pattern (detached task + stream). The pass tracks a `runningTask` so `AnnotationService.cancel()` (called via `ScrapeCoordinator.cancelAnnotation()`) can propagate `Task.checkCancellation`.

### SwiftData rules of thumb

- `@Model` instances **must not cross actor boundaries**. The detached tasks fetch their own posts; only `Sendable` values (Int counters, String URIs, enum cases) are sent back to the main actor.
- `@Query` on the main context updates when *any* `ModelContext` (including a background one) saves to the same store — usually within milliseconds. The charts and lists pick up scrape progress live.
- Never mutate the store with raw SQL. CoreData metadata (`Z_METADATA`, `Z_PRIMARYKEY`) becomes inconsistent. Use `ModelContext.delete` + `save`. (Learned the hard way; `AnnotationDedup` is the corrected pattern.)

---

## Key design decisions

1. **Depth-first scrape, per post.** For each account: feed-scrape, and for every newly-stored root post the coordinator immediately scrapes its full reply tree before fetching the next post. Replies appear live in the UI as the scrape progresses — no waiting for an account's entire feed history before any reply data shows up. Implemented via `FeedScraper.scrape(... onNewRootPost:)`.
2. **One annotation per `(post, modelName)`.** Prompt revisions don't trigger re-classification — the dedup key is `modelName` only. If you want a re-run, delete the annotation. The data model supports multiple annotations per post (a `gemma4:26b` annotation and a `qwen2.5:7b` annotation can coexist), enabling cross-model comparison.
3. **Annotation is decoupled from scraping.** Scraping never auto-annotates. The user explicitly triggers `Run Sentiment` or `Start LLM` from the Annotation Queue.
4. **Sentiment as a base layer, LLMs as carving.** The Posts-by-week and Replies-by-week stacked-area charts have a muted "Pending" base that shrinks as LLM classes (hate / counter / neutral) carve it up on top — so even a brand-new scrape with zero annotations already shows visible volume.
5. **Load + thermal management on long LLM runs.** `LLMPace` (Burst / Steady / Gentle) inserts a base inter-request sleep; `ThermalBackoff` automatically adds 3 s / 10 s extra when `ProcessInfo.thermalState` rises to `.serious` / `.critical`. A 72k-post overnight run won't pin the M4 at 100 °C.
6. **Reproducible app icon.** `tools/generate-app-icon.swift` renders the 1024 master via Core Graphics; `sips` downsamples to every macOS catalog size. The icon is version-controlled as the script, not just the PNG.

---

## Color system

`BlueXColors.swift` defines a dark-only palette. Three accessors map a `speechClass` string to a coordinated colour set:

- `Color.speechClassBorder(_:)` — the strong outline tone (used for the node colors in `ThreadGraphView`).
- `Color.speechClassBackground(_:)` — the muted fill (used in the stacked area charts).
- `Color.speechClassBadgeText(_:)` — the readable foreground for badge text.

`Color.pendingBackground` (a 45 %-opacity muted text) is the gray used everywhere a post has no annotation for the current source yet.

---

## Credentials

Bluesky credentials are stored in macOS Keychain via `KeychainCredentials`. Never in UserDefaults or files. App passwords (not account passwords) are used. The keychain service key is `net.pulsschlag.BlueX`.

---

## File map

Top-level only — see file headers for per-file responsibilities.

```
BlueX/
├── BlueXApp.swift                       Entry point; ModelContainer setup
├── Assets.xcassets/AppIcon.appiconset/  Generated app icon
├── BlueX.entitlements                   Network client + keychain access
├── Info.plist
├── Data/
│   ├── BlueXSchema.swift                Schema list + BlueXStore (URL + openContainer)
│   ├── TrackedAccount.swift
│   ├── AccountGroup.swift
│   ├── Post.swift
│   ├── Post+Annotations.swift           currentLLMAnnotation, nlTaggerAnnotation, etc.
│   ├── Annotation.swift
│   ├── AccountSnapshot.swift
│   ├── ScrapeLog.swift
│   ├── ModelConfig.swift                Includes promptHash(of:) static helper
│   ├── CoordinatorState.swift
│   ├── AccountSeeder.swift              Seeds accounts + presets, idempotent
│   ├── AnnotationDedup.swift            Launch-time (post, model) dedup
│   └── LLMPace.swift                    Pace enum + ThermalBackoff
├── Services/
│   ├── API/
│   │   ├── BlueskyAPIClient.swift
│   │   ├── BlueskyError.swift
│   │   ├── BlueskyStructs.swift
│   │   ├── KeychainCredentials.swift
│   │   └── ATProtoDate.swift            Shared ISO-8601 parser
│   ├── Scraping/
│   │   ├── FeedScraper.swift            Pagination + onNewRootPost callback
│   │   ├── ThreadScraper.swift          Recursive tree walk + scrapeThreadIfDue
│   │   ├── RescrapingPolicy.swift       Single-window rule
│   │   └── ScrapeCoordinator.swift      The state machine
│   └── Annotation/
│       ├── NLTaggerAnalyser.swift
│       ├── LocalModelClient.swift       Protocol + LLMAnnotation
│       ├── OllamaClient.swift
│       ├── MLXClient.swift              + OpenAICompatibleClient typealias
│       ├── LLMResponseParser.swift
│       └── AnnotationService.swift      Both passes; AsyncThrowingStream-based
├── ViewModels/
│   ├── SidebarViewModel.swift
│   ├── AccountViewModel.swift
│   ├── GroupViewModel.swift
│   ├── ThreadViewModel.swift
│   ├── ChartsViewModel.swift            WeekBucket aggregation
│   └── QueueViewModel.swift             fetchCount-based, capped pending list
└── Views/
    ├── RootView.swift                   3-column NavigationSplitView
    ├── BlueXColors.swift                Palette + speechClass* helpers
    ├── Sidebar/SidebarView.swift
    ├── Account/AccountContentView.swift
    ├── Account/AccountChartsView.swift
    ├── Group/GroupContentView.swift
    ├── Group/GroupChartsView.swift
    ├── Thread/PostRowView.swift
    ├── Thread/ThreadView.swift
    ├── Thread/ThreadGraphView.swift     Tree visualization + ColorSource picker
    ├── Thread/PostInspectorView.swift   Click-popover with all post metadata
    ├── Thread/SentimentIndicator.swift  Small bar used in rows + inspector
    ├── Thread/AnnotationBadge.swift
    ├── Queue/QueueView.swift            Sentiment / LLM run UI
    └── Settings/{Settings,CredentialsSettings,ModelSettings,ScrapingSettings}View.swift
cli/
├── Shared/CLISupport.swift               CancelFlag, SIGINT handler, progress writer
├── annotate/main.swift                   blueX-annotate — top-level entry point
└── scrape/main.swift                     blueX-scrape — top-level entry point
tools/
└── generate-app-icon.swift              Core Graphics renderer for the app icon
```

### Command-line tools

Two CLIs share the GUI's services and schema; they don't duplicate scraping or annotation logic. Both open the same SwiftData store and write back into it, so an unattended overnight CLI run is visible the next time you launch the GUI.

- **`blueX-annotate`** — runs the LLM annotation pass against the existing store. Picks the `isDefault` `ModelConfig` unless `--model <id>` is passed (`--list-models` enumerates them). `--pace burst|steady|gentle` controls the per-post sleep; `--limit <n>` caps the run. Progress bar reports posts processed, average time per post, ETA, and a thermal-state glyph (🟢 / 🟡 / 🔴) that escalates the cool-down automatically.
- **`blueX-scrape`** — runs the depth-first scrape (feed + reply trees) against active accounts. `--handle <h>` restricts to one account; `--limit <n>` caps new posts per account; `--max-window-days <n>` overrides the reply-tree refresh window for this run only; `--list-accounts` enumerates active accounts. Uses the same Keychain credentials as the GUI.

Both tools install a SIGINT handler so Ctrl-C stops cleanly at the next post boundary (the partial batch is already saved). Local install target: `~/.local/bin/`.

---

## Adding things

- **A new persisted field** → add it to the `@Model`, then add a backfill or migration if existing data needs it; SwiftData handles trivial additive changes automatically.
- **A new LLM provider** → conform to `LocalModelClient` and add a `ModelConfig` preset to `AccountSeeder.modelPresets`. The Queue picker, the pending-count predicate, and the dedup logic all work off `modelName` / `promptHash`, so nothing else changes.
- **A new chart** → extend `WeekBucket` with the new column, compute it in `ChartsViewModel.computeBuckets`, render it in `AccountChartsView` (or `GroupChartsView`). Use `.foregroundStyle(by: .value(…))` for stacking; do not pass cumulative y manually.
- **A new view that lives off post data** → use `@Query` with `relationshipKeyPathsForPrefetching = [\.annotations]` and consume `Post+Annotations.swift` accessors — never `post.annotations.last(where:)`.
