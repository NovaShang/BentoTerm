import XCTest
@testable import BentoAgentKit

/// Coverage for the non-Claude rule sets (AgentRulePresets.swift). Fixtures are
/// synthesized from the UI strings documented in herdr's detection manifests —
/// the factual evidence source for these agents — so they lock our re-expression
/// to that evidence until we replace them with first-hand captures.
final class AgentRulePresetsTests: XCTestCase {

    private let detector = AgentDetector.shared

    private func set(_ command: String) -> AgentRuleSet {
        guard let s = detector.ruleSet(command: command, title: "") else {
            fatalError("no rule set resolves for command \(command)")
        }
        return s
    }

    // MARK: - Registry

    func testBuiltInsResolveByCommand() {
        for (command, id) in [
            ("claude", "claude-code"), ("codex", "codex"), ("gemini", "gemini"),
            ("opencode", "opencode"), ("hermes", "hermes"), ("agy", "antigravity"),
            ("cursor-agent", "cursor-agent"), ("copilot", "copilot"),
            ("amp", "amp"), ("cline", "cline"),
        ] {
            XCTAssertEqual(detector.ruleSet(command: command, title: "")?.id, id,
                           "command \(command) should resolve rule set \(id)")
        }
        XCTAssertNil(detector.ruleSet(command: "zsh", title: "~/code"))
    }

    func testBuiltInIDsAreUnique() {
        let ids = AgentRuleSet.builtIns.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    /// Every built-in profile that carries agentRules must use the same id for
    /// both — the quick-keys lookup keys `.awaitingInput(profile:)` by it.
    @MainActor
    func testProfileAndRuleSetIDsAgree() {
        for p in ProfileStore.defaultProfiles {
            guard let rules = p.agentRules else { continue }
            XCTAssertEqual(p.id, rules.id, "profile \(p.id) carries rules id \(rules.id)")
        }
    }

    // MARK: - Codex

    func testCodexTitleActionRequiredIsBlocked() {
        let r = detector.classify(set("codex"), title: "Action Required: approve command", snapshot: nil)
        XCTAssertEqual(r?.status, .blocked)
    }

    func testCodexTitleSpinnerIsWorking() {
        let r = detector.classify(set("codex"), title: "⠧ Running tests", snapshot: nil)
        XCTAssertEqual(r?.status, .working)
    }

    func testCodexStrongBlockerBelowPromptMarker() {
        let snapshot = """
        Some earlier prose mentioning press enter to confirm or esc to cancel.
        › fix the build
        Allow command?
          press enter to confirm or esc to cancel
        """
        let r = detector.classify(set("codex"), title: "Codex", snapshot: snapshot)
        XCTAssertEqual(r?.status, .blocked)
        XCTAssertEqual(r?.ruleID, "strong_blocker_form")
    }

    /// The same form text ABOVE the last `›` prompt line is history, not live
    /// UI — the marker-scoped strong rule must not fire (the weak whole-screen
    /// rule may still, at lower priority, but not for this text).
    func testCodexFormAbovePromptMarkerIsNotStrongBlocked() {
        let snapshot = """
        Allow command?
          press enter to confirm or esc to cancel
        › continue please
        ⠋ working on it
        """
        let r = detector.classify(set("codex"), title: "Codex", snapshot: snapshot)
        XCTAssertNotEqual(r?.ruleID, "strong_blocker_form")
    }

    func testCodexNeutralTitleIsIdle() {
        let r = detector.classify(set("codex"), title: "Codex — ~/project", snapshot: "all done\n")
        XCTAssertEqual(r?.status, .idle)
    }

    // MARK: - Gemini

    func testGeminiApplyChangeIsBlocked() {
        let snapshot = """
        │ Apply this change
        │ ● yes, allow once
        """
        XCTAssertEqual(detector.classify(set("gemini"), title: "", snapshot: snapshot)?.status, .blocked)
    }

    func testGeminiEscCancelIsWorking() {
        XCTAssertEqual(detector.classify(set("gemini"), title: "", snapshot: "thinking… (esc to cancel)")?.status, .working)
    }

    /// Live calibration 2026-07-07: gemini runs under `node`, so identity must
    /// come from its `◇` title, and the first-run ToS picker is blocked.
    func testGeminiIdentityByTitleNotCommand() {
        XCTAssertEqual(detector.ruleSet(command: "node", title: "◇  Ready (speakterm)")?.id, "gemini")
    }

    func testGeminiFirstRunPickerIsBlocked() {
        let snapshot = """
        │   (Use Enter to select)
        │   Terms of Services and Privacy Notice for Gemini CLI
        """
        XCTAssertEqual(detector.classify(set("gemini"), title: "◇  Ready (x)", snapshot: snapshot)?.status, .blocked)
    }

    func testGeminiReadyTitleIsIdle() {
        let r = detector.classify(set("gemini"), title: "◇  Ready (speakterm)", snapshot: "prose\n")
        XCTAssertEqual(r?.status, .idle)
    }

    // MARK: - OpenCode

    func testOpenCodePermissionRequiredIsBlocked() {
        XCTAssertEqual(detector.classify(set("opencode"), title: "",
                                          snapshot: "△ Permission required\nbash: rm -rf build")?.status, .blocked)
    }

    func testOpenCodeInterruptHintIsWorking() {
        XCTAssertEqual(detector.classify(set("opencode"), title: "",
                                          snapshot: "working…  esc to interrupt")?.status, .working)
    }

    // MARK: - Hermes

    func testHermesDangerousCommandIsBlocked() {
        let snapshot = """
        dangerous command detected
        allow once   allow for this session   deny
        enter to confirm
        """
        XCTAssertEqual(detector.classify(set("hermes"), title: "", snapshot: snapshot)?.status, .blocked)
    }

    // MARK: - Antigravity

    func testAntigravityPermissionIsBlocked() {
        let snapshot = """
        requesting permission for: rm -rf build
        do you want to proceed?
        """
        XCTAssertEqual(detector.classify(set("agy"), title: "", snapshot: snapshot)?.status, .blocked)
    }

    func testAntigravitySpinnerLineIsWorking() {
        XCTAssertEqual(detector.classify(set("agy"), title: "",
                                          snapshot: "⠸⠼ Thinking about the plan")?.status, .working)
    }

    // MARK: - Cursor Agent

    func testCursorWriteApprovalIsBlocked() {
        let snapshot = """
        write to this file? src/main.rs
        proceed (y)   reject & propose changes
        """
        let r = detector.classify(set("cursor-agent"), title: "", snapshot: snapshot)
        XCTAssertEqual(r?.status, .blocked)
        XCTAssertEqual(r?.ruleID, "write_file_approval")
    }

    func testCursorStopHintIsWorking() {
        XCTAssertEqual(detector.classify(set("cursor-agent"), title: "",
                                          snapshot: "generating…  ctrl+c to stop")?.status, .working)
    }

    // MARK: - Copilot (blocked outranks working on the shared esc-cancel hint)

    func testCopilotSelectionFormBeatsWorkingHint() {
        let snapshot = """
        Choose an option
        ↑/↓ move · enter to select · esc to cancel
        """
        XCTAssertEqual(detector.classify(set("copilot"), title: "", snapshot: snapshot)?.status, .blocked)
    }

    func testCopilotCancelHintAloneIsWorking() {
        XCTAssertEqual(detector.classify(set("copilot"), title: "",
                                          snapshot: "running tools… esc to cancel")?.status, .working)
    }

    // MARK: - Amp / Cline

    func testAmpApprovalFooterIsBlocked() {
        XCTAssertEqual(detector.classify(set("amp"), title: "",
                                          snapshot: "waiting for approval — run this command?")?.status, .blocked)
    }

    func testClineToolPermissionIsBlocked() {
        XCTAssertEqual(detector.classify(set("cline"), title: "",
                                          snapshot: "Let Cline use this tool?  yes / no")?.status, .blocked)
    }

    /// Cline has no working/idle rules on purpose — unmatched panes fall back
    /// to output-activity detection.
    func testClineQuietScreenMatchesNothing() {
        XCTAssertNil(detector.classify(set("cline"), title: "", snapshot: "just prose\n"))
    }

    // MARK: - Claude additions (transcript / picker skips, bash permission)

    private func claude() -> AgentRuleSet { set("claude") }

    func testClaudeTranscriptViewerIsSkip() {
        let snapshot = """
        lots of transcript text
        showing detailed transcript · ctrl+o to toggle
        """
        let r = detector.classify(claude(), title: "x", snapshot: snapshot)
        XCTAssertEqual(r?.ruleID, "transcript_viewer")
        XCTAssertNil(r?.status, "transcript viewer must be a skip rule (state unchanged)")
    }

    func testClaudeBashPermissionIsBlocked() {
        let snapshot = """
        Bash command
          rm -rf build/
        Do you want to proceed?
        ❯ 1. Yes
          2. No, and tell Claude what to do differently (tab to amend)
        """
        let r = detector.classify(claude(), title: "x", snapshot: snapshot)
        XCTAssertEqual(r?.status, .blocked)
    }

    func testClaudeModelPickerIsSkip() {
        let snapshot = """
        Select model
        1. Sonnet    2. Opus
        enter to set as default · esc to cancel
        """
        let r = detector.classify(claude(), title: "x", snapshot: snapshot)
        XCTAssertEqual(r?.ruleID, "model_picker")
        XCTAssertNil(r?.status)
    }

    // MARK: - Cost guards
    //
    // Detection runs on the MAIN THREAD for every pane every poll, so a rule
    // that is merely slow is a product bug: an idle opencode pane once cost
    // ~500ms per poll and made the whole app unusable. Neither guard below
    // asserts on detection *results* — they bound what a rule may cost.

    /// Collect every regex pattern a clause evaluates, recursing into and/or/not.
    private func patterns(_ clause: MatchClause) -> [String] {
        switch clause {
        case .contains, .containsAny:      return []
        case .regex(let p), .lineRegex(let p): return [p]
        case .all(let cs), .any(let cs):   return cs.flatMap(patterns)
        case .not(let c):                  return patterns(c)
        }
    }

    /// A leading unbounded wildcard is always redundant — `firstMatch` already
    /// searches the whole string — and it forces ICU to retry from every offset
    /// with a backtracking `.*`, which is quadratic in line length. Since
    /// `capture-pane -J` joins wrapped lines, one streamed paragraph is a single
    /// very long line, and the cost lands on the main thread.
    func testNoRuleStartsWithAnUnboundedWildcard() {
        for set in AgentRuleSet.builtIns {
            for rule in set.rules {
                for p in patterns(rule.clause) {
                    let body = p.hasPrefix("(?i)") ? String(p.dropFirst(4)) : p
                    XCTAssertFalse(body.hasPrefix(".*") || body.hasPrefix(".+"),
                                   """
                                   \(set.id)/\(rule.id): pattern \(p) starts with an \
                                   unbounded wildcard. Drop it — it matches the same \
                                   text and removes the quadratic backtracking.
                                   """)
                }
            }
        }
    }

    /// End-to-end budget. The snapshot is a real pane's worth of text (78x318
    /// ≈ 25KB) reshaped the way `capture-pane -J` does it — same characters,
    /// folded into few very long lines — and matches nothing, so every rule
    /// runs to exhaustion. Only ONE rule set runs per pane in production; this
    /// sweeps all of them, so it carries roughly 10x headroom on top of a
    /// budget that is already ~6x the measured cost. It won't flake on a loaded
    /// machine, and it fires on the quadratic-backtracking class of bug (which
    /// put this single sweep at ~3s before the fix above).
    func testWorstCaseSnapshotClassifiesWithinBudget() {
        let body = String(repeating: "streaming a long wrapped markdown paragraph. ", count: 28)
        let snapshot = Array(repeating: String(body.prefix(1240)), count: 20)
            .joined(separator: "\n")
        let start = Date()
        for set in AgentRuleSet.builtIns {
            _ = detector.classify(set, title: "working", snapshot: snapshot)
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 1.0,
                          "classifying all built-ins over a joined snapshot took \(elapsed)s")
    }

    /// The fix above must not cost detection: opencode's footer wording that
    /// only the regex catches ("esc again to interrupt" is not in the substring
    /// list) still resolves to working.
    func testOpencodeInterruptFooterStillDetected() {
        let snapshot = """
        > summarise the repo

        opencode v0.3.1                                    esc again to interrupt
        """
        let r = detector.classify(set("opencode"), title: "x", snapshot: snapshot)
        XCTAssertEqual(r?.ruleID, "interrupt_hint_working")
        XCTAssertEqual(r?.status, .working)
    }
}
