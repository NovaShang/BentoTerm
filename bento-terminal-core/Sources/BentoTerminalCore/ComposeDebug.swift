import Foundation

/// Lightweight file logger for the scroll-review-compose feature. Appends
/// timestamped lines to `<App Support>/Bento/compose-debug.log` so the feature
/// can be exercised in a running build and the log read back directly (no manual
/// console copy-paste — see feedback_debugging). Thread-safe via a serial queue;
/// callable from any thread (the libghostty action callback included).
///
/// This is temporary instrumentation for bring-up. Gate everything behind
/// `enabled`; flip it off (or delete the call sites) once the interaction is
/// verified.
public enum ComposeDebug {
    /// Master switch. Set true to capture phase transitions to the log file when
    /// diagnosing the scroll-review-compose interaction; off in production (every
    /// call site is `@autoclosure`-gated, so disabled = zero string-building I/O).
    public static var enabled = false

    private static let queue = DispatchQueue(label: "com.bento.composedebug")

    /// Resolved lazily on first use. Same App Support root as the theme config,
    /// so it lands in the app container when sandboxed and in ~/Library otherwise.
    private static let fileURL: URL? = {
        let fm = FileManager.default
        guard let appSup = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = appSup.appendingPathComponent("Bento", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("compose-debug.log")
    }()

    public static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = "\(timestamp()) \(message())\n"
        queue.async {
            guard let url = fileURL, let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Truncate the log (call at app launch so each run starts clean).
    public static func reset() {
        guard enabled else { return }
        queue.async {
            guard let url = fileURL else { return }
            try? Data().write(to: url, options: .atomic)
        }
    }

    private static func timestamp() -> String {
        // Wall-clock HH:mm:ss.SSS — enough to read interaction ordering.
        let now = Date()
        let cal = Calendar.current
        let c = cal.dateComponents([.hour, .minute, .second, .nanosecond], from: now)
        let ms = (c.nanosecond ?? 0) / 1_000_000
        return String(format: "%02d:%02d:%02d.%03d",
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0, ms)
    }
}
