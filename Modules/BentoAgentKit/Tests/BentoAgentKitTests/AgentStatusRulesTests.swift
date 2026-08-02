import XCTest
@testable import BentoAgentKit

/// Fixtures are trimmed from real `tmux capture-pane` output of a live Claude
/// Code session (2026-06-21), so these lock the rules to actual UI, not guesses.
final class AgentStatusRulesTests: XCTestCase {

    private let detector = AgentDetector.shared

    private func claude() -> AgentRuleSet {
        let set = detector.ruleSet(command: "claude", title: "✳ anything")
        XCTAssertNotNil(set, "claude command should resolve the Claude rule set")
        return set!
    }

    // Real idle screen: empty ❯ box between two rules, footer has the mode hint.
    private let idleSnapshot = """
      ◼ build + 浏览器验证各门窗类型 + 提交 PR 部署

    ────────────────────────────────────────────────────────────────────────────
    ❯
    ────────────────────────────────────────────────────────────────────────────
      ⏵⏵ auto mode on (shift+tab to cycle) · ctrl+t to hide tasks · ← for age…
    """

    // Real working screen: live status line + `esc to interrupt` in the footer.
    private let workingSnapshot = """
    · Inferring… (1m 12s · ↓ 4.2k tokens)
    ────────────────────────────────────────────────────────────────────────────
    ❯
    ────────────────────────────────────────────────────────────────────────────
      ⏵⏵ auto mode on (shift+tab to cycle) · esc to interrupt   Update available!
    """

    func testIdentityByCommand() {
        XCTAssertNotNil(detector.ruleSet(command: "claude", title: ""))
        XCTAssertNil(detector.ruleSet(command: "zsh", title: "~/code"))
        XCTAssertNil(detector.ruleSet(command: nil, title: "Shangs-Air-2"))
    }

    func testTitleSpinnerIsWorking_noSnapshotNeeded() {
        // Braille spinner prefix → working, decided from the title alone.
        let r = detector.classify(claude(), title: "⠐ Diagnose Mac typing lag", snapshot: nil)
        XCTAssertEqual(r?.status, .working)
        XCTAssertEqual(r?.ruleID, "title_working_spinner")
    }

    func testTitleStarIsIdle() {
        let r = detector.classify(claude(), title: "✳ Define scope", snapshot: idleSnapshot)
        XCTAssertEqual(r?.status, .idle)
    }

    func testIdlePromptBoxFromRealSnapshot() {
        // Even with a neutral title, the empty ❯ box → idle.
        let r = detector.classify(claude(), title: "Define scope", snapshot: idleSnapshot)
        XCTAssertEqual(r?.status, .idle)
        XCTAssertEqual(r?.ruleID, "idle_prompt_box")
    }

    func testWorkingFooterBeatsIdlePromptBox() {
        // The working footer (`esc to interrupt`) outranks the ❯ box → working,
        // even though an empty ❯ is also on screen.
        let r = detector.classify(claude(), title: "Diagnose", snapshot: workingSnapshot)
        XCTAssertEqual(r?.status, .working)
        XCTAssertEqual(r?.ruleID, "footer_working")
    }

    func testPermissionPromptIsBlocked() {
        // Provisional blocked fixture (calibrate against a live capture).
        let blocked = """
        ╭──────────────────────────────────────────────╮
        │ Bash command                                   │
        │ rm -rf build/                                   │
        │                                                │
        │ Do you want to proceed?                        │
        │ ❯ 1. Yes                                       │
        │   2. No, and tell Claude what to do (esc)      │
        ╰──────────────────────────────────────────────╯
          esc to cancel
        """
        let r = detector.classify(claude(), title: "✳ task", snapshot: blocked)
        XCTAssertEqual(r?.status, .blocked)
    }

    func testHorizontalRuleDetection() {
        XCTAssertTrue(AgentDetector.isHorizontalRule(String(repeating: "─", count: 40)))
        XCTAssertTrue(AgentDetector.isHorizontalRule("  " + String(repeating: "─", count: 20)))
        XCTAssertFalse(AgentDetector.isHorizontalRule("❯ hello world"))
        XCTAssertFalse(AgentDetector.isHorizontalRule("── short"))
    }

    // MARK: - Unified Codable rule engine (the hardcoded rules are now preset DATA)

    /// The rich rules round-trip through JSON losslessly — i.e. they're real
    /// serializable data now, not Swift-only literals.
    func testAgentRuleSetCodableRoundTrip() throws {
        let original = AgentRuleSet.claudeCode
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AgentRuleSet.self, from: data)
        XCTAssertEqual(decoded.id, "claude-code")
        XCTAssertEqual(decoded.rules.count, original.rules.count)
        // Lossless: the decoded value classifies the real snapshots identically.
        XCTAssertEqual(detector.classify(decoded, title: "x", snapshot: idleSnapshot)?.ruleID,
                       "idle_prompt_box")
        XCTAssertEqual(detector.classify(decoded, title: "x", snapshot: workingSnapshot)?.status,
                       .working)
    }

    /// The one unified type (StateProfile) carries the rich rules + boundary, and
    /// the whole profile round-trips.
    func testStateProfileCarriesRulesAndBoundary() throws {
        let p = ProfileStore.claudeCode
        XCTAssertNotNil(p.agentRules, "claude-code preset must carry the rich rules as data")
        XCTAssertEqual(p.agentRules?.id, "claude-code")
        XCTAssertFalse(p.promptBoundary.isEmpty, "claude-code must have a turn-boundary regex")
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(StateProfile.self, from: data)
        XCTAssertEqual(decoded.agentRules?.rules.count, p.agentRules?.rules.count)
        XCTAssertEqual(decoded.promptBoundary, p.promptBoundary)
    }

    /// The APP path builds the detector from the profiles' `agentRules` — it must
    /// classify identically to the standalone detector (proves the store-driven
    /// path is equivalent to the old hardcoded one).
    func testStoreDerivedDetectorMatchesHardcoded() {
        let fromData = AgentDetector(ruleSets: [ProfileStore.claudeCode].compactMap(\.agentRules))
        guard let set = fromData.ruleSet(command: "claude", title: "") else {
            return XCTFail("data-derived detector should resolve the claude rule set")
        }
        XCTAssertEqual(fromData.classify(set, title: "✳ x", snapshot: idleSnapshot)?.status, .idle)
        XCTAssertEqual(fromData.classify(set, title: "x", snapshot: workingSnapshot)?.status, .working)
        XCTAssertEqual(fromData.classify(set, title: "⠐ x", snapshot: nil)?.status, .working)
    }

    /// The turn-boundary regex matches a real user turn but NOT the empty live
    /// prompt (❯+NBSP) or assistant/status lines.
    func testPromptBoundaryMatchesUserTurnNotEmptyPrompt() {
        let pat = ProfileStore.claudeCode.promptBoundary.first!
        func m(_ s: String) -> Bool { AgentDetector.regexMatches(pat, in: s) }
        XCTAssertTrue(m("\u{276F} In one short line, output ALPHA"))  // user turn
        XCTAssertFalse(m("\u{276F}\u{00A0}"))                         // empty live prompt (NBSP)
        XCTAssertFalse(m("\u{23FA} ALPHA"))                          // assistant line
        XCTAssertFalse(m("\u{273B} Worked for 3s"))                  // status line
    }
}
