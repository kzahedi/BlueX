# BlueX — Nightly Scrape + Cheap Sentiment (2026-08-04)

Restore unattended scraping on `macmini.local`, and replace the LLM annotation pass
with Apple's on-device NLTagger sentiment. Priorities, in order: **reply-tree
scraping**, **simple sentiment**, semantic checker deferred.

## Problem

Scraping has been dead for **61 consecutive days**. Last store write: 2026-06-04 11:00.
Two independent faults, both verified:

1. **DarkWake + external volume.** `pmset` has `sleep 1`, so the mini sleeps after one
   minute idle and the launchd calendar events fire during DarkWake/PowerNap windows.
   In DarkWake `/Volumes/Eregion` (`Device Location: External`) is not mounted, so
   `/bin/zsh` cannot open the job script → `can't open input file` → exit 127. Observed
   today: DarkWake `08:30:18` → annotate fired `08:35` → slept `08:36:33`. 61 identical
   lines in both `launchd.scrape.err.log` and `launchd.annotate.err.log`.
2. **Broken CLI symlinks.** `~/.local/bin/blueX-{scrape,annotate}` point into a deleted
   DerivedData directory, so even a successful DarkWake run would have died at exec.

Aggravating factor: repeated `Dark Wake Thermal Emergency` sleeps (08:36, 09:01, 09:22)
cut DarkWake windows short, so a long job cannot live in one.

At the time of the outage the SwiftData store was at
`~/Library/Application Support/BlueX/default.store`, on the internal disk and
unaffected — only scripts and binaries sat on the volume that vanishes. The store has
since been moved to Eregion by request; see "Store on the external volume" below, which
is why the mount state now matters to the job as well as to the scripts.

## Constraints

- **Sleep configuration changed mid-project (2026-08-04).** At 11:21 `pmset` read
  `sleep 1` (idle-sleep after one minute) — that is the machine the outage happened on,
  and the DarkWake diagnosis above is from that state. By 14:09 it read **`sleep 0`**
  (never idle-sleep); the mini had then been continuously awake since 09:33:59, last
  sleeping at 09:22:19. Other settings unchanged: `powernap 1`, `womp 1`,
  `displaysleep 10`, `disksleep 10`, repeating `wakepoweron at 6:55AM`.
  The design assumes `sleep 0` but must degrade gracefully if it changes back — it has
  changed once already today.
- **`man pmset`: "you may only have one pair of repeating events scheduled — a 'power
  on' event and a 'power off' event."** The 06:55 `wakepoweron` already occupies that
  slot, so a second repeating wake at 03:30 is impossible without destroying it.
- **`pmset schedule` requires root.** Verified: `pmset schedule wake "08/05/26 03:30:00"`
  → `pmset: This operation must be run as root`, exit 1, no event created. An
  unprivileged LaunchAgent cannot arm its own wake — which is why the design avoids
  needing a wake at all rather than adding a privileged component to schedule one.
- **Keychain and notifications require the user's Aqua session.** The scrape reads
  Bluesky credentials from the user Keychain and alerting uses `osascript`, so the
  working job must be a user LaunchAgent, not a root LaunchDaemon.
- **Must not interfere with daily operations.** No scraping or annotation during
  working hours.
- Personal projects stay on `/Volumes/Eregion` per the global convention. Relocating
  the repo is not an acceptable fix.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Run window | Dedicated pre-dawn, 03:30 | Machine unused; full wake, not DarkWake; best thermal headroom |
| Wake mechanism | **None** — the mini is set to never idle-sleep (`sleep 0`), so launchd fires the 03:31 agent while it is awake | Removes the root LaunchDaemon, the `sudo` step and the only privileged component. `pmset schedule` needs root, so avoiding it entirely is worth more than the insurance |
| Alerting | Notification on failure + staleness watchdog at 06:56 | Watchdog catches the "never even started" mode that caused the 61-day gap |
| Gap handling | **Clean slate** — fresh empty store, old corpus archived | Chosen 2026-08-04; removes the migration, the catch-up run and the only irreversible step. See "Clean slate" below |
| Store location | `/Volumes/Eregion/bluex-data/default.store` | Internal disk at 96% (18Gi free); Eregion has 627Gi. The reply-tree corpus grows without bound |
| Sentiment model | Apple NLTagger (`stage: "nltagger"`) | Only viable option at corpus scale (hundreds of thousands of posts); already implemented and tested |
| Semantic checker | Deferred; Apple Foundation Models is the candidate | Confirmed `AVAILABLE` on macOS 26.5.1 with permissive guardrails |

### Why NLTagger and not Foundation Models

Measured on the pre-clean-slate store: **797,253 posts**; `nltagger` 2,600 (0.33%),
`llm-sentiment` 30,854, `llm` 1,179 — a sentiment backlog of **~794,700 posts**. The
clean slate resets those counts to zero, but the argument is unchanged: the rebuilt
corpus grows to the same order of magnitude, and sentiment must keep up with it.

- NLTagger: microseconds per post, no network, no Ollama.
- Foundation Models (~3B, on-device): at ~0.3–1 s/post the same backlog is **66 hours
  to 9 days**. Infeasible for full-corpus sentiment.

Foundation Models is therefore reserved for the semantic checker, run over a sample.
`AppleFoundationModelClient.swift` already exists and reports available.

### NLTagger quality caveats (measured, German corpus)

| Score | Lang | Text |
|---|---|---|
| 1.0 | de | Das ist eine wunderbare Nachricht, ich freue mich sehr! |
| 0.4 | de | China ihr Kackhaufen |
| 0.2 | **pl** | Nazi Kolonie |
| −0.8 | de | Haha lol vergewaltigung |
| 1.0 | de | Man kann den Israelis nur empfehlen, auszuwandern |
| 0.2 | de | Ich bin seit 40 Jahren Abonnent, aber dieser Artikel ist Mist |
| 0.4 | de | Die Bundesregierung hat heute ein neues Gesetz beschlossen. |
| 1.0 | de | Danke für diesen tollen Beitrag! |
| −0.4 | de | Du bist ein widerlicher Mensch und solltest verschwinden |

1. **Positive skew** — neutral news scores `0.4`, not `0`. Baseline is not centred.
2. **Contrastive text breaks it** — reproduces the failure already documented at
   `ModelConfig.swift:124`.
3. **Short insults read positive.**
4. **Language misdetection on short strings.**

Caveats 2–4 are hate-classification failures, deferred to the semantic checker.
Caveat 1 affects sentiment directly. **Mitigation:** store raw scores only; put no
threshold in the writer. `ChartsViewModel.swift:77` already averages raw values, so
trends stay valid and calibration stays a later, reversible decision.

## Architecture

Nothing on `/Volumes/Eregion` is on the runtime path. The repo remains the source of
truth; an install script copies job scripts to the internal disk, and the plists point
at the installed copies.

| Component | Location | Purpose |
|---|---|---|
| `bluex-nightly.sh` | installed → `~/Library/Application Support/BlueX/jobs/` | Sole working entry point: preflight → caffeinate → lock → scrape → sentiment → heartbeat |
| `bluex-watchdog.sh` | same | Runs 06:56 on the existing wake; notifies if heartbeat or store is stale. Notification only |
| `install-jobs.sh` | `tools/` (repo, version controlled) | Builds CLIs to a stable path, installs scripts + plists, loads agents/daemon. Idempotent |
| `net.pulsschlag.bluex.nightly.plist` | `~/Library/LaunchAgents/` | `StartCalendarInterval` 03:31 |
| `net.pulsschlag.bluex.watchdog.plist` | `~/Library/LaunchAgents/` | `StartCalendarInterval` 06:56 |

**No privileged component.** Everything runs as user LaunchAgents. `install-jobs.sh`
never calls `sudo`, nothing lands in `/Library/LaunchDaemons` or `/usr/local/libexec`,
and no `pmset` state is modified.

**Degradation if `sleep` is re-enabled** (it changed once on 2026-08-04, so this is a
real scenario, not a hypothetical): launchd replays the missed 03:31 calendar event on
the next wake, so the job still runs — just later. If that wake is a DarkWake with
`/Volumes/Eregion` unmounted, `bluex_wait_for_store` times out after 180s and the job
notifies and exits 75. Both paths are loud. The `caffeinate` assertion is retained for
the same reason: it costs nothing and protects a long run if idle-sleep returns.

This **replaces** the two current jobs. Today the shared store-lock makes annotate
silently `exit 0` when scrape overruns; running the two sequentially inside one wrapper
makes that ordering structural instead of a race, and needs one `caffeinate` and one
lock acquisition.

### Binary stability

`install-cli.sh` symlinks into DerivedData, which got cleaned — fault 2. Fix: build with
`-derivedDataPath ~/.local/share/bluex-build` and symlink there. This keeps the
symlink-not-copy approach (necessary for the Sequoia provenance `SIGKILL` documented in
`install-cli.sh:24-29`) while surviving an Xcode clean.

### Data flow

```
03:31  launchd fires bluex-nightly.sh (user agent, script on internal disk).
       No wake needed: the mini never idle-sleeps.
       wait for /Volumes/Eregion to mount (bounded; notify + exit if it never does)
       preflight: binaries, store, Keychain credentials
       caffeinate -i -s held for the whole run
       acquire store lock (atomic mkdir, existing 18h stale reclaim)
       blueX-scrape   --pace gentle --max-window-days 7
       blueX-annotate --pass nltagger        (incremental)
       release lock + caffeinate (trap EXIT)
       write ~/Library/Logs/BlueX/last-run.json
       exit → mini stays awake (sleep 0)
06:55  existing wakepoweron (unchanged, untouched)
06:56  bluex-watchdog.sh (user agent) → notify if stale
```

## Code changes

### Clean slate

Decided 2026-08-04, after the store-relocation decision. Rather than migrating the
existing 456MB corpus, BlueX starts from an empty store on Eregion and re-scrapes.

The old corpus is archived, not destroyed:
`/Volumes/Eregion/bluex-archive/default.store.2026-08-04-preclean` — verified
797,253 posts, 6 accounts, annotations `llm` 1,179 / `llm-sentiment` 30,854 /
`nltagger` 2,600.

**What this removes from the plan:** the store migration, the
`--max-window-days 70` catch-up, and the one-way door — the only irreversible step
the design previously contained.

**Why it works mechanically.** `RescrapingPolicy` documents an explicit invariant:
*"every post is scraped completely at least once"* — a post whose `replyTreeStatus`
is not `.complete` is due on every run **regardless of age**. `Post.init` sets
`.pending`, so on an empty store every root post has its reply tree fetched on first
encounter, however old. `--max-window-days` only governs *re*-scraping of trees
already marked `.complete`, so it is irrelevant to the initial run.

**Account data survives at zero cost.** `AccountSeeder.seeds` hardcodes all six
accounts (DIDs, handles, display names, groups) and `seed(into:)` populates any store
with no accounts. `ensureModelConfigs` does the same for model settings. Verified on the rebuilt store: all three groups (All Media, German Media,
International Media) and 9 ModelConfigs are recreated identically to the archive.
Nothing is lost from the configuration.

**Accepted trade-off, recorded because it is real and non-obvious.** A fresh scrape
returns what exists *today*. Replies deleted, deauthored or moderated away since 2018
are unrecoverable, and for a hate-speech / counter-speech corpus that erosion is
**not random** — moderation removes disproportionately the hateful content this
project studies. The rebuilt corpus is therefore expected to be cleaner than reality.
This was raised and the trade-off accepted; the archive exists for comparison.

**Cost.** ~48,684 root threads at `--pace gentle` (2s per thread request) is on the
order of 27+ hours before pagination — a multi-day job spanning several nightly
windows. The `.pending` retry invariant makes interruption safe: an incomplete run
simply resumes.

### Store on the external volume

Added 2026-08-04 on request: the reply-tree corpus must live on Eregion. The internal
disk was at **96% (18Gi free)** holding a 456MB store, against **627Gi free** on Eregion.
After archiving the old corpus to Eregion the internal disk is at 92% (32Gi free); the
rebuilt corpus will grow to a comparable size and belongs on the large volume.

New location: `/Volumes/Eregion/bluex-data/default.store`, matching the existing
top-level `mbsr-data/` naming convention. `BlueXStore` is the single point of change —
the GUI and both CLIs already route through `BlueXStore.openContainer()`.

**This makes the mount state load-bearing**, which needs care given the outage:

- The 03:30 wake is a **full** wake, where external volumes mount normally. The outage
  was specific to DarkWake, so the nightly path is sound.
- `BlueXStore.openContainer()` throws a named `volumeNotMounted` error rather than
  silently creating an empty store at a path that happens to be absent. Creating a
  second, empty store would be the worst outcome — it looks like success.
- `bluex-nightly.sh` waits for the mount with a bounded timeout, then notifies and
  exits rather than hanging a launchd job indefinitely.
- The **job scripts themselves stay on the internal disk.** That part of the original
  fix is unchanged and non-negotiable: launchd execs them, and launchd can fire during
  DarkWake. Only the *data* moves.
- The GUI cannot open the store while the drive is detached. Accepted: this is a Mac
  mini with a permanently attached drive.

The path is overridable via the `BLUEX_STORE_DIR` environment variable, which keeps the
location testable and lets it move again without a rebuild.

### 0. Extract `NLTaggerPass` so the CLI can reuse it

`project.yml:64-66` **excludes** `AnnotationService.swift` from the `BlueXAnnotate`
target — the project deliberately keeps `@Observable`/GUI-coupled code out of CLI
targets (`ScrapeCoordinator.swift` is excluded from `BlueXScrape` for the same reason).
So the CLI cannot call `AnnotationService.runNLTaggerPass` at all.

Extract the paging + tagging loop into `BlueX/Services/Annotation/NLTaggerPass.swift`:
a plain struct, no `Observation`, no `@MainActor`, directly unit-testable, taking an
optional progress callback. `AnnotationService.runNLTaggerPass` delegates to it and
keeps its `@Observable` progress publishing; the CLI calls it directly. One
implementation, two consumers — no duplicated loop.

`BlueX/Services/Annotation/` is already in the `BlueXAnnotate` target, so only the one
excluded file stays excluded.

### 1. Expose `--pass nltagger` in `blueX-annotate`

`AnnotatePass` in `cli/annotate/main.swift:20` has only `.llm` and `.llmSentiment`.
`ScrapeCoordinator.runNLTaggerAnnotation()` and
`AnnotationService.runNLTaggerPass(batchSize: 200)` already exist, run on a background
`ModelContext` with batched saves, and are covered by
`BlueXTests/Services/ScrapeCoordinatorAnnotationTests.swift`. This is thin wiring.

Spelling is `nltagger`, matching the existing stage string and the
`--reset-annotations` vocabulary.

### 2. Fix the pending-posts fetch (required at corpus scale)

`AnnotationService.swift:61`:

```swift
let pending = try context.fetch(FetchDescriptor<Post>())
    .filter { !$0.hasNLTaggerAnnotation }
```

This materialises all 797k posts, then filters in Swift, and `hasNLTaggerAnnotation`
faults the `annotations` relationship per post. Acceptable at 2,600 annotations; not at
795k. The replacement lands in `NLTaggerPass` (section 0) and does three things:

1. Fetch the URIs that already carry an `nltagger` annotation into a `Set<String>` once
   — 2,600 rows today. This mirrors the `alreadyDone` pattern already proven at
   `cli/annotate/main.swift:361-370`, and avoids relationship faulting entirely.
2. Page `Post` with `fetchLimit`/`fetchOffset` over a stable sort (`\Post.uri`).
   Inserting annotations does not change the `Post` count, so offsets stay valid.
3. Use a fresh `ModelContext` per page so the context does not accumulate 795k
   registered objects.

It also gains a `limit` parameter, without which the Phase 1 throughput measurement
is impossible.

This is a targeted fix to code the work depends on, not unrelated refactoring.

## Error handling

- Non-zero exit from either CLI → `osascript` notification with exit code and log path.
  The run still proceeds to the re-arm step, so the chain never dies from one bad night.
- Missing or non-executable binary → distinct message naming `install-jobs.sh` as the
  fix; exit 78.
- `caffeinate` and the store lock both released via `trap … EXIT`; keep the existing
  18h stale-lock reclaim.
- Watchdog: notify when heartbeat age **or** store mtime exceeds **48h**. Using both
  distinguishes "ran but scraped nothing" from "never ran".
- **There is no scheduling chain to break.** The 03:31 agent is a plain calendar event;
  nothing has to arm it, so no failure can stop future runs.
- If the machine is asleep at 03:31 (only possible if `sleep` is re-enabled), launchd
  replays the event on the next wake; a DarkWake with the volume unmounted exits 75 with
  a notification rather than failing silently.

The earlier "skip annotate if Ollama is unreachable" branch is **removed** — NLTagger
has no external dependency.

## Testing

The risk is silent misconfiguration, so tests target exactly that:

- Assert no installed plist or job script references `/Volumes/` — this is the
  regression that caused the outage.
- `--preflight` flag: verify binaries, store, and Keychain credentials without
  scraping. Keychain access from an unattended pre-dawn run is the untested unknown.
- End-to-end: `launchctl kickstart -k`, then confirm a fresh per-run log and a bumped
  store mtime.
- `--pass nltagger` wiring covered by extending the existing annotation tests.

Python tooling follows the pytest convention already established in `tools/benchmark/`.

## Rollout

Two phases: a clean-slate start, then steady state.

**Phase 1 — once, attended.** Nothing here is irreversible: the old corpus is already
archived on Eregion, so the worst case is re-scraping again.

1. **Retire the old internal store.** With the GUI closed and no job running, delete
   `~/Library/Application Support/BlueX/default.store`. The archive at
   `/Volumes/Eregion/bluex-archive/default.store.2026-08-04-preclean` is the record
   (verified 797,253 posts / 6 accounts). Frees ~456MB on the internal disk.
2. `install-jobs.sh` — build CLIs, install scripts and plists. No `sudo` required.
3. `bluex-nightly.sh --preflight` — verify binaries, store and Keychain credentials.
   This is also the first real test of unattended Keychain access.
4. **Verify the fresh store seeds correctly.** A first CLI or GUI run must create
   `/Volumes/Eregion/bluex-data/default.store` and auto-seed 6 accounts and 2 groups.
   Confirm before scraping — an empty account list would silently scrape nothing.
5. **Initial scrape.** `blueX-scrape --pace gentle` (the default 14-day window is fine;
   `--max-window-days` does not affect never-scraped posts). Expect 27+ hours over
   several nightly windows. Safe to interrupt: `.pending` trees are retried.
6. `blueX-annotate --pass nltagger` — sentiment over whatever has been scraped.
   Cheap and incremental; no separate backfill phase is needed.

**Phase 2 — nightly.** Enable the 03:31 agent and the 06:56 watchdog.
Until the initial scrape converges the nightly runs continue it; afterwards each run is
one day of new posts, which is small.

## Open items

- **NLTagger throughput on this store is unmeasured.** The 9-sample test was dominated
  by Swift compile time. Phase 1 step 2 exists to measure it rather than guess; no
  backfill duration is asserted in this spec.
- **Keychain access at 03:30 is unverified.** It worked before June, but an unattended
  run is where Keychain ACLs bite. `--preflight` tests this before the schedule is
  trusted.
- **Thermal behaviour on the first night** should be checked, though NLTagger replacing
  phi4:14b removes most of the sustained load.

## Explicitly out of scope

- The semantic / hate checker. `--pass llm` stays in the CLI, unused by the nightly job,
  so it can slot in later without rework. The benchmark harness in `tools/benchmark/`
  and its open items (no true-positive hate examples, 3 borderline posts unreviewed)
  are untouched.
- Sentiment threshold calibration for the positive skew.
- Relocating the repo off `/Volumes/Eregion`.
- Changing any `pmset` power setting, including the 06:55 repeating wake.
