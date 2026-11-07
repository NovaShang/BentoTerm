import Foundation
import BentoTmuxKit

/// The last few lines each pane printed, as plain text.
///
/// Voice reads ~30 lines of the active pane to bias speech recognition toward
/// the words on screen, and a pane that turns amber hands its last lines to
/// the Live Activity / notification as the prompt snippet. Nothing here judges
/// state — that comes from the pane's `@bento_state` option (`PaneStatusOption`).
@MainActor
public final class PaneRecentText {
    private var linesStore: [TmuxPaneID: [String]] = [:]
    /// Raw output buffered per pane, awaiting lazy processing. `recordOutput`
    /// runs on the hot output path (every chunk of every pane), so it must do
    /// no string/regex work — stripping and line-splitting happen on demand
    /// in `processPending`, only when someone actually reads the lines.
    private var pendingRaw: [TmuxPaneID: Data] = [:]
    private let maxPendingBytes = 32 * 1024
    private let maxLines = 20

    /// Compiled once — `replacingOccurrences(options: .regularExpression)`
    /// recompiles the pattern on every call, which showed up as a top
    /// main-thread cost under heavy TUI output.
    private static let ansiStripRegex = try! NSRegularExpression(
        pattern: "\\x1b\\[[\\d;]*[A-Za-z]|\\x1b\\][^\\x07]*\\x07|[\\x00-\\x08\\x0e-\\x1f]"
    )

    public init() {}

    /// Call when new output arrives for a pane. Hot path — only buffers the
    /// raw bytes; all stripping/splitting is deferred to `processPending`.
    public func recordOutput(pane: TmuxPaneID, data: Data) {
        guard !data.isEmpty else { return }
        var buf = pendingRaw[pane] ?? Data()
        buf.append(data)
        // Only the last `maxLines` lines ever matter; keep the tail. Trim only
        // after overshooting by a slab (not every chunk once at the cap), so heavy
        // output doesn't pay an O(maxPendingBytes) copy per chunk on the main
        // thread — same memmove-storm pattern as PaneViewModel's history trim.
        if buf.count > 2 * maxPendingBytes {
            buf = Data(buf.suffix(maxPendingBytes))
        }
        pendingRaw[pane] = buf
    }

    /// Fold any buffered raw output for `pane` into `linesStore`.
    private func processPending(_ pane: TmuxPaneID) {
        guard let raw = pendingRaw.removeValue(forKey: pane) else { return }

        let text = String(decoding: raw, as: UTF8.self)
        let range = NSRange(text.startIndex..., in: text)
        let stripped = Self.ansiStripRegex.stringByReplacingMatches(
            in: text, range: range, withTemplate: ""
        )

        let lines = stripped.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return }

        var current = linesStore[pane] ?? []
        current.append(contentsOf: lines)
        if current.count > maxLines {
            current = Array(current.suffix(maxLines))
        }
        linesStore[pane] = current
    }

    /// Forget a pane (e.g., when it's closed).
    public func clearPane(_ pane: TmuxPaneID) {
        linesStore.removeValue(forKey: pane)
        pendingRaw.removeValue(forKey: pane)
    }

    /// Return the most recent N lines of stripped text for a pane, joined by
    /// newlines.
    public func recentText(for pane: TmuxPaneID, lines: Int) -> String {
        processPending(pane)
        let buffer = linesStore[pane] ?? []
        let slice = buffer.suffix(max(0, lines))
        return slice.joined(separator: "\n")
    }
}
