import XCTest
@testable import BentoSessionKit

/// The host list's dot and the Live Activity both read a session's phase
/// through `liveness`; the setup steps must all read as connecting.
final class SessionPhaseLivenessTests: XCTestCase {

    func testEveryPhaseHasOneLiveness() {
        XCTAssertEqual(SessionPhase.tmuxReady.liveness, .live)
        XCTAssertEqual(SessionPhase.shellReady.liveness, .live)
        XCTAssertEqual(SessionPhase.sshConnecting.liveness, .connecting)
        XCTAssertEqual(SessionPhase.choosingSession.liveness, .connecting)
        XCTAssertEqual(SessionPhase.starting.liveness, .connecting)
        XCTAssertEqual(SessionPhase.suspended.liveness, .suspended)
        XCTAssertEqual(SessionPhase.ended.liveness, .ended)
    }
}
