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

struct CLIArgs {
    var modelID: String?
    var pace: LLMPace = .steady
    var limit: Int?
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
        let client = OllamaClient(
            modelName: cfg.modelID,
            endpoint: cfg.endpoint,
            promptTemplate: cfg.promptTemplate
        )

        // ---- cancel handler (Ctrl-C)
        let cancel = installSIGINTHandler(notice: "\n\nstopping after current post — please wait…\n")

        // ---- build pending set, scoped to this model only
        let currentModelName = cfg.modelID
        let alreadyDone: Set<String>
        do {
            let matched = try context.fetch(FetchDescriptor<Annotation>(
                predicate: #Predicate { $0.stage == "llm" && $0.modelName == currentModelName }
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
        print("Annotating \(total) posts · \(cfg.modelID) · pace \(args.pace.rawValue)\n")

        let runStart = Date()
        var processed = 0
        var errors = 0
        let saveEvery = 20
        var sinceSave = 0

        for post in pending {
            if cancel.isSet { break }

            let baseline = post.nlTaggerAnnotation
            let language = baseline?.detectedLanguage ?? "other"
            let baselineSentiment = baseline?.sentimentScore ?? 0.0

            do {
                let result = try await client.classify(text: post.text, language: language)
                let annotation = Annotation(
                    speechClass: result.speechClass,
                    sentimentScore: baselineSentiment,
                    detectedLanguage: language,
                    modelName: client.modelName,
                    modelVersion: client.modelVersion,
                    promptHash: client.promptHash,
                    rawResponse: result.rawResponse,
                    stage: "llm",
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
            } catch {
                errors += 1
            }

            let thermal = ProcessInfo.processInfo.thermalState
            let elapsed = Date().timeIntervalSince(runStart)
            writeProgress(progressLine(
                processed: processed, total: total, errors: errors,
                elapsed: elapsed, thermal: thermal,
                modelID: cfg.modelID, paceLabel: args.pace.rawValue
            ))

            // Pace + thermal back-off. Both sleeps are cancellable via Task.sleep
            // throwing CancellationError if our async context gets cancelled — but
            // CLI doesn't cancel its own Task. The cancel flag is checked at the
            // top of the next iteration.
            let cooldown = args.pace.baseDelayNanoseconds
                + ThermalBackoff.extraDelayNanoseconds(for: thermal)
            if cooldown > 0 {
                try? await Task.sleep(nanoseconds: cooldown)
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
