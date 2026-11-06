import XCTest
import BentoTmuxKit
@testable import BentoAgentKit

/// The whole of state detection now: what the hook wrote, guarded by the
/// pane's foreground command.
final class AgentHookStateTests: XCTestCase {

    func testHookStatesMapOntoPaneStates() {
        XCTAssertTrue(AgentHookState.classify(agent: "claude", state: "working", command: "claude") == (.working, true))
        XCTAssertTrue(AgentHookState.classify(agent: "codex", state: "awaiting", command: "node")
                      == (.awaitingInput(profile: "codex"), true))
        XCTAssertTrue(AgentHookState.classify(agent: "claude", state: "done", command: "2.1.246") == (.idle, true))
    }

    func testAwaitingWithoutAnAgentNameStillCounts() {
        XCTAssertTrue(AgentHookState.classify(agent: nil, state: "awaiting", command: "node")
                      == (.awaitingInput(profile: "agent"), true))
    }

    func testNoHookNoDot() {
        XCTAssertTrue(AgentHookState.classify(agent: nil, state: nil, command: "cargo") == (.idle, false))
        XCTAssertTrue(AgentHookState.classify(agent: "claude", state: "", command: "claude") == (.idle, false))
        XCTAssertTrue(AgentHookState.classify(agent: "claude", state: "thinking", command: "claude") == (.idle, false))
    }

    /// An agent killed before its session-end hook ran leaves its last state
    /// behind. Once the pane is back at a shell prompt, that state is stale.
    func testStaleStateAtAShellPromptIsIgnored() {
        for shell in ["zsh", "-zsh", "/bin/bash", "fish"] {
            XCTAssertTrue(AgentHookState.classify(agent: "codex", state: "working", command: shell) == (.idle, false),
                          "\(shell) should read as a bare shell")
        }
    }

    @MainActor
    func testRecentTextStripsEscapesAndKeepsTheTail() {
        let text = PaneRecentText()
        let pane = TmuxPaneID(3)
        text.recordOutput(pane: pane, data: Data("\u{1b}[1mhello\u{1b}[0m\r\n\nworld\n".utf8))
        XCTAssertEqual(text.recentText(for: pane, lines: 5), "hello\nworld")
        XCTAssertEqual(text.recentText(for: pane, lines: 1), "world")
        text.clearPane(pane)
        XCTAssertEqual(text.recentText(for: pane, lines: 5), "")
    }
}
