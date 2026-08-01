import Foundation
import os

private let log = Logger(subsystem: "com.novashang.bento", category: "TerminalVM")

/// Optional file sink for the package `dlog`. Logs default to os_log only,
/// which is invisible in the app's pullable `debug.log` — set this once at
/// app start (before any terminal work) to mirror every log line into the
/// host app's file logger so real-device incidents can be diagnosed from a
/// single file pull.
public nonisolated(unsafe) var coreDlogFileSink: (@Sendable (String) -> Void)?

/// Shared debug-log shorthand. Every Bento module's `dlog` converged on this
/// one (the iOS app target keeps its own file-logging variant; local symbols
/// shadow the imported one, so both coexist).
public func dlog(_ s: String) {
    log.debug("\(s, privacy: .public)")
    coreDlogFileSink?(s)
}

// File diagnostics ordering surface-lifecycle vs seed-feed events (os_log
// debug doesn't reliably reach `log show`). Off by default; opt in per-run
// with BENTO_DIAG=1 to trace to /tmp/bento-diag.log.
let _diagEnabled = ProcessInfo.processInfo.environment["BENTO_DIAG"] == "1"
let _diagLock = NSLock()
public func DIAG(_ s: @autoclosure () -> String) {
    guard _diagEnabled else { return }
    _diagLock.lock(); defer { _diagLock.unlock() }
    let line = String(format: "%.3f %@\n", ProcessInfo.processInfo.systemUptime, s())
    let url = URL(fileURLWithPath: "/tmp/bento-diag.log")
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
        try? line.data(using: .utf8)?.write(to: url)
    }
}
