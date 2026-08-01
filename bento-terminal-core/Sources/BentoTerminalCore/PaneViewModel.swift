import Foundation
import os
import SwiftUI
import BentoTmuxKit
import BentoFilePreviewKit

/// ViewModel for a single tmux pane, managing its terminal output and input.
@MainActor
public final class PaneViewModel: ObservableObject, Identifiable {
    public nonisolated let paneID: TmuxPaneID
    @Published public var pane: Pane
    @Published public var isActive: Bool = false
    @Published public var paneState: PaneState = .idle

    /// True when a coding-agent pane has finished (.idle) but the user hasn't
    /// looked at it yet — the "done, unseen" state (herdr's done vs idle). Set
    /// when an agent pane goes idle while not focused; cleared when it's focused
    /// or leaves idle. Drives the distinct "done" dot.
    @Published public var agentFinishedUnseen: Bool = false

    /// Called when terminal output arrives for this pane. Setting this also
    /// replays the full history buffer so a freshly-bound surface (e.g.
    /// after navigating away and back) repaints the scrollback rather than
    /// showing an empty screen until the next byte arrives.
    public nonisolated(unsafe) var onDataReceived: (@Sendable (Data) -> Void)? {
        didSet {
            // Snapshot under the lock — output may be appending concurrently on
            // the tmux parse queue while a surface binds here.
            let replay = feedLock.withLock { _history }
            guard let onDataReceived, !replay.isEmpty else { return }
            onDataReceived(replay)
        }
    }

    /// Rolling buffer of every byte received for this pane. Capped so a
    /// long-running session doesn't grow without bound.
    nonisolated(unsafe) private var _history = Data()
    private nonisolated static let maxHistoryBytes = 256 * 1024
    /// Let history overshoot the cap by this much before trimming, then drop a
    /// whole slab at once. Removing from the front of `Data` is O(n); trimming on
    /// every chunk once at the cap turned heavy output into an O(n²) main-thread
    /// memmove storm — the ~1s keystroke stall, since `feedData` runs on the main
    /// actor and blocks `keyDown`. Amortized, the front-shift runs ~once per slab
    /// received instead of once per chunk (linear total work).
    private nonisolated static let historySlackBytes = 256 * 1024

    /// Strips screen/tmux window-title escapes from this pane's byte stream
    /// (see ScreenTitleStripper). Stateful, so it must persist across chunks —
    /// and since output can now arrive on the tmux parse queue, every touch of
    /// it (and of `_history`) is serialized by `feedLock`.
    nonisolated(unsafe) private let titleStripper = ScreenTitleStripper()

    /// Guards `titleStripper` + `_history`. Both are stream-stateful, so a
    /// concurrent feed would corrupt escape-sequence tracking, not just race.
    private nonisolated let feedLock = OSAllocatedUnfairLock()

    /// Feed data to this pane — appended to history and forwarded if bound.
    ///
    /// `nonisolated` so tmux output reaches the surface without a main-thread
    /// hop. The main thread is frozen for ~19ms on every keystroke (input
    /// method IPC), and routing echoes through it made them queue behind the
    /// very keystroke they were echoing.
    public nonisolated func feedData(_ data: Data) {
        // The strip + history append must be atomic as a pair: the stripper
        // consumes a prefix of the stream and history must record exactly what
        // it emitted, in the same order.
        feedLock.lock()
        let clean = titleStripper.strip(data)
        if !clean.isEmpty { appendHistory(clean) }
        feedLock.unlock()
        guard !clean.isEmpty else { return }
        // Outside the lock: the surface hands off to its own queue, and holding
        // a lock across a callback into unknown code invites deadlock.
        onDataReceived?(clean)
    }

    /// Caller must hold `feedLock`.
    private nonisolated func appendHistory(_ data: Data) {
        _history.append(data)
        // Trim only after overshooting the cap by a slab, then trim back to the
        // cap in one shot (see historySlackBytes) — never per chunk.
        if _history.count > Self.maxHistoryBytes + Self.historySlackBytes {
            // Known main-thread O(n) memmove; measured so we can see whether it
            // actually shows up in a stall or is amortized away.
            _history.removeSubrange(0..<(_history.count - Self.maxHistoryBytes))
        }
    }

    private let tmuxService: TmuxControlMode

    public nonisolated var id: TmuxPaneID { paneID }

    public init(pane: Pane, tmuxService: TmuxControlMode) {
        self.paneID = pane.id
        self.pane = pane
        self.isActive = pane.isActive
        self.tmuxService = tmuxService
    }

    /// Send raw terminal input to this pane
    public func sendInput(_ data: Data) {
        tmuxService.sendData(to: paneID, data: data)
    }

    public func sendString(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        sendInput(data)
    }

    public func updatePane(_ newPane: Pane) {
        // Equality-gate: the 2s poll re-applies an identical Pane most cycles;
        // republishing it would ripple objectWillChange through every subscribed
        // view for no visible change.
        guard pane != newPane else { return }
        self.pane = newPane
    }

    /// The pane's live working directory (`#{pane_current_path}`), queried at
    /// call time so it's never stale. nil on error / not reported. Used by
    /// path-preview to resolve relative paths — works over any transport since
    /// it rides the tmux control channel.
    public func currentWorkingDirectory() async -> String? {
        let resp = await tmuxService.send(
            .displayMessage(format: "#{pane_current_path}", target: paneID),
            timeout: .seconds(3))
        pathPreviewLog.log("cwd query pane=\(self.paneID.description, privacy: .public) error=\(resp.isError) output=⟨\(resp.output.prefix(120), privacy: .public)⟩")
        guard !resp.isError else { return nil }
        let path = resp.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? path : nil
    }
}
