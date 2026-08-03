import Foundation
import BentoTmuxKit

/// Monitors pane output to detect the three-state machine:
/// Working → Idle → AwaitingInput
///
/// Detection rules:
/// 1. tmux silence (no output for >silenceThreshold) → idle
/// 2. Output pattern matching (last N lines match profile regex) → awaitingInput
/// 3. Working = default (recent output within threshold)
@MainActor
public final class StateDetectionService {
    private var lastOutputTime: [TmuxPaneID: Date] = [:]
    private var recentLinesStore: [TmuxPaneID: [String]] = [:]
    /// Arrival time of each line in `recentLinesStore` (same indexes, trimmed in
    /// lockstep), so pattern matches can be gated on freshness — a prompt line
    /// that has gone quiet past `silenceThreshold` must not keep a pane in
    /// awaitingInput forever.
    private var recentLinesArrival: [TmuxPaneID: [Date]] = [:]
    /// Raw output buffered per pane, awaiting lazy processing. `recordOutput`
    /// runs on the hot output path (every chunk of every pane), so it must do
    /// no string/regex work — stripping and line-splitting happen on demand
    /// in `processPending`, only when detection actually reads the lines.
    private var pendingRaw: [TmuxPaneID: Data] = [:]
    private var pendingArrival: [TmuxPaneID: Date] = [:]
    private let maxPendingBytes = 32 * 1024
    /// Per-pane manual profile override (pane menu → Change Profile). When set,
    /// detection uses ONLY this profile's patterns and ignores command matching;
    /// nil = auto-detect (the default).
    private var paneProfileOverride: [TmuxPaneID: String] = [:]
    private let maxLines = 20
    private let silenceThreshold: TimeInterval = 5.0

    /// Region/priority rule engine for recognized coding agents (Claude, …).
    /// Takes precedence over the legacy `detectState` profile path for panes it
    /// recognizes; everything else still flows through `detectState`. Built from
    /// the profiles' `agentRules` (preset + user config) via the one ProfileStore
    /// — no longer a hardcoded singleton, so adding/editing an agent is data.
    var agentDetector: AgentDetector { AgentDetector(ruleSets: profiles.compactMap(\.agentRules)) }

    /// Compiled once — `replacingOccurrences(options: .regularExpression)`
    /// recompiles the pattern on every call, which showed up as a top
    /// main-thread cost under heavy TUI output.
    private static let ansiStripRegex = try! NSRegularExpression(
        pattern: "\\x1b\\[[\\d;]*[A-Za-z]|\\x1b\\][^\\x07]*\\x07|[\\x00-\\x08\\x0e-\\x1f]"
    )

    public init() {}

    var profiles: [StateProfile] { ProfileStore.shared.profiles }

    /// Force a pane to use a specific profile (nil restores auto-detect).
    public func setProfileOverride(_ profileID: String?, for pane: TmuxPaneID) {
        if let profileID { paneProfileOverride[pane] = profileID }
        else { paneProfileOverride.removeValue(forKey: pane) }
    }

    public func profileOverride(for pane: TmuxPaneID) -> String? { paneProfileOverride[pane] }

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
        pendingArrival[pane] = Date()
    }

    /// Fold any buffered raw output for `pane` into `recentLinesStore`.
    /// `lastOutputTime` only advances when the buffer contained real content
    /// after ANSI stripping, matching the old per-chunk semantics (so pure
    /// cursor/control traffic still counts as silence).
    private func processPending(_ pane: TmuxPaneID) {
        guard let raw = pendingRaw.removeValue(forKey: pane) else { return }
        let arrival = pendingArrival.removeValue(forKey: pane)

        let text = String(decoding: raw, as: UTF8.self)
        let range = NSRange(text.startIndex..., in: text)
        let stripped = Self.ansiStripRegex.stringByReplacingMatches(
            in: text, range: range, withTemplate: ""
        )

        let lines = stripped.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return }

        let stamp = arrival ?? Date()
        lastOutputTime[pane] = stamp
        var current = recentLinesStore[pane] ?? []
        var currentArrivals = recentLinesArrival[pane] ?? []
        current.append(contentsOf: lines)
        currentArrivals.append(contentsOf: Array(repeating: stamp, count: lines.count))
        if current.count > maxLines {
            current = Array(current.suffix(maxLines))
            currentArrivals = Array(currentArrivals.suffix(maxLines))
        }
        recentLinesStore[pane] = current
        recentLinesArrival[pane] = currentArrivals
    }

    /// Compiled-regex cache — shared with AgentDetector's rule engine
    /// (AgentStatusRules.swift); the pattern set is small, so never recompile.
    private func compiledRegex(_ pattern: String) -> NSRegularExpression? {
        AgentDetector.compiled(pattern)
    }

    /// Returns true if any of `patterns` matches `text` (case-insensitive regex).
    private func anyMatch(_ patterns: [String], in text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let range = NSRange(text.startIndex..., in: text)
        for pattern in patterns {
            if let regex = compiledRegex(pattern),
               regex.firstMatch(in: text, range: range) != nil {
                return true
            }
        }
        return false
    }

    /// Process names (tmux `pane_current_command`) of a bare interactive shell
    /// sitting at its prompt. Output from such a pane is the echo of the user
    /// typing, not a running command — so it must not read as "working".
    private static let interactiveShells: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "ash",
    ]

    /// True when `command` names a bare interactive shell — tolerating a login
    /// shell's leading "-" (e.g. "-zsh") and a full path.
    private static func isShellPrompt(_ command: String) -> Bool {
        let name = (command as NSString).lastPathComponent
        let base = name.hasPrefix("-") ? String(name.dropFirst()) : name
        return interactiveShells.contains(base.lowercased())
    }

    /// Detect the current state of a pane. `title` is the pane_title; it's
    /// checked before output patterns (PRD §3.4 priority: Title → output).
    public func detectState(pane: TmuxPaneID, currentCommand: String?, title: String? = nil) -> PaneState {
        processPending(pane)
        let now = Date()
        let lastOutput = lastOutputTime[pane] ?? .distantPast
        let lines = recentLinesStore[pane] ?? []
        let recentText = lines.joined(separator: "\n")
        let titleText = title ?? ""
        // Only honor an output-pattern match while the pane is still talking:
        // a prompt line that has sat past `silenceThreshold` is stale (the user
        // already answered it) and must not keep the pane in awaitingInput
        // forever. Title patterns aren't gated — a title like "git add" stays
        // current regardless of output silence.
        let newestLine = recentLinesArrival[pane]?.max() ?? .distantPast
        let outputFresh = now.timeIntervalSince(newestLine) <= silenceThreshold

        // Manual override (pane menu → Change Profile): use only this profile's
        // patterns, ignoring command matching.
        if let overrideID = paneProfileOverride[pane],
           let profile = profiles.first(where: { $0.id == overrideID }) {
            if anyMatch(profile.titlePatterns, in: titleText) || (outputFresh && anyMatch(profile.outputPatterns, in: recentText)) {
                return .awaitingInput(profile: profile.id)
            }
            if now.timeIntervalSince(lastOutput) > silenceThreshold { return .idle }
            return .working
        }

        // Check for awaiting-input patterns. Two passes so a command-bound
        // profile (claude/codex/git/vim) always wins over the catch-all generic
        // shell profile, regardless of the order profiles happen to sit in the
        // array (built-ins merged into an existing install land at the end).
        for commandBoundPass in [true, false] {
            for profile in profiles {
                let isCommandBound = profile.commandPattern != nil
                guard isCommandBound == commandBoundPass else { continue }

                // Command-bound profiles only apply when the running command matches.
                if let cmdPattern = profile.commandPattern {
                    guard let cmd = currentCommand, cmd.contains(cmdPattern) else { continue }
                }

                // Title patterns take priority over output patterns (PRD §3.4).
                if anyMatch(profile.titlePatterns, in: titleText) || (outputFresh && anyMatch(profile.outputPatterns, in: recentText)) {
                    return .awaitingInput(profile: profile.id)
                }
            }
        }

        // A pane sitting at an interactive shell prompt is never "working": any
        // recent output there is just the echo of the user typing, not a running
        // command. (Real shell prompts like [y/N] were already caught by the
        // awaiting-input passes above.) Without this, typing a couple characters
        // into an idle pane flips it green.
        if let cmd = currentCommand, Self.isShellPrompt(cmd) {
            return .idle
        }

        // Check silence threshold
        if now.timeIntervalSince(lastOutput) > silenceThreshold {
            return .idle
        }

        return .working
    }

    /// Outcome of classifying a pane through the agent rule engine.
    public enum AgentClassification {
        case notAgent              // not a recognized agent → use legacy detectState
        case needsSnapshot         // recognized agent; fetch capture-pane then re-call
        case state(PaneState)      // resolved state
    }

    /// Classify a pane that may be running a coding agent. Call first with
    /// `snapshot: nil` (cheap, title-only): a spinner title resolves to
    /// `.working` with no tmux round-trip; otherwise you get `.needsSnapshot`,
    /// so fetch `capture-pane` and call again with the text. Maps the engine's
    /// agent status onto `PaneState` (blocked → `.awaitingInput`).
    public func classifyAgent(command: String?, title: String, snapshot: String?,
                              pane: TmuxPaneID, current: PaneState) -> AgentClassification {
        guard let set = agentDetector.ruleSet(command: command, title: title) else {
            return .notAgent
        }
        let result = agentDetector.classify(set, title: title, snapshot: snapshot)
        if snapshot == nil {
            if result?.status == .working { return .state(.working) }
            return .needsSnapshot   // need the screen to tell blocked vs idle
        }
        guard let result else {
            // Recognized agent but no rule matched — fall back to activity.
            processPending(pane)
            let silent = Date().timeIntervalSince(lastOutputTime[pane] ?? .distantPast) > silenceThreshold
            return .state(silent ? .idle : .working)
        }
        guard let status = result.status else { return .state(current) }   // skip rule
        switch status {
        case .working: return .state(.working)
        case .blocked: return .state(.awaitingInput(profile: set.id))
        case .idle:    return .state(.idle)
        }
    }

    /// Get quick keys for a pane's current state
    public func quickKeys(for state: PaneState) -> [QuickKey] {
        guard case .awaitingInput(let profileID) = state else { return [] }
        return profiles.first { $0.id == profileID }?.quickKeys ?? []
    }

    /// Clear state for a pane (e.g., when it's closed)
    public func clearPane(_ pane: TmuxPaneID) {
        lastOutputTime.removeValue(forKey: pane)
        recentLinesStore.removeValue(forKey: pane)
        recentLinesArrival.removeValue(forKey: pane)
        pendingRaw.removeValue(forKey: pane)
        pendingArrival.removeValue(forKey: pane)
        paneProfileOverride.removeValue(forKey: pane)
    }

    /// Return the most recent N lines of stripped text for a pane, joined by
    /// newlines. Used as context for LLM-assisted command generation.
    public func recentText(for pane: TmuxPaneID, lines: Int) -> String {
        processPending(pane)
        let buffer = recentLinesStore[pane] ?? []
        let slice = buffer.suffix(max(0, lines))
        return slice.joined(separator: "\n")
    }
}
