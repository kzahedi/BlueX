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

/// Print an error to stderr (prefixed with the program name) and exit non-zero.
public func fail(_ program: String, _ message: String) -> Never {
    FileHandle.standardError.write(Data("\(program): \(message)\n".utf8))
    exit(2)
}
