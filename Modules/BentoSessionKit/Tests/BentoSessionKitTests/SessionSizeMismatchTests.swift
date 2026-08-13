import Foundation
import Testing
@testable import BentoSessionKit

/// The banner's two rules, which are decisions rather than mechanics: WHO it
/// names, and WHEN it stops to ask.
@Suite struct SessionSizeMismatchTests {

    private func mismatch(_ mode: TerminalSizingMode, owner: String?) -> SessionSizeMismatch {
        SessionSizeMismatch(mode: mode, owner: owner,
                            sessionCols: 120, sessionRows: 30,
                            deviceCols: 180, deviceRows: 48)
    }

    @Test func onlyANamedOwnerIsWorthConfirming() {
        // Someone claimed the size explicitly and is about to lose it.
        #expect(mismatch(.thisDevice, owner: "Shang’s iPad").needsConfirmation)
        // Nobody claimed anything: tmux derives the size from the attached
        // clients, so there is no one on the other end of a confirmation.
        #expect(!mismatch(.tracking, owner: nil).needsConfirmation)
        #expect(!mismatch(.smallest, owner: nil).needsConfirmation)
    }

    @Test func theOwnerIsNamedAndTheOthersAreExplained() {
        #expect(mismatch(.thisDevice, owner: "Shang’s iPad").title.contains("Shang’s iPad"))
        // `manual` with no owner recorded is an older build's freeze, not a
        // device — it must not claim someone else is holding the size.
        #expect(!mismatch(.thisDevice, owner: nil).title.contains("device"))
        // The client-derived policies say what decides the size instead.
        #expect(mismatch(.tracking, owner: nil).title != mismatch(.smallest, owner: nil).title)
    }

    @Test func theConfirmationSaysWhatTheOtherDeviceLoses() {
        let m = mismatch(.thisDevice, owner: "Shang’s iPad")
        #expect(m.confirmMessage.contains("Shang’s iPad"))
        #expect(m.confirmMessage.contains("stops setting the session size"))
        // …and what this device ends up with.
        #expect(m.confirmMessage.contains("180×48"))
    }

    @Test func bothGridsAreOnScreenEitherWay() {
        let m = mismatch(.tracking, owner: nil)
        #expect(m.detail.contains("120×30") && m.detail.contains("180×48"))
        #expect(m.compactDetail.contains("120×30") && m.compactDetail.contains("180×48"))
        // The tap's name is the mode it switches to, so the banner and the
        // Session Size menu agree about what just happened.
        #expect(m.actionTitle == TerminalSizingMode.thisDevice.title)
    }
}
