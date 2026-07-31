import Testing
@testable import Bento
import BentoTerminalCore
import SwiftTmux

@Suite("State Detection Tests")
@MainActor
struct StateDetectionTests {
    @Test func detectAwaitingInput() {
        let service = StateDetectionService()
        let pane = TmuxPaneID(0)

        // Feed output that matches a shell prompt pattern
        let data = "Do you want to continue? [y/N] ".data(using: .utf8)!
        service.recordOutput(pane: pane, data: data)

        let state = service.detectState(pane: pane, currentCommand: nil)
        if case .awaitingInput = state {
            // Expected
        } else {
            Issue.record("Expected awaitingInput, got \(state)")
        }
    }

    @Test func detectWorking() {
        let service = StateDetectionService()
        let pane = TmuxPaneID(0)

        let data = "Compiling module 'App'...\n".data(using: .utf8)!
        service.recordOutput(pane: pane, data: data)

        let state = service.detectState(pane: pane, currentCommand: nil)
        #expect(state == .working)
    }
}
