import XCTest
import BentoTmuxKit
@testable import BentoAgentKit

/// Detection against REAL screens.
///
/// Every other test in this target feeds the engine text we wrote ourselves,
/// which can only prove the engine does what we think the agent does. These
/// fixtures are verbatim `tmux capture-pane -p -J` output — the same command
/// and flags the app issues — from live sessions of codex-cli 0.147.0 and
/// opencode 1.18.5 on 2026-08-13, each paired with the `pane_title` and
/// `pane_current_command` tmux reported at that instant (the `.meta` file).
///
/// They exist because both agents were detected incorrectly while every
/// hand-written test passed:
///   * codex runs as `node`, so it was never identified at all and none of its
///     rules ever ran;
///   * opencode's footer says `esc interrupt`, not the "esc to interrupt" the
///     rules were looking for, and it had no idle rule whatsoever.
///
/// To add a case: capture with `tmux capture-pane -t <pane> -p -J`, save the
/// title and command next to it, and give the state you actually observed.
final class LiveCaptureTests: XCTestCase {

    private let detector = AgentDetector.shared

    // MARK: - Fixture loading

    private struct Capture {
        let name: String
        let title: String
        let command: String
        let screen: String
    }

    private func capture(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> Capture {
        let bundle = Bundle.module
        guard let screenURL = bundle.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"),
              let metaURL = bundle.url(forResource: name, withExtension: "meta", subdirectory: "Fixtures")
        else {
            XCTFail("missing fixture \(name)", file: file, line: line)
            throw XCTSkip("missing fixture")
        }
        let meta = try String(contentsOf: metaURL, encoding: .utf8)
            .trimmingCharacters(in: .newlines)
            .components(separatedBy: "\t")
        return Capture(name: name,
                       title: meta.first ?? "",
                       command: meta.count > 1 ? meta[1] : "",
                       screen: try String(contentsOf: screenURL, encoding: .utf8))
    }

    /// The full production path for one capture: resolve identity the way
    /// `StateDetectionService` does (command/title, then the screen for a
    /// runtime pane), then classify.
    @MainActor
    private func classify(_ c: Capture) -> (agent: String?, status: AgentStatus?, rule: String?) {
        let service = StateDetectionService()
        let pane = TmuxPaneID(1)
        switch service.classifyAgent(command: c.command, title: c.title, snapshot: nil,
                                     pane: pane, current: .idle) {
        case .notAgent:
            return (nil, nil, nil)
        case .state, .needsSnapshot:
            break
        }
        // Second pass with the screen, exactly as the poller does.
        let result = service.classifyAgent(command: c.command, title: c.title, snapshot: c.screen,
                                           pane: pane, current: .idle)
        guard case .state(let state) = result else { return (nil, nil, nil) }
        let agent = service.identifiedAgent(for: pane)
        let set = agent.flatMap { id in detector.ruleSets.first { $0.id == id } }
        let matched = set.flatMap { detector.classify($0, title: c.title, snapshot: c.screen) }
        let status: AgentStatus? = {
            switch state {
            case .working:       return .working
            case .awaitingInput: return .blocked
            case .idle:          return .idle
            }
        }()
        return (agent, status, matched?.ruleID)
    }

    // MARK: - Codex (codex-cli 0.147.0)

    /// The identity bug itself, pinned: homebrew's codex is a node wrapper, so
    /// the command name says `node` and nothing else names it.
    func testCodexPaneReportsNodeAsItsCommand() throws {
        for name in ["codex-idle", "codex-working", "codex-blocked", "codex-trust"] {
            XCTAssertEqual(try capture(name).command, "node",
                           "\(name): fixture no longer shows the runtime-wrapper case it was captured for")
        }
        XCTAssertNil(detector.ruleSet(command: "node", title: "work"),
                     "a bare `node` pane must not be claimed by any agent on command alone")
    }

    @MainActor
    func testCodexWorkingTitleSpinner() throws {
        let r = classify(try capture("codex-working"))
        XCTAssertEqual(r.agent, "codex")
        XCTAssertEqual(r.status, .working)
        XCTAssertEqual(r.rule, "title_working_spinner")
    }

    @MainActor
    func testCodexApprovalFormIsBlocked() throws {
        let r = classify(try capture("codex-blocked"))
        XCTAssertEqual(r.agent, "codex")
        XCTAssertEqual(r.status, .blocked)
    }

    /// The blocked title arrives as `[ ! ] Action Required | work` — the marker
    /// is not at the start, which is why the title rules can't anchor at ^.
    func testCodexBlockedTitleIsNotAnchoredAtStart() throws {
        let c = try capture("codex-blocked")
        XCTAssertTrue(c.title.contains("Action Required"))
        XCTAssertFalse(c.title.hasPrefix("Action Required"))
        XCTAssertEqual(detector.ruleSet(command: c.command, title: c.title)?.id, "codex")
    }

    @MainActor
    func testCodexIdleIsIdleAndStillIdentified() throws {
        let r = classify(try capture("codex-idle"))
        XCTAssertEqual(r.agent, "codex", "an idle codex must still be recognized as an agent")
        XCTAssertEqual(r.status, .idle)
    }

    @MainActor
    func testCodexJustFinishedIsIdle() throws {
        XCTAssertEqual(classify(try capture("codex-idle2")).status, .idle)
    }

    /// A fresh codex opens on the trust gate — blocked, before it has ever set
    /// a spinner title. Identity here can only come from the screen: tmux still
    /// reports the shell's title (the hostname).
    @MainActor
    func testCodexTrustPromptIsBlocked() throws {
        let c = try capture("codex-trust")
        XCTAssertNil(detector.ruleSet(command: c.command, title: c.title),
                     "the trust screen's title is the shell's — identity must come from the screen")
        let r = classify(c)
        XCTAssertEqual(r.agent, "codex")
        XCTAssertEqual(r.status, .blocked)
        XCTAssertEqual(r.rule, "trust_directory")
    }

    /// Once a pane has been identified, it keeps its rules while the same
    /// command keeps running — codex's banner scrolls away, so without this an
    /// idle mid-session pane would go unrecognized on the next poll.
    @MainActor
    func testCodexIdentityStaysStickyAcrossPolls() throws {
        let service = StateDetectionService()
        let pane = TmuxPaneID(2)
        let working = try capture("codex-working")
        _ = service.classifyAgent(command: working.command, title: working.title,
                                  snapshot: working.screen, pane: pane, current: .idle)
        XCTAssertEqual(service.identifiedAgent(for: pane), "codex")

        // Same pane, now idle: the title is just the directory name and the
        // banner is long gone, so nothing on this poll names codex.
        let idle = try capture("codex-idle")
        XCTAssertNil(detector.ruleSet(command: idle.command, title: idle.title))
        let result = service.classifyAgent(command: idle.command, title: idle.title,
                                           snapshot: idle.screen, pane: pane, current: .working)
        guard case .state(let state) = result else {
            return XCTFail("sticky identity was lost between polls")
        }
        XCTAssertEqual(state, .idle)
    }

    /// …and it is dropped the moment the pane's command changes: quitting codex
    /// back to the shell must not leave the pane wearing codex's rules.
    @MainActor
    func testStickyIdentityDropsWhenTheCommandChanges() throws {
        let service = StateDetectionService()
        let pane = TmuxPaneID(3)
        let working = try capture("codex-working")
        _ = service.classifyAgent(command: working.command, title: working.title,
                                  snapshot: working.screen, pane: pane, current: .idle)
        XCTAssertEqual(service.identifiedAgent(for: pane), "codex")

        let after = service.classifyAgent(command: "zsh", title: "~/code", snapshot: "$ ",
                                          pane: pane, current: .idle)
        guard case .notAgent = after else {
            return XCTFail("a pane that returned to the shell is not an agent pane")
        }
        XCTAssertNil(service.identifiedAgent(for: pane))
    }

    /// A runtime pane that isn't an agent costs one probe, then goes quiet —
    /// otherwise every `node` dev server would pay a capture-pane every poll.
    @MainActor
    func testUnknownRuntimePaneIsProbedOnceThenLeftAlone() {
        let service = StateDetectionService()
        let pane = TmuxPaneID(4)
        guard case .needsSnapshot = service.classifyAgent(command: "node", title: "npm run dev",
                                                          snapshot: nil, pane: pane, current: .idle)
        else { return XCTFail("a node pane should be probed once") }

        guard case .notAgent = service.classifyAgent(command: "node", title: "npm run dev",
                                                      snapshot: "webpack compiled successfully\n",
                                                      pane: pane, current: .idle)
        else { return XCTFail("a dev server's screen names no agent") }

        // Immediately after a miss, the cheap pass must not ask for another
        // snapshot.
        guard case .notAgent = service.classifyAgent(command: "node", title: "npm run dev",
                                                      snapshot: nil, pane: pane, current: .idle)
        else { return XCTFail("the probe miss should suppress the next capture-pane") }
    }

    // MARK: - OpenCode (1.18.5)

    @MainActor
    func testOpenCodeIsIdentifiedByCommand() throws {
        // The binary reports as `opencode.exe`, which still contains "opencode".
        let c = try capture("opencode-idle")
        XCTAssertEqual(c.command, "opencode.exe")
        XCTAssertEqual(detector.ruleSet(command: c.command, title: c.title)?.id, "opencode")
    }

    @MainActor
    func testOpenCodePermissionFormIsBlocked() throws {
        let r = classify(try capture("opencode-blocked"))
        XCTAssertEqual(r.agent, "opencode")
        XCTAssertEqual(r.status, .blocked)
        XCTAssertEqual(r.rule, "permission_required")
    }

    @MainActor
    func testOpenCodeWorkingFooterIsWorking() throws {
        let r = classify(try capture("opencode-working"))
        XCTAssertEqual(r.status, .working)
    }

    /// 1.18.5 writes `esc interrupt`, not "esc to interrupt". The old rule list
    /// missed it, and only the progress-bar rule kept working detection alive.
    func testOpenCodeWorkingFooterWordingIsMatchedDirectly() throws {
        let screen = try capture("opencode-working").screen
        XCTAssertTrue(screen.contains("esc interrupt"))
        XCTAssertFalse(screen.contains("esc to interrupt"))
        let set = detector.ruleSet(command: "opencode", title: "")!
        // Feed the footer alone: the bar is not in it, so this is the wording
        // rule or nothing.
        let footer = "  esc interrupt   14.2K (1%)  ctrl+p commands"
        let r = detector.classify(set, title: "", snapshot: footer)
        XCTAssertEqual(r?.ruleID, "interrupt_hint_working")
        XCTAssertEqual(r?.status, .working)
    }

    @MainActor
    func testOpenCodeComposerIsIdle() throws {
        for name in ["opencode-idle", "opencode-idle2"] {
            let r = classify(try capture(name))
            XCTAssertEqual(r.agent, "opencode", "\(name)")
            XCTAssertEqual(r.status, .idle, "\(name) should read idle, not fall through to activity")
        }
    }

    // MARK: - Cost, measured on the real screens

    /// Detection runs on the main thread for every pane every two seconds, so
    /// the budget below is about the app staying usable, not about speed for
    /// its own sake. One classify over a real 120x40 screen, all built-ins
    /// swept (production runs exactly one set per pane).
    @MainActor
    func testClassifyingRealScreensStaysCheap() throws {
        let captures = try ["codex-blocked", "codex-idle", "opencode-working", "opencode-blocked"]
            .map { try capture($0) }
        let start = Date()
        for _ in 0..<10 {
            for c in captures {
                for set in AgentRuleSet.builtIns {
                    _ = detector.classify(set, title: c.title, snapshot: c.screen)
                }
            }
        }
        let perSweep = Date().timeIntervalSince(start) / 40
        XCTAssertLessThan(perSweep, 0.05,
                          "a full sweep of every built-in over one real screen took \(perSweep * 1000)ms")
    }
}
