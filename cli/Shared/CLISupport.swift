// cli/Shared/CLISupport.swift
//
// Utilities shared by the blueX-annotate and blueX-scrape CLI binaries.
// Both are compiled into both targets via project.yml.

import Foundation

/// Thread-safe boolean flag set by the SIGINT handler so the main loop can
/// terminate at the next safe checkpoint without losing in-flight saves.
public final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    public init() {}
    public var isSet: Bool { lock.lock(); defer { lock.unlock() }; return v }
    public func set() { lock.lock(); v = true; lock.unlock() }
}

/// Installs a SIGINT handler that flips a CancelFlag and prints a notice.
/// Returns the flag so the caller can poll it from the main loop.
@discardableResult
public func installSIGINTHandler(notice: String = "\n\nstopping at next safe point — please wait…\n") -> CancelFlag {
    let cancel = CancelFlag()
    let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    src.setEventHandler {
        cancel.set()
        FileHandle.standardError.write(Data(notice.utf8))
    }
    src.resume()
    signal(SIGINT, SIG_IGN)  // dispatch source takes over from the default handler
    // The dispatch source must outlive this function; stash it in a global keepalive.
    SignalSourceKeepalive.shared.sources.append(src)
    return cancel
}

private final class SignalSourceKeepalive: @unchecked Sendable {
    static let shared = SignalSourceKeepalive()
    var sources: [DispatchSourceSignal] = []
}

/// Pretty-prints a duration. Same format used by both progress bars.
public func formatDuration(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds.rounded()))
    if s >= 3600 { return "\(s/3600)h \((s % 3600)/60)m" }
    if s >= 60   { return "\(s/60)m \(s % 60)s" }
    return "\(s)s"
}

/// In-place ANSI progress writer: returns cursor to column 0, clears to end of line.
public func writeProgress(_ line: String) {
    FileHandle.standardOutput.write(Data(("\r\u{1B}[K" + line).utf8))
}

/// Print a final line and advance: clears the in-place region, writes line + newline.
public func writeFinalLine(_ line: String) {
    FileHandle.standardOutput.write(Data(("\r\u{1B}[K" + line + "\n").utf8))
}

// MARK: - Uncaught ObjC exceptions

/// Program name for the uncaught-exception handler. The handler is a C function
/// pointer and therefore cannot capture context, so this is a global set by
/// `installUncaughtExceptionHandler(program:)` before the handler is installed.
private nonisolated(unsafe) var uncaughtExceptionProgram = "blueX"

/// Turns a fatal ObjC exception into a clean nonzero exit WITH the detail printed.
///
/// Why this exists: on 2026-08-04 the internal disk filled while `blueX-scrape` was
/// running. Every SQLite `COMMIT TRANSACTION` failed with error-code 13 ("database or
/// disk is full") and the process ended with
///
///     libc++abi: terminating due to uncaught exception of type NSException
///
/// i.e. SIGABRT — no exit status the nightly job could report, no heartbeat, so the
/// watchdog stayed quiet until its 48 h staleness threshold. The exception is raised
/// inside CoreData/CFNetwork, below any Swift `do/catch` we own: `NSException` is not a
/// Swift `Error` and cannot be caught in Swift at all. Converting it at the process
/// boundary is the only place it CAN be handled.
///
/// This deliberately does not swallow anything — name, reason, userInfo and the call
/// stack all go to stderr (and therefore into the run log) before exiting 1, which is
/// the same status `runFailed` uses, so bluex-nightly.sh notifies and writes a
/// heartbeat with a nonzero `scrapeExit` exactly as it does for any other failure.
/// Swift-level write errors are unaffected: they still throw and are still handled by
/// the callers that set `runFailed`. This is the backstop for the ones that cannot.
public func installUncaughtExceptionHandler(program: String) {
    uncaughtExceptionProgram = program
    NSSetUncaughtExceptionHandler { exception in
        let name = exception.name.rawValue
        let reason = exception.reason ?? "<no reason>"
        var text = "\n\(uncaughtExceptionProgram): FATAL — uncaught \(name): \(reason)\n"
        // The disk-full case is the one that brought this handler into being; name it
        // explicitly so the log says what to do instead of only what happened.
        if reason.contains("disk is full") || reason.contains("code=13") {
            text += "\(uncaughtExceptionProgram): a disk filled up mid-write. "
                 +  "Check free space on the store volume AND on the internal disk "
                 +  "(TMPDIR / ~/Library/Caches), then re-run — the store is "
                 +  "transactional, so committed work is intact.\n"
        }
        if let info = exception.userInfo, !info.isEmpty {
            text += "\(uncaughtExceptionProgram): userInfo: \(info)\n"
        }
        text += exception.callStackSymbols.map { "  \($0)\n" }.joined()
        text += "\(uncaughtExceptionProgram): exiting 1 (was: abort with no status).\n"
        FileHandle.standardError.write(Data(text.utf8))
        exit(1)
    }
}

/// Print an error to stderr (prefixed with the program name) and exit non-zero.
public func fail(_ program: String, _ message: String) -> Never {
    FileHandle.standardError.write(Data("\(program): \(message)\n".utf8))
    exit(2)
}
