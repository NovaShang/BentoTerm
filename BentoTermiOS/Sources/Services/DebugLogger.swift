import Foundation
import os

/// File-based logger for debugging on the simulator and on a tethered device.
/// Logs are written to the app's Documents directory and pulled from the Mac
/// with `devicectl device copy from --domain-type appDataContainer`.
///
/// **Debug builds only.** The file is what makes a real-device incident
/// diagnosable from one pull, and every device debugging session in this
/// project runs a Debug build — but a shipped app has no business writing a
/// plaintext transcript of the user's terminal session to Documents, which is
/// both an iCloud-backed location and the wrong place for non-user data. The
/// lines carry pane output, tmux replies and voice transcripts verbatim.
///
/// In Release the type still exists and `dlog` still compiles; the writes go
/// to os_log only.
final class DebugLogger: @unchecked Sendable {
    static let shared = DebugLogger()

    private let fileHandle: FileHandle?
    private let lock = OSAllocatedUnfairLock(initialState: ())
    let logFileURL: URL

    /// ISO8601DateFormatter is thread-safe (documented); one shared instance
    /// avoids paying its allocation cost on every log line (this is the hot
    /// file sink). `nonisolated(unsafe)` asserts that thread-safety to Swift 6
    /// strict concurrency, which can't see it from the type.
    nonisolated(unsafe) private static let timestampFormatter = ISO8601DateFormatter()

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        logFileURL = docs.appendingPathComponent("debug.log")

#if DEBUG
        // Truncate on launch
        FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: logFileURL)
        fileHandle?.seekToEndOfFile()

        log("=== BentoTerm Debug Log Started ===")
#else
        // No file in a shipped build — see the type comment. A stale log left
        // behind by a Debug install would otherwise sit in Documents forever.
        fileHandle = nil
        try? FileManager.default.removeItem(at: logFileURL)
#endif
    }

    func log(_ message: String, file: String = #fileID, line: Int = #line) {
        let timestamp = Self.timestampFormatter.string(from: Date())
        let fileName = (file as NSString).lastPathComponent
        let entry = "[\(timestamp)] [\(fileName):\(line)] \(message)\n"

        lock.withLock { _ in
            if let data = entry.data(using: .utf8) {
                fileHandle?.write(data)
                // Also mirror to os_log for console
                os_log(.debug, "%{public}@", message)
            }
        }
    }

    deinit {
        fileHandle?.closeFile()
    }
}

/// Shorthand
func dlog(_ message: String, file: String = #fileID, line: Int = #line) {
    DebugLogger.shared.log(message, file: file, line: line)
}
