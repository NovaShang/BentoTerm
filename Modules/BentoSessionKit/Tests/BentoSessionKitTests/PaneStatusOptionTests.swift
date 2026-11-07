import XCTest
import BentoTmuxKit
@testable import BentoSessionKit

/// The whole of state detection now: what the pane's `@bento_state` option
/// says, guarded by the pane's foreground command.
final class PaneStatusOptionTests: XCTestCase {

    func testOptionValuesMapOntoPaneStates() {
        XCTAssertTrue(PaneStatusOption.classify(value: "working", command: "claude") == (.working, true))
        XCTAssertTrue(PaneStatusOption.classify(value: "awaiting", command: "node") == (.awaitingInput, true))
        XCTAssertTrue(PaneStatusOption.classify(value: "done", command: "2.1.246") == (.idle, true))
    }

    func testNoOptionNoDot() {
        XCTAssertTrue(PaneStatusOption.classify(value: nil, command: "cargo") == (.idle, false))
        XCTAssertTrue(PaneStatusOption.classify(value: "", command: "claude") == (.idle, false))
        XCTAssertTrue(PaneStatusOption.classify(value: "thinking", command: "claude") == (.idle, false))
    }

    /// A program killed before it cleared the option leaves its last state
    /// behind. Once the pane is back at a shell prompt, that state is stale.
    func testStaleStateAtAShellPromptIsIgnored() {
        for shell in ["zsh", "-zsh", "/bin/bash", "fish"] {
            XCTAssertTrue(PaneStatusOption.classify(value: "working", command: shell) == (.idle, false),
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
