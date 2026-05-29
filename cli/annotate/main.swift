// cli/main.swift — blueX-annotate
//
// Standalone CLI that runs the same LLM annotation pass as the GUI, against the same
// SwiftData store at ~/Library/Application Support/BlueX/default.store. Shares
// OllamaClient, LLMPace, ThermalBackoff, ModelConfig and the @Model schema with the
// app target via shared source files in project.yml — no logic is duplicated.
//
//   blueX-annotate                       — run the default model at steady pace
//   blueX-annotate --model qwen2.5:7b    — pick a specific model from ModelConfig
//   blueX-annotate --pace gentle         — burst | steady | gentle (default: steady)
//   blueX-annotate --limit 500           — stop after N posts (default: no limit)
//   blueX-annotate --list-models         — print available ModelConfigs + exit
//   blueX-annotate --help                — usage

import Foundation
import SwiftData

// MARK: - Argument parsing

enum AnnotatePass: String {
    case llm                // hate / counter / neutral classification (default)
    case llmSentiment       // positive / neutral / negative sentiment
}

struct CLIArgs {
    var modelID: String?
    var pace: LLMPace = .steady
    var limit: Int?
    var concurrency: Int = 1
    var pass: AnnotatePass = .llm
    var listModels = false
    var help = false

    static func parse(_ args: [String]) -> CLIArgs {
        var a = CLIArgs()
        var i = 1
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "-h", "--help":         a.help = true
            case "--list-models":        a.listModels = true
            case "--model":
                i += 1; if i < args.count { a.modelID = args[i] }
            case "--pace":
                i += 1
                if i < args.count, let p = LLMPace(rawValue: args[i]) { a.pace = p }
                else if i < args.count {
                    fail("blueX-annotate", "invalid --pace value '\(args[i])'. Valid: burst, steady, gentle")
                }
            case "--limit":
                i += 1
                if i < args.count, let n = Int(args[i]), n > 0 { a.limit = n }
                else if i < args.count {
                    fail("blueX-annotate", "invalid --limit value '\(args[i])'")
                }
            case "--concurrency", "-j":
                i += 1
                if i < args.count, let n = Int(args[i]), n >= 1, n <= 32 { a.concurrency = n }
                else if i < args.count {
                    fail("blueX-annotate", "invalid --concurrency value '\(args[i])' (must be 1–32)")
                }
            case "--pass":
                i += 1
                if i < args.count {
                    switch args[i] {
                    case "llm": a.pass = .llm
                    case "llm-sentiment", "sentiment": a.pass = .llmSentiment
                    default:
                        fail("blueX-annotate", "invalid --pass value '\(args[i])'. Valid: llm, llm-sentiment")
                    }
                }
            default:
                fail("blueX-annotate", "unknown argument: \(arg). Run --help for usage.")
            }
            i += 1
        }
        return a
    }
}

let usage = """
usage: blueX-annotate [options]

  --model <id>       LLM modelID (e.g. qwen2.5:7b). Default: whichever ModelConfig
                     is marked isDefault, or the first one if none are.
  --pace <p>         burst   — no pause between requests
                     steady  — 0.5 s pause (default)
                     gentle  — 2 s pause; recommended for overnight runs
  --limit <n>        Stop after N posts. Default: process every pending post.
  --concurrency <n>, -j <n>
                     Number of classify() calls in flight at once. Default 1
                     (sequential). For Apple Foundation Models the Neural
                     Engine handles concurrency well — try 4–8. For Ollama the
                     local server is single-threaded per model, so keep at 1
                     unless you're hitting a remote endpoint. Max 32.
  --pass <p>         llm            — hate / counter / neutral classification
                                       using the model's prompt template (default)
                     llm-sentiment  — positive / neutral / negative sentiment
                                       classification, distinct prompt + class
                                       set; writes stage="llm-sentiment" so it
                                       sits alongside the NLTagger sentiment
                                       and the hate/counter annotation.
  --list-models      Print available ModelConfigs and exit.
  --help, -h         This help.

Reads from the BlueX SwiftData store at
  ~/Library/Application Support/BlueX/default.store
Writes annotations through the same store, so the GUI picks them up live.
Ctrl-C stops at the next post boundary (no data is lost — last batch is saved).

Thermal back-off: at ProcessInfo.thermalState .serious / .critical the loop
adds an extra 3 s / 10 s sleep after each post automatically, on top of pace.
"""

// MARK: - Progress bar

let barWidth = 32

func progressLine(processed: Int, total: Int, errors: Int,
                  elapsed: TimeInterval, thermal: ProcessInfo.ThermalState,
                  modelID: String, paceLabel: String) -> String {
    let pct = total == 0 ? 0.0 : Double(processed) / Double(total)
    let filled = Int((Double(barWidth) * pct).rounded())
    let bar = String(repeating: "█", count: filled)
              + String(repeating: "░", count: barWidth - filled)
    let perPost: Double? = processed > 0 ? elapsed / Double(processed) : nil
    let avgStr: String = perPost.map(formatPerPost) ?? "—"
    let etaStr: String = {
        guard let perPost, processed < total else { return "—" }
        return formatDuration(perPost * Double(total - processed))
    }()
    let thermalGlyph: String = {
        switch thermal {
        case .nominal:  return "🟢"
        case .fair:     return "🟢"
        case .serious:  return "🟡 cooling"
        case .critical: return "🔴 hot"
        @unknown default: return "?"
        }
    }()
    let errStr = errors > 0 ? "  \(errors) err" : ""
    return String(
        format: "%@ · %@  [%@] %5.1f%%  %d/%d%@  avg %@  ETA %@  %@",
        modelID, paceLabel, bar, pct * 100, processed, total, errStr, avgStr, etaStr, thermalGlyph
    )
}

/// Per-post duration formatter. LLM calls are typically 0.5–5 s, so seconds with
/// a decimal reads cleanly; below 100 ms we show as ms; above 60 s we hand off to
/// `formatDuration` for the m/s split.
func formatPerPost(_ seconds: TimeInterval) -> String {
    if seconds < 0.1 {
        return String(format: "%dms", Int(seconds * 1000))
    }
    if seconds < 60 {
        return String(format: "%.1fs", seconds)
    }
    return formatDuration(seconds)
}

// formatDuration / writeProgress now live in cli/Shared/CLISupport.swift.

// MARK: - Main

// `main.swift` is the implicit entry point — top-level code becomes `main`. We
// can't use `@main` here because that would conflict with top-level declarations
// like `usage` and `barWidth` above.
func runCLI() async {
        let args = CLIArgs.parse(CommandLine.arguments)
        if args.help { print(usage); return }

        let container: ModelContainer
        do { container = try BlueXStore.openContainer() }
        catch { fail("blueX-annotate", "failed to open store: \(error)") }
        let context = ModelContext(container)

        // ---- list-models mode
        if args.listModels {
            let configs = (try? context.fetch(FetchDescriptor<ModelConfig>())) ?? []
            for cfg in configs.sorted(by: { $0.name < $1.name }) {
                let mark = cfg.isDefault ? "*" : " "
                print("\(mark) \(cfg.modelID.padding(toLength: 20, withPad: " ", startingAt: 0))  \(cfg.endpoint)   \(cfg.name)")
            }
            print("\n(* = isDefault. Pass any modelID with --model.)")
            return
        }

        // ---- pick model
        let configs = (try? context.fetch(FetchDescriptor<ModelConfig>())) ?? []
        let modelCfg: ModelConfig?
        if let id = args.modelID {
            modelCfg = configs.first { $0.modelID == id }
        } else {
            modelCfg = configs.first { $0.isDefault } ?? configs.first
        }
        guard let cfg = modelCfg else {
            fail("blueX-annotate", "no ModelConfig found in the store. Launch the GUI once to seed defaults, or run --list-models to inspect.")
        }
        // For the sentiment pass we ignore Apple Foundation Models (guardrails block
        // it on hateful inputs anyway) and the ModelConfig's prompt template. We
        // build an Ollama client directly with the sentiment prompt + class set.
        // For the classification pass the factory's normal dispatch applies.
        let client: any LocalModelClient
        let stageTag: String
        let signedSentimentScore: Bool
        switch args.pass {
        case .llmSentiment:
            // Sentiment uses a different prompt + class set, but every other
            // dispatch concern (Apple? Cerebras? Ollama? auth header?) is the
            // same as the classification pass, so route through the factory
            // with the overrides applied.
            do {
                client = try ModelClientFactory.make(
                    from: cfg,
                    promptOverride: ModelConfig.defaultSentimentPromptTemplate,
                    validClasses: LLMResponseParser.positiveNeutralNegative
                )
            } catch {
                fail("blueX-annotate", "could not build sentiment client for \(cfg.modelID): \(error.localizedDescription)")
            }
            stageTag = "llm-sentiment"
            signedSentimentScore = true
        case .llm:
            do {
                client = try ModelClientFactory.make(from: cfg)
            } catch {
                fail("blueX-annotate", "could not build client for \(cfg.modelID): \(error.localizedDescription)")
            }
            stageTag = "llm"
            signedSentimentScore = false
        }

        // ---- cancel handler (Ctrl-C)
        let cancel = installSIGINTHandler(notice: "\n\nstopping after current post — please wait…\n")

        // ---- build pending set, scoped to this (stage, model) pair
        let currentModelName = cfg.modelID
        let currentStage = stageTag
        let alreadyDone: Set<String>
        do {
            let matched = try context.fetch(FetchDescriptor<Annotation>(
                predicate: #Predicate { $0.stage == currentStage && $0.modelName == currentModelName }
            ))
            alreadyDone = Set(matched.compactMap { $0.post?.uri })
        } catch {
            fail("blueX-annotate","failed to read existing \(cfg.modelID) annotations: \(error)")
        }

        var allDesc = FetchDescriptor<Post>(sortBy: [SortDescriptor(\Post.createdAt, order: .reverse)])
        allDesc.relationshipKeyPathsForPrefetching = [\.annotations]
        let allPosts: [Post]
        do { allPosts = try context.fetch(allDesc) }
        catch { fail("blueX-annotate","failed to fetch posts: \(error)") }

        var pending = allPosts.filter { !alreadyDone.contains($0.uri) }
        if let limit = args.limit, pending.count > limit {
            pending = Array(pending.prefix(limit))
        }
        let total = pending.count

        if total == 0 {
            print("Nothing to do — every post already has a \(cfg.modelID) annotation.")
            return
        }

        // ---- run
        let concurrencyTag = args.concurrency > 1 ? " · j=\(args.concurrency)" : ""
        let passTag = (args.pass == .llmSentiment) ? " · sentiment" : ""
        print("Annotating \(total) posts · \(cfg.modelID) · pace \(args.pace.rawValue)\(concurrencyTag)\(passTag)\n")

        let runStart = Date()

        // Build a uri→Post lookup so the LLM tasks can return just the URI (a Sendable
        // String) and the main actor re-binds to the @Model when persisting. @Model
        // instances cannot cross actor boundaries safely.
        var postsByURI: [String: Post] = [:]
        for post in pending { postsByURI[post.uri] = post }

        // Per-call payload (Sendable) sent into each task.
        struct PendingClassify: Sendable {
            let uri: String
            let text: String
            let language: String
            let baselineSentiment: Double
        }
        let queue: [PendingClassify] = pending.map { post in
            let baseline = post.nlTaggerAnnotation
            return PendingClassify(
                uri: post.uri,
                text: post.text,
                language: baseline?.detectedLanguage ?? "other",
                baselineSentiment: baseline?.sentimentScore ?? 0.0
            )
        }

        struct Outcome: Sendable {
            let item: PendingClassify
            let result: Result<LLMAnnotation, Error>
        }

        let modelName = client.modelName
        let modelVersion = client.modelVersion
        let promptHashValue = client.promptHash
        var processed = 0
        var errors = 0
        let saveEvery = 20
        var sinceSave = 0

        // Persist one completed classification (called on the controller actor after
        // a task returns). Re-find the post by URI so we never carry a Sendable-violating
        // @Model reference across the await boundary.
        func persist(_ outcome: Outcome) {
            guard let post = postsByURI[outcome.item.uri] else { return }
            switch outcome.result {
            case .success(let result):
                // For the LLM-sentiment pass, derive a signed sentimentScore from the
                // class label so charts pick it up directly. For the hate/counter pass,
                // preserve the NLTagger baseline.
                let scoreToStore: Double
                if signedSentimentScore {
                    switch result.speechClass {
                    case "positive": scoreToStore = result.confidence
                    case "negative": scoreToStore = -result.confidence
                    default:         scoreToStore = 0.0
                    }
                } else {
                    scoreToStore = outcome.item.baselineSentiment
                }
                let annotation = Annotation(
                    speechClass: result.speechClass,
                    sentimentScore: scoreToStore,
                    detectedLanguage: outcome.item.language,
                    modelName: modelName,
                    modelVersion: modelVersion,
                    promptHash: promptHashValue,
                    rawResponse: result.rawResponse,
                    stage: currentStage,
                    severity: result.severity,
                    confidence: result.confidence,
                    reasoning: result.reasoning
                )
                annotation.post = post
                context.insert(annotation)
                post.needsReAnnotation = false
                processed += 1
                sinceSave += 1
                if sinceSave >= saveEvery {
                    try? context.save()
                    sinceSave = 0
                }
            case .failure:
                errors += 1
            }
        }

        // Bounded-concurrency TaskGroup. Keep `concurrency` classify() calls in flight;
        // as each completes we look it up by URI, write the Annotation, and (if we
        // still have work + we're not cancelled) submit the next one.
        //
        // Pace and thermal back-off apply BETWEEN task submissions, not inside the
        // classify() body. At concurrency 1 the cadence matches the old sequential
        // path exactly; at higher concurrency the back-off becomes a global throttle
        // — the system catches up at the same rate, the work just spreads across more
        // workers in between.
        let pace = args.pace
        let concurrency = max(1, args.concurrency)
        var queueIter = queue.makeIterator()
        await withTaskGroup(of: Outcome.self) { group in
            var inflight = 0

            // Helper: submit the next queue item if any.
            func submitNext() -> Bool {
                guard !cancel.isSet, let item = queueIter.next() else { return false }
                let clientRef = client
                group.addTask {
                    do {
                        let r = try await clientRef.classify(text: item.text, language: item.language)
                        return Outcome(item: item, result: .success(r))
                    } catch {
                        return Outcome(item: item, result: .failure(error))
                    }
                }
                inflight += 1
                return true
            }

            // Initial fill.
            for _ in 0..<concurrency { if !submitNext() { break } }

            while inflight > 0 {
                guard let outcome = await group.next() else { break }
                inflight -= 1
                persist(outcome)

                let thermal = ProcessInfo.processInfo.thermalState
                let elapsed = Date().timeIntervalSince(runStart)
                writeProgress(progressLine(
                    processed: processed, total: total, errors: errors,
                    elapsed: elapsed, thermal: thermal,
                    modelID: cfg.modelID, paceLabel: args.pace.rawValue
                ))

                // Pace + thermal back-off — applied at task-submission time so it
                // throttles the rate of new work, not each classify() call.
                let cooldown = pace.baseDelayNanoseconds
                    + ThermalBackoff.extraDelayNanoseconds(for: thermal)
                if cooldown > 0 {
                    try? await Task.sleep(nanoseconds: cooldown)
                }
                _ = submitNext()
            }
        }

        if sinceSave > 0 { try? context.save() }

        // Final newline so the next prompt isn't on the progress line
        FileHandle.standardOutput.write(Data("\n".utf8))
        let elapsed = Date().timeIntervalSince(runStart)
        let interrupted = cancel.isSet ? "  (interrupted)" : ""
        print("Done · \(processed)/\(total) processed · \(errors) errors · \(formatDuration(elapsed)) elapsed\(interrupted)")
}

await runCLI()
