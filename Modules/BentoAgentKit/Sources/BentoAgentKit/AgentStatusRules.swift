import Foundation

// Region-scoped, priority-ordered rule engine for detecting a coding agent's
// status from a terminal snapshot + title. Pure (Foundation only) so it's unit
// testable and platform-independent.
//
// Design (our own implementation; the region/priority/AND-OR-NOT *approach* is a
// common one, also used by tools like herdr — the built-in rule sets for each
// agent live in AgentRulePresets.swift, with their evidence provenance):
//   * Match a clean SCREEN SNAPSHOT (tmux already renders the TUI for us via
//     `capture-pane -p`), never the raw output stream.
//   * Scope each rule to a REGION (title / prompt box / after the last rule /
//     bottom N lines), so we match invariant UI controls, not incidental prose.
//   * Evaluate rules by PRIORITY, highest first; first match wins. A rule may
//     say "skip" (don't change state) for transient overlays (transcript/picker).

/// The three behavioral states a coding agent can be in. (`done` vs `idle` —
/// finished-unseen vs finished-seen — is a separate "seen" axis tracked on the
/// pane via focus, not produced here.)
public enum AgentStatus: String, Equatable, Sendable, Codable, CaseIterable {
    case working    // generating / running tools
    case blocked    // a permission/selection form is on screen, waiting on you
    case idle       // finished its turn, sitting at the input prompt

    /// How this state is named to the user — the same words the color legend
    /// uses, so a rule and a pane's tint can't be described differently.
    public var label: String {
        switch self {
        case .working: return "Working"
        case .blocked: return "Needs you"
        case .idle:    return "Idle"
        }
    }
}

/// Which slice of the pane a rule matches against.
public enum DetectRegion: Equatable, Hashable, Codable {
    case oscTitle                    // the pane_title (OSC 0/2)
    case wholeSnapshot               // the entire capture-pane snapshot
    case bottomNonEmptyLines(Int)    // last N non-empty lines of the snapshot
    case topNonEmptyLines(Int)       // first N non-empty lines (pinned chrome / launch screens)
    case afterLastHorizontalRule     // snapshot lines after the last ─── rule
    case promptBoxBody               // snapshot lines between the last two ─── rules
    case afterLastPromptMarker       // lines after the last `›` prompt line (Codex)

    /// How this region reads in the settings editor.
    public var label: String {
        switch self {
        case .oscTitle:                  return "Window title"
        case .wholeSnapshot:             return "Whole screen"
        case .bottomNonEmptyLines(let n): return "Bottom \(n) lines"
        case .topNonEmptyLines(let n):   return "Top \(n) lines"
        case .afterLastHorizontalRule:   return "Below the last divider"
        case .promptBoxBody:             return "Inside the input box"
        case .afterLastPromptMarker:     return "Below the last prompt"
        }
    }
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

    /// One line of plain English for the settings editor. Nested clauses read
    /// as parenthesised and/or, which is what the rules actually are — the
    /// editor doesn't pretend a rule is simpler than it is, it just spells it
    /// out so you can tell WHY a pane is being read the way it is.
    public var summary: String {
        func quoted(_ items: [String]) -> String {
            items.map { "“\($0)”" }.joined(separator: ", ")
        }
        switch self {
        case .contains(let subs):
            return subs.count == 1 ? "shows \(quoted(subs))" : "shows all of \(quoted(subs))"
        case .containsAny(let subs):
            return subs.count == 1 ? "shows \(quoted(subs))" : "shows any of \(quoted(subs))"
        case .regex(let p):
            return "matches /\(p)/"
        case .lineRegex(let p):
            return "has a line matching /\(p)/"
        case .all(let cs):
            return cs.map(\.summary).joined(separator: " and ")
        case .any(let cs):
            return "(" + cs.map(\.summary).joined(separator: " or ") + ")"
        case .not(let c):
            return "does not \(c.summary)"
        }
    }

    // MARK: - Editing
    //
    // A clause is a tree, and Settings lets you edit it as one. These are the
    // structural operations that editor needs; keeping them here (rather than
    // in the view) means the tree can only be reshaped in ways that stay a
    // valid clause, and it can be tested without a UI.

    /// The shape of a clause, independent of its contents — what the editor's
    /// kind picker chooses between.
    public enum Kind: String, CaseIterable, Sendable {
        case contains, containsAny, regex, lineRegex, all, any

        public var label: String {
            switch self {
            case .contains:    return "Shows all of"
            case .containsAny: return "Shows any of"
            case .regex:       return "Matches pattern"
            case .lineRegex:   return "Has a line matching"
            case .all:         return "All of these"
            case .any:         return "Any of these"
            }
        }

        public var isGroup: Bool { self == .all || self == .any }
    }

    /// This clause's kind. `not` reports the kind of what it negates — the
    /// editor shows negation as a switch on the node, not as a node of its own,
    /// because "does not show X" is one thought.
    public var kind: Kind {
        switch self {
        case .contains:    return .contains
        case .containsAny: return .containsAny
        case .regex:       return .regex
        case .lineRegex:   return .lineRegex
        case .all:         return .all
        case .any:         return .any
        case .not(let c):  return c.kind
        }
    }

    public var isNegated: Bool {
        if case .not = self { return true }
        return false
    }

    /// The clause under a `not`, or self.
    public var unnegated: MatchClause {
        if case .not(let c) = self { return c }
        return self
    }

    public func negated(_ on: Bool) -> MatchClause {
        on ? .not(unnegated) : unnegated
    }

    /// The text terms of a leaf clause: the substrings, or the single pattern.
    /// Empty for groups.
    public var terms: [String] {
        switch unnegated {
        case .contains(let s), .containsAny(let s): return s
        case .regex(let p), .lineRegex(let p):      return [p]
        case .all, .any:                            return []
        case .not:                                  return []
        }
    }

    /// Sub-clauses of a group, empty for leaves.
    public var children: [MatchClause] {
        switch unnegated {
        case .all(let cs), .any(let cs): return cs
        default:                         return []
        }
    }

    /// Same clause, same negation, new contents.
    public func with(terms: [String]) -> MatchClause {
        let rebuilt: MatchClause
        switch unnegated {
        case .contains:    rebuilt = .contains(terms)
        case .containsAny: rebuilt = .containsAny(terms)
        case .regex:       rebuilt = .regex(terms.first ?? "")
        case .lineRegex:   rebuilt = .lineRegex(terms.first ?? "")
        case .all, .any, .not: return self
        }
        return rebuilt.negated(isNegated)
    }

    public func with(children: [MatchClause]) -> MatchClause {
        let rebuilt: MatchClause
        switch unnegated {
        case .all: rebuilt = .all(children)
        case .any: rebuilt = .any(children)
        default:   return self
        }
        return rebuilt.negated(isNegated)
    }

    /// Convert to another kind, carrying across what can be carried: terms stay
    /// terms (a pattern keeps the first one), and a leaf becoming a group wraps
    /// itself so nothing the user typed is thrown away.
    public func converted(to kind: Kind) -> MatchClause {
        guard kind != self.kind else { return self }
        let negate = isNegated
        let existingTerms = terms
        let existingChildren = children
        let rebuilt: MatchClause
        switch kind {
        case .contains:    rebuilt = .contains(existingTerms.isEmpty ? [""] : existingTerms)
        case .containsAny: rebuilt = .containsAny(existingTerms.isEmpty ? [""] : existingTerms)
        case .regex:       rebuilt = .regex(existingTerms.first ?? "")
        case .lineRegex:   rebuilt = .lineRegex(existingTerms.first ?? "")
        case .all, .any:
            let kids: [MatchClause] = {
                if !existingChildren.isEmpty { return existingChildren }
                // A leaf turning into a group keeps itself as the first branch.
                return [unnegated]
            }()
            rebuilt = kind == .all ? .all(kids) : .any(kids)
        }
        return rebuilt.negated(negate)
    }

    public func replacingChild(at index: Int, with child: MatchClause) -> MatchClause {
        var kids = children
        guard kids.indices.contains(index) else { return self }
        kids[index] = child
        return with(children: kids)
    }

    public func removingChild(at index: Int) -> MatchClause {
        var kids = children
        guard kids.indices.contains(index) else { return self }
        kids.remove(at: index)
        // A group with one branch left is that branch — an "any of" with a
        // single condition is noise in the editor and in the summary.
        if kids.count == 1 { return kids[0].negated(isNegated) }
        return with(children: kids)
    }

    public func addingChild(_ child: MatchClause) -> MatchClause {
        guard kind.isGroup else { return self }
        return with(children: children + [child])
    }

    /// A blank leaf, for "add a condition".
    public static var newTextTerm: MatchClause { .contains([""]) }
}

/// One detection rule: when `clause` matches `region`, the pane takes `status`
/// (or, if `status` is nil, state is left unchanged — for transient overlays).
public struct DetectRule: Codable, Identifiable {
    /// Stable key (also what the engine reports as the matching rule). Never
    /// changes once created — the editor renames via `label`, so a rule you
    /// edited is still the same rule in a log or a bug report.
    public let id: String
    /// Everything below is `var`: Settings edits rules in place. (A rule is a
    /// guess about someone else's UI — the guess has to be correctable without
    /// shipping a new build.)
    public var status: AgentStatus?   // nil = skip (don't update state) when matched
    public var priority: Int
    public var region: DetectRegion
    public var clause: MatchClause
    /// Off = the engine walks straight past it. Settings' per-rule switch: a
    /// mis-firing built-in can be silenced without editing (or losing) it.
    public var isEnabled: Bool
    /// Set on rules the user added in Settings — they read differently in the
    /// editor (labelled as yours).
    public var isCustom: Bool
    /// A name the user gave this rule. `nil` = show the built-in id.
    public var label: String?

    /// What to call it in the UI.
    public var displayName: String {
        if let label, !label.isEmpty { return label }
        return id.replacingOccurrences(of: "_", with: " ")
    }

    public init(id: String, status: AgentStatus?, priority: Int,
                region: DetectRegion, clause: MatchClause,
                isEnabled: Bool = true, isCustom: Bool = false, label: String? = nil) {
        self.id = id; self.status = status; self.priority = priority
        self.region = region; self.clause = clause
        self.isEnabled = isEnabled; self.isCustom = isCustom; self.label = label
    }

    // Lenient: `isEnabled`/`isCustom` arrived after profiles were already on
    // disk, and a throwing decode here would fail the WHOLE profile array
    // (ProfileStore then backs up and reseeds, silently dropping user profiles).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.status = try c.decodeIfPresent(AgentStatus.self, forKey: .status)
        self.priority = try c.decode(Int.self, forKey: .priority)
        self.region = try c.decode(DetectRegion.self, forKey: .region)
        self.clause = try c.decode(MatchClause.self, forKey: .clause)
        self.isEnabled = (try? c.decode(Bool.self, forKey: .isEnabled)) ?? true
        self.isCustom = (try? c.decode(Bool.self, forKey: .isCustom)) ?? false
        self.label = try? c.decodeIfPresent(String.self, forKey: .label)
    }
}

/// The full rule set for one agent, plus how to recognize that agent. Now a
/// Codable value carried by a StateProfile (`profile.agentRules`) — the
/// hardcoded built-ins became preset data, and the whole thing is configurable
/// through the one ProfileStore.
public struct AgentRuleSet: Codable {
    public let id: String                 // e.g. "claude-code" (matches the StateProfile id)
    public var commandPatterns: [String]  // identity via pane_current_command (substring)
    public var titleIdentity: [String]    // identity via title (regex), for when the
                                          // foreground command name is unreliable
    /// Identity via the SCREEN (regex over the snapshot), for agents that are
    /// neither their own process name nor identifiable from the title. Codex is
    /// the case that forced it: it runs as `node`, and its title is just the
    /// working directory until it starts a turn. Only consulted for panes whose
    /// foreground command is a language runtime (see
    /// `StateDetectionService.runtimeCommands`), so it costs nothing on a
    /// shell/vim/git pane.
    public var screenIdentity: [String]
    public var rules: [DetectRule]        // any order; the engine sorts by priority desc
    /// Off = this agent isn't detected at all (panes fall back to activity
    /// detection). The settings switch for "stop guessing at this one".
    public var isEnabled: Bool

    public init(id: String, commandPatterns: [String], titleIdentity: [String],
                screenIdentity: [String] = [], rules: [DetectRule],
                isEnabled: Bool = true) {
        self.id = id; self.commandPatterns = commandPatterns
        self.titleIdentity = titleIdentity; self.screenIdentity = screenIdentity
        self.rules = rules; self.isEnabled = isEnabled
    }

    // Lenient for the same reason as DetectRule: stored profiles predate these
    // fields, and one throw would reseed the user's whole profile store.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.commandPatterns = (try? c.decode([String].self, forKey: .commandPatterns)) ?? []
        self.titleIdentity = (try? c.decode([String].self, forKey: .titleIdentity)) ?? []
        self.screenIdentity = (try? c.decode([String].self, forKey: .screenIdentity)) ?? []
        self.rules = (try? c.decode([DetectRule].self, forKey: .rules)) ?? []
        self.isEnabled = (try? c.decode(Bool.self, forKey: .isEnabled)) ?? true
    }
}

// MARK: - Trying a rule set out

/// What a rule set makes of one screen. Returned by `AgentRuleSet.evaluate`,
/// which Settings' "Try it" sheet uses so the answer it shows comes from the
/// real engine and not from a second implementation that could drift.
public struct RuleTrial {
    /// How the pane was recognized as this agent, if at all.
    public enum Identity: String {
        case command, title, screen, unrecognized
    }
    public let identity: Identity
    /// The rule that decided it (nil = nothing matched → the pane would fall
    /// back to output-activity detection).
    public let ruleID: String?
    /// nil with a non-nil `ruleID` means a "skip" rule: state left alone.
    public let status: AgentStatus?
}

public extension AgentRuleSet {
    /// Run this rule set against a pane exactly as the poller would.
    func evaluate(command: String?, title: String, screen: String?) -> RuleTrial {
        let detector = AgentDetector(ruleSets: [self])
        let identity: RuleTrial.Identity = {
            if let command, !command.isEmpty,
               commandPatterns.contains(where: { command.contains($0) }) { return .command }
            if titleIdentity.contains(where: { AgentDetector.regexMatches($0, in: title) }) { return .title }
            if let screen, screenIdentity.contains(where: { AgentDetector.regexMatches($0, in: screen) }) {
                return .screen
            }
            return .unrecognized
        }()
        let result = detector.classify(self, title: title, snapshot: screen)
        return RuleTrial(identity: identity, ruleID: result?.ruleID, status: result?.status)
    }
}

/// Stateless evaluator over the built-in agent rule sets.
struct AgentDetector {
    let ruleSets: [AgentRuleSet]

    static let shared = AgentDetector(ruleSets: AgentRuleSet.builtIns)

    /// The rule set whose agent is running in this pane, if any.
    func ruleSet(command: String?, title: String) -> AgentRuleSet? {
        for set in ruleSets where set.isEnabled {
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

    /// The rule set whose agent's chrome is on this screen, if any. The last
    /// resort for runtime-launched agents (`node …/codex`), where neither the
    /// process name nor the title says who it is.
    func ruleSet(screen: String) -> AgentRuleSet? {
        for set in ruleSets where set.isEnabled {
            if set.screenIdentity.contains(where: { Self.regexMatches($0, in: screen) }) {
                return set
            }
        }
        return nil
    }

    /// Look a set up by id — how a sticky (already-identified) pane re-resolves
    /// its rules without redoing identity every poll.
    func ruleSet(id: String) -> AgentRuleSet? {
        ruleSets.first { $0.id == id && $0.isEnabled }
    }

    /// Classify a pane. `snapshot` is the `capture-pane` text (nil if not
    /// fetched — then only title-region rules can match). Returns the matched
    /// rule's status (nil status = "skip"/leave unchanged) and its id, or nil if
    /// nothing matched (caller falls back to activity-based detection).
    func classify(_ set: AgentRuleSet, title: String, snapshot: String?)
        -> (status: AgentStatus?, ruleID: String, matched: Bool)?
    {
        let sorted = set.rules.filter(\.isEnabled).sorted { $0.priority > $1.priority }
        let lines = snapshot.map { Self.splitLines($0) }
        // Slice each region ONCE per classify, not once per rule. A rule set is
        // a dozen rules over three or four regions, and `regionText` re-joins
        // the whole snapshot every time it's asked — on the main thread, for
        // every pane, every two seconds.
        var regions: [DetectRegion: String?] = [:]
        for rule in sorted {
            let text: String?
            if let cached = regions[rule.region] {
                text = cached
            } else {
                text = regionText(rule.region, title: title, lines: lines)
                regions[rule.region] = text
            }
            guard let text else { continue }
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
            return nonEmpty.suffix(max(0, n)).joined(separator: "\n")
        case .topNonEmptyLines(let n):
            guard let lines else { return nil }
            let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return nonEmpty.prefix(max(0, n)).joined(separator: "\n")
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
            // An empty list would be vacuously true and match every screen.
            // Since Settings can now edit these, "nothing specified" has to mean
            // "no evidence", not "always" — a half-typed rule at the top of the
            // ladder would otherwise paint every pane. (An empty *string* term
            // is already safe: `range(of: "")` is nil, and an empty regex fails
            // to compile.)
            guard !subs.isEmpty else { return false }
            return subs.allSatisfy { text.range(of: $0, options: .caseInsensitive) != nil }
        case .containsAny(let subs):
            return subs.contains { text.range(of: $0, options: .caseInsensitive) != nil }
        case .regex(let pattern):
            return Self.regexMatches(pattern, in: text)
        case .lineRegex(let pattern):
            return text.split(separator: "\n", omittingEmptySubsequences: false)
                .contains { Self.regexMatches(pattern, in: String($0)) }
        case .all(let cs):
            guard !cs.isEmpty else { return false }   // same reason as `.contains`
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

    /// Compiled-regex cache, shared with StateDetectionService — detection
    /// runs every poll for several panes; the patterns are a small fixed set,
    /// so never recompile.
    static let regexCache = NSCache<NSString, NSRegularExpression>()

    static func compiled(_ pattern: String) -> NSRegularExpression? {
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

