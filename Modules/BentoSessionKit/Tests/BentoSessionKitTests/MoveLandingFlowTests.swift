import XCTest
@testable import BentoSessionKit

/// The ask-and-retry around a cross-session move. Every move UI (Mac pane menu,
/// Mac window strip, sidebar, iPhone tabs, iOS pane menu) runs through this, so
/// the prompt is only shown when the target really is unsettled, and a cancel
/// never moves anything.
@MainActor
final class MoveLandingFlowTests: XCTestCase {

    /// A settled target lands on the first try and never asks.
    func testSettledTargetNeverAsks() async {
        var attempts: [MoveLanding] = []
        var asked = false
        let result = await TerminalViewModel.move(toSession: "work", chooseLanding: { _ in
            asked = true
            return .newWindow
        }, attempt: { landing in
            attempts.append(landing)
            return .moved
        })
        XCTAssertEqual(result, .moved)
        XCTAssertEqual(attempts, [.auto])
        XCTAssertFalse(asked)
    }

    /// An unsettled target asks once, naming the target, and retries with the
    /// answer.
    func testUnsettledTargetAsksThenRetriesWithTheAnswer() async {
        var attempts: [MoveLanding] = []
        var askedFor: [String] = []
        let result = await TerminalViewModel.move(toSession: "work", chooseLanding: { name in
            askedFor.append(name)
            return .joinCurrentWindow
        }, attempt: { landing in
            attempts.append(landing)
            return landing == .auto ? .needsLandingChoice : .moved
        })
        XCTAssertEqual(result, .moved)
        XCTAssertEqual(askedFor, ["work"])
        XCTAssertEqual(attempts, [.auto, .joinCurrentWindow])
    }

    /// Cancelling the prompt moves nothing.
    func testCancellingMovesNothing() async {
        var attempts: [MoveLanding] = []
        let result = await TerminalViewModel.move(toSession: "work", chooseLanding: { _ in nil },
                                                  attempt: { landing in
            attempts.append(landing)
            return .needsLandingChoice
        })
        XCTAssertEqual(result, .needsLandingChoice)
        XCTAssertEqual(attempts, [.auto])
    }

    /// A failure is reported as-is, without asking.
    func testFailureIsNotAPrompt() async {
        var asked = false
        let result = await TerminalViewModel.move(toSession: "work", chooseLanding: { _ in
            asked = true
            return .newWindow
        }, attempt: { _ in .failed })
        XCTAssertEqual(result, .failed)
        XCTAssertFalse(asked)
    }
}
