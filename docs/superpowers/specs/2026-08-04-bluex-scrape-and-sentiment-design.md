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

The SwiftData store at `~/Library/Application Support/BlueX/default.store` is on the
internal disk and unaffected. Only scripts and binaries sit on the volume that vanishes.

## Constraints

- **Keep the current sleep/wake settings.** `sleep 1`, `powernap 1`, `womp 1`,
  `displaysleep 10`, `disksleep 10`, and the repeating `wakepoweron at 6:55AM`.
- **`man pmset`: "you may only have one pair of repeating events scheduled — a 'power
  on' event and a 'power off' event."** The 06:55 `wakepoweron` already occupies that
  slot, so a second repeating wake at 03:30 is impossible without destroying it.
- **`pmset schedule` requires root.** Verified: `pmset schedule wake "08/05/26 03:30:00"`
  → `pmset: This operation must be run as root`, exit 1, no event created. An
  unprivileged LaunchAgent therefore cannot arm its own wake.
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
| Wake mechanism | Root LaunchDaemon at 07:00 arms a one-shot `pmset schedule wake` for 03:30 | `pmset` needs root; `pmset repeat` slot is taken by 06:55; privilege split keeps Keychain + notifications in the user session |
| Alerting | Notification on failure + staleness watchdog at 06:56 | Watchdog catches the "never even started" mode that caused the 61-day gap |
| Gap handling | One-off attended `--max-window-days 70` catch-up first | First normal run permanently freezes gap-era reply trees; one-way door |
| Sentiment model | Apple NLTagger (`stage: "nltagger"`) | Only viable option at 795k posts; already implemented and tested |
| Semantic checker | Deferred; Apple Foundation Models is the candidate | Confirmed `AVAILABLE` on macOS 26.5.1 with permissive guardrails |

### Why NLTagger and not Foundation Models

Store state: **797,253 posts**; `nltagger` 2,600 (0.33%), `llm-sentiment` 30,854,
`llm` 1,179. The sentiment backlog is **~794,700 posts**.

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
| `bluex-arm-wake.sh` | installed → `/usr/local/libexec/bluex/` (root-owned) | Arms the next 03:30 one-shot wake. The only privileged component |
| `install-jobs.sh` | `tools/` (repo, version controlled) | Builds CLIs to a stable path, installs scripts + plists, loads agents/daemon. Idempotent |
| `net.pulsschlag.bluex.nightly.plist` | `~/Library/LaunchAgents/` | `StartCalendarInterval` 03:31 |
| `net.pulsschlag.bluex.watchdog.plist` | `~/Library/LaunchAgents/` | `StartCalendarInterval` 06:56 |
| `net.pulsschlag.bluex.armwake.plist` | `/Library/LaunchDaemons/` | Root, `StartCalendarInterval` 07:00 |

**Privilege split.** The daemon does exactly one thing — call `pmset` — and holds no
credentials and no store access. The agent does all the work and needs no elevation.
Arming at 07:00 (after the 06:55 `wakepoweron`, when the machine is reliably awake) means
re-arming is independent of whether the previous night's run succeeded.

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
03:30  one-shot pmset full wake (armed yesterday at 07:00 by the daemon)
03:31  launchd fires bluex-nightly.sh (user agent, internal disk)
       preflight: binaries, store, Keychain credentials
       caffeinate -i -s held for the whole run
       acquire store lock (atomic mkdir, existing 18h stale reclaim)
       blueX-scrape   --pace gentle --max-window-days 7
       blueX-annotate --pass nltagger        (incremental)
       release lock + caffeinate (trap EXIT)
       write ~/Library/Logs/BlueX/last-run.json
       exit → mini idles → sleeps after 1 min
06:55  existing wakepoweron (unchanged)
06:56  bluex-watchdog.sh (user agent) → notify if stale
07:00  bluex-arm-wake.sh (root daemon) → pmset schedule wake tomorrow 03:30
```

## Code changes

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

### 2. Fix the pending-posts fetch (required for a 795k backfill)

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
- **Arming cannot be broken by a failed run.** The daemon arms at 07:00 unconditionally,
  driven by the 06:55 `wakepoweron` rather than by the previous night's job. There is no
  chain to break — which is why the watchdog needs no re-arm responsibility.
- Daemon failure (e.g. `pmset` error) → logged to
  `/var/log/bluex-armwake.log`; the missing 03:30 wake shows up as a stale heartbeat at
  the next 06:56 watchdog run.

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

Two phases, because backfill and steady-state have different shapes.

**Phase 1 — once, attended.** Measure before committing to durations.

1. `install-jobs.sh` — build CLIs, install scripts and plists. Prompts for `sudo` once,
   to install the root arm-wake daemon.
2. `bluex-nightly.sh --preflight` — verify binaries, store, and Keychain credentials.
3. `blueX-annotate --pass nltagger --limit 2000` — measure real throughput.
4. `blueX-scrape --pace gentle --max-window-days 70` — reply-tree catch-up for the
   61-day gap. **One-way door:** a normal run freezes these trees permanently, so this
   must precede any `--max-window-days 7` run.
5. Full NLTagger backfill over the ~795k backlog.

**Phase 2 — nightly.** Enable the 03:31 agent, the 06:56 watchdog, and the 07:00 daemon.
Incremental only: one day of new posts, which is small.

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
