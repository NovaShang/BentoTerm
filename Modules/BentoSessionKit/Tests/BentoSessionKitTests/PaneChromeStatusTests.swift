import XCTest
@testable import BentoSessionKit

/// The wash both hosts lay over a pane body, and that the iOS surround blends
/// in — one table, so the two can't drift again.
final class PaneChromeStatusTests: XCTestCase {

    func testIdleHasNoWash() {
        XCTAssertNil(PaneChrome.Status.idle.wash)
    }

    func testStateWashesFollowThePaneStatePalette() {
        let working = PaneChrome.Status(state: .working, doneUnseen: false).wash
        XCTAssertEqual(working?.hex, PaneState.workingHex)
        XCTAssertEqual(working?.alpha, PaneState.working.tintAlpha)

        let awaiting = PaneChrome.Status(state: .awaitingInput,
                                         doneUnseen: false).wash
        XCTAssertEqual(awaiting?.hex, PaneState.awaitingHex)
        XCTAssertEqual(awaiting?.alpha, 0.12)
    }

    /// A finished-while-away pane washes green even though its PaneState has
    /// settled back to idle — the case the iOS surface wash used to miss.
    func testDoneUnseenWashesGreenOverAnIdlePane() {
        let done = PaneChrome.Status(state: .idle, doneUnseen: true).wash
        XCTAssertEqual(done?.hex, PaneState.doneUnseenHex)
        XCTAssertEqual(done?.alpha, 0.10)
    }
}
