import Foundation

// Region-scoped, priority-ordered rule engine for detecting a coding agent's
// status from a terminal snapshot + title. Pure (Foundation only) so it's unit
// testable and platform-independent.
//
// Design (our own implementation; the region/priority/AND-OR-NOT *approach* is a
// common one, also used by tools like herdr — the Claude rules below are
// authored from first-hand `capture-pane` evidence; the other agents' rule
// sets (AgentRulePresets.swift) additionally cross-reference herdr's public
// detection manifests as FACTUAL evidence of each agent's UI strings,
// re-expressed in this schema — see that file's header for provenance):
//   * Match a clean SCREEN SNAPSHOT (tmux already renders the TUI for us via
//     `capture-pane -p`), never the raw output stream.
//   * Scope each rule to a REGION (title / prompt box / after the last rule /
//     bottom N lines), so we match invariant UI controls, not incidental prose.
//   * Evaluate rules by PRIORITY, highest first; first match wins. A rule may
//     say "skip" (don't change state) for transient overlays (transcript/picker).

/// The three behavioral states a coding agent can be in. (`done` vs `idle` —
/// finished-unseen vs finished-seen — is a separate "seen" axis tracked on the
/// pane via focus, not produced here.)
public enum AgentStatus: String, Equatable, Sendable, Codable {
    case working    // generating / running tools
    case blocked    // a permission/selection form is on screen, waiting on you
    case idle       // finished its turn, sitting at the input prompt
}

/// Which slice of the pane a rule matches against.
public enum DetectRegion: Equatable, Codable {
    case oscTitle                    // the pane_title (OSC 0/2)
    case wholeSnapshot               // the entire capture-pane snapshot
    case bottomNonEmptyLines(Int)    // last N non-empty lines of the snapshot
    case afterLastHorizontalRule     // snapshot lines after the last ─── rule
    case promptBoxBody               // snapshot lines between the last two ─── rules
    case afterLastPromptMarker       // lines after the last `›` prompt line (Codex)
}

/// A recursive AND/OR/NOT match clause over a region's text. All substring/regex
/// matching is case-insensitive.
public indirect enum MatchClause: Codable {
    case contains([String])      // ALL of these substrings present
    case containsAny([String])   // ANY of these substrings present
    case regex(String)           // regex matches somewhere in the region text
    case lineRegex(String)       // regex matches at least one line of the region
    case all([MatchClause])      // every sub-clause matches
    case any([MatchClause])      // at least one sub-clause matches
    case not(MatchClause)        // the sub-clause does NOT match
}

/// One detection rule: when `clause` matches `region`, the pane takes `status`
/// (or, if `status` is nil, state is left unchanged — for transient overlays).
public struct DetectRule: Codable {
    public let id: String
    public let status: AgentStatus?   // nil = skip (don't update state) when matched
    public let priority: Int
    public let region: DetectRegion
    public let clause: MatchClause

    public init(id: String, status: AgentStatus?, priority: Int,
                region: DetectRegion, clause: MatchClause) {
        self.id = id; self.status = status; self.priority = priority
        self.region = region; self.clause = clause
    }
}

/// The full rule set for one agent, plus how to recognize that agent. Now a
/// Codable value carried by a StateProfile (`profile.agentRules`) — the
/// hardcoded built-ins became preset data, and the whole thing is configurable
/// through the one ProfileStore.
public struct AgentRuleSet: Codable {
    public let id: String                 // e.g. "claude-code" (matches the StateProfile id)
    public let commandPatterns: [String]  // identity via pane_current_command (substring)
    public let titleIdentity: [String]    // identity via title (regex), for when the
                                          // foreground command name is unreliable
    public let rules: [DetectRule]        // any order; the engine sorts by priority desc

    public init(id: String, commandPatterns: [String], titleIdentity: [String],
                rules: [DetectRule]) {
        self.id = id; self.commandPatterns = commandPatterns
        self.titleIdentity = titleIdentity; self.rules = rules
    }
}

/// Stateless evaluator over the built-in agent rule sets.
struct AgentDetector {
    let ruleSets: [AgentRuleSet]

    static let shared = AgentDetector(ruleSets: AgentRuleSet.builtIns)

    /// The rule set whose agent is running in this pane, if any.
    func ruleSet(command: String?, title: String) -> AgentRuleSet? {
        for set in ruleSets {
            if let command, !command.isEmpty,
               set.commandPatterns.contains(where: { command.contains($0) }) {
                return set
            }
            if set.titleIdentity.contains(where: { Self.regexMatches($0, in: title) }) {
                return set
            }
        }
        return nil
    }

    /// Classify a pane. `snapshot` is the `capture-pane` text (nil if not
    /// fetched — then only title-region rules can match). Returns the matched
    /// rule's status (nil status = "skip"/leave unchanged) and its id, or nil if
    /// nothing matched (caller falls back to activity-based detection).
    func classify(_ set: AgentRuleSet, title: String, snapshot: String?)
        -> (status: AgentStatus?, ruleID: String, matched: Bool)?
    {
        let sorted = set.rules.sorted { $0.priority > $1.priority }
        let lines = snapshot.map { Self.splitLines($0) }
        for rule in sorted {
            guard let text = regionText(rule.region, title: title, lines: lines) else { continue }
            if evaluate(rule.clause, against: text) {
                return (rule.status, rule.id, true)
            }
        }
        return nil
    }

    // MARK: - Region extraction

    private func regionText(_ region: DetectRegion, title: String, lines: [String]?) -> String? {
        switch region {
        case .oscTitle:
            return title
        case .wholeSnapshot:
            return lines?.joined(separator: "\n")
        case .bottomNonEmptyLines(let n):
            guard let lines else { return nil }
            let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return nonEmpty.suffix(n).joined(separator: "\n")
        case .afterLastHorizontalRule:
            guard let lines else { return nil }
            guard let last = lines.lastIndex(where: Self.isHorizontalRule) else { return nil }
            return lines[(last + 1)...].joined(separator: "\n")
        case .promptBoxBody:
            guard let lines else { return nil }
            let ruleIdx = lines.indices.filter { Self.isHorizontalRule(lines[$0]) }
            guard ruleIdx.count >= 2 else { return nil }
            let lo = ruleIdx[ruleIdx.count - 2], hi = ruleIdx[ruleIdx.count - 1]
            guard hi > lo + 1 else { return "" }
            return lines[(lo + 1)..<hi].joined(separator: "\n")
        case .afterLastPromptMarker:
            // Codex renders its input prompt as a lone `›` line; a form below
            // the last one is live UI, prose above it is history.
            guard let lines else { return nil }
            guard let last = lines.lastIndex(where: { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return t == "›" || t.hasPrefix("› ")
            }) else { return lines.joined(separator: "\n") }
            return lines[(last + 1)...].joined(separator: "\n")
        }
    }

    // MARK: - Clause evaluation

    private func evaluate(_ clause: MatchClause, against text: String) -> Bool {
        switch clause {
        case .contains(let subs):
            return subs.allSatisfy { text.range(of: $0, options: .caseInsensitive) != nil }
        case .containsAny(let subs):
            return subs.contains { text.range(of: $0, options: .caseInsensitive) != nil }
        case .regex(let pattern):
            return Self.regexMatches(pattern, in: text)
        case .lineRegex(let pattern):
            return text.split(separator: "\n", omittingEmptySubsequences: false)
                .contains { Self.regexMatches(pattern, in: String($0)) }
        case .all(let cs):
            return cs.allSatisfy { evaluate($0, against: text) }
        case .any(let cs):
            return cs.contains { evaluate($0, against: text) }
        case .not(let c):
            return !evaluate(c, against: text)
        }
    }

    // MARK: - Helpers

    private static func splitLines(_ s: String) -> [String] {
        s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// A line that's a horizontal rule: predominantly box-drawing dashes and at
    /// least 10 chars wide. Claude brackets its input box with these.
    static func isHorizontalRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 10 else { return false }
        let ruleChars: Set<Character> = ["─", "━", "═", "—", "-"]
        let hits = trimmed.reduce(0) { $0 + (ruleChars.contains($1) ? 1 : 0) }
        return Double(hits) / Double(trimmed.count) >= 0.8
    }

    /// Compiled-regex cache — detection runs every poll for several panes; the
    /// patterns are a small fixed set, so never recompile.
    private static let regexCache = NSCache<NSString, NSRegularExpression>()

    private static func compiled(_ pattern: String) -> NSRegularExpression? {
        if let cached = regexCache.object(forKey: pattern as NSString) { return cached }
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        else { return nil }
        regexCache.setObject(re, forKey: pattern as NSString)
        return re
    }

    static func regexMatches(_ pattern: String, in text: String) -> Bool {
        guard let re = compiled(pattern) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return re.firstMatch(in: text, range: range) != nil
    }
}

// MARK: - Built-in agent rule sets (authored from first-hand capture-pane evidence)

extension AgentRuleSet {
    /// Every built-in rule set the detector should know about. Order matters
    /// only for identity resolution ties (first match wins); keep the
    /// best-calibrated sets first.
    static let builtIns: [AgentRuleSet] = [
        .claudeCode, .codex, .gemini, .opencode, .hermes,
        .antigravity, .cursorAgent, .copilot, .amp, .cline,
    ]

    /// Claude Code. Verified on a live session 2026-06-21:
    ///   * working → title prefix is an animated braille spinner (U+2800–28FF);
    ///     the footer shows `esc to interrupt`, a live status line `· Inferring…`.
    ///   * idle    → title prefix is `✳` (U+2733); an empty `❯` input box sits
    ///     between two `───` rules; footer shows `shift+tab to cycle` etc.
    ///   * blocked → a permission/selection form: `Do you want to proceed?` with
    ///     numbered `1. Yes` / `2. No` options, or `enter to select`/`esc to
    ///     cancel`. Blocked/overlay evidence cross-referenced against herdr's
    ///     field-tested claude manifest (see AgentRulePresets.swift header);
    ///     final first-hand calibration of the bash-permission form still open.
    static let claudeCode = AgentRuleSet(
        id: "claude-code",
        commandPatterns: ["claude"],
        titleIdentity: [],
        rules: [
            // Working: animated braille spinner in the title. Highest confidence.
            DetectRule(id: "title_working_spinner", status: .working, priority: 1100,
                       region: .oscTitle,
                       clause: .regex("^\\s*[\\x{2800}-\\x{28FF}]")),

            // Working corroboration when the title isn't a spinner: the live
            // footer/status line only appears while generating.
            DetectRule(id: "footer_working", status: .working, priority: 1050,
                       region: .bottomNonEmptyLines(4),
                       clause: .containsAny(["esc to interrupt"])),

            // Transcript viewer (ctrl+o) — a scrolling overlay, not a state
            // change. Skip so browsing history can't flip the pane state.
            DetectRule(id: "transcript_viewer", status: nil, priority: 1000,
                       region: .bottomNonEmptyLines(3),
                       clause: .all([
                           .contains(["showing detailed transcript"]),
                           .any([
                               .contains(["ctrl+o", "to toggle"]),
                               .contains(["ctrl+e", "show all"]),
                               .contains(["ctrl+e", "collapse"]),
                               .containsAny(["↑↓ scroll", "? for shortcuts"]),
                           ]),
                       ])),

            // Model picker (/model) — a transient menu, not a blocker.
            DetectRule(id: "model_picker", status: nil, priority: 950,
                       region: .wholeSnapshot,
                       clause: .all([
                           .contains(["select model", "enter to set as default", "esc to cancel"]),
                           .not(.containsAny(["do you want to proceed?", "enter to select"])),
                       ])),

            // Blocked: the bash-command permission form, corroborated by its
            // distinctive chrome (tab to amend / ctrl+e to explain) plus the
            // numbered yes/no option lines.
            DetectRule(id: "bash_permission_prompt", status: .blocked, priority: 910,
                       region: .wholeSnapshot,
                       clause: .all([
                           .contains(["do you want to proceed?"]),
                           .containsAny(["bash command", "bash(", "contains expansion",
                                         "tab to amend", "ctrl+e to explain"]),
                           .any([
                               .lineRegex("^\\s*❯?\\s*1\\.\\s*yes\\b"),
                               .lineRegex("^\\s*2\\.\\s*no\\b"),
                           ]),
                       ])),

            // Blocked: an actual permission form on screen. Scoped to
            // the bottom of the screen so prose in the conversation above can't
            // false-trigger it.
            DetectRule(id: "permission_prompt", status: .blocked, priority: 900,
                       region: .bottomNonEmptyLines(18),
                       clause: .all([
                           .containsAny(["do you want to proceed?", "do you want to make this edit",
                                         "do you want to create", "would you like to proceed"]),
                           .any([
                               .lineRegex("(?i)^\\s*❯?\\s*1\\.\\s*yes"),
                               .lineRegex("(?i)^\\s*2\\.\\s*no"),
                               .containsAny(["esc to cancel", "enter to confirm"]),
                           ]),
                       ])),

            // Blocked: a selection form (navigation + select/cancel controls).
            DetectRule(id: "selection_form", status: .blocked, priority: 880,
                       region: .afterLastHorizontalRule,
                       clause: .all([
                           .contains(["esc to cancel"]),
                           .containsAny(["enter to select", "enter to confirm"]),
                           .containsAny(["to navigate", "↑/↓", "↑↓", "arrow keys"]),
                       ])),

            // Idle: the empty input box is showing (a lone `❯`) and none of the
            // blocker controls are present — high-confidence "your turn".
            DetectRule(id: "idle_prompt_box", status: .idle, priority: 800,
                       region: .promptBoxBody,
                       clause: .all([
                           .lineRegex("^\\s*❯"),
                           .not(.containsAny(["do you want to", "esc to cancel",
                                              "enter to select", "to navigate"])),
                       ])),

            // Blocked, low-confidence catch-all: permission chrome that leaked
            // past the structured forms above. The `not` guard (an empty live
            // `❯` prompt anywhere) keeps ordinary conversation prose about
            // permissions from false-triggering once the turn has ended.
            DetectRule(id: "legacy_permission_catchall", status: .blocked, priority: 300,
                       region: .wholeSnapshot,
                       clause: .all([
                           .containsAny(["waiting for permission", "tab to amend",
                                         "ctrl+e to explain", "review your answers",
                                         "do you want to allow this connection?"]),
                           .not(.regex("(?m)^\\s*❯\\s*$")),
                       ])),

            // Idle: the `✳` at-rest marker in the title (lowest priority — a
            // visible blocker form above always wins).
            DetectRule(id: "title_idle_marker", status: .idle, priority: 250,
                       region: .oscTitle,
                       clause: .regex("^\\s*\\x{2733}")),
        ]
    )
}
