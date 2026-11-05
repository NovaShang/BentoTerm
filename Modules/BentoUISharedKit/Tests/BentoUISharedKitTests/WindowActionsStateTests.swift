import Testing
import BentoTmuxKit
@testable import BentoUISharedKit

/// The window menus' shared state: what a request leaves behind for the
/// dialog it raises, and which windows can step earlier or later.
@MainActor
@Suite("Window actions state")
struct WindowActionsStateTests {

    private let a = TmuxWindowID(string: "@1")!
    private let b = TmuxWindowID(string: "@2")!
    private let c = TmuxWindowID(string: "@3")!

    @Test func renameSeedsTheFieldWithTheCurrentName() {
        let state = WindowActionsState()
        state.requestRename(b, current: "server")
        #expect(state.pendingRename == b)
        #expect(state.renameText == "server")
    }

    /// The new-session prompt never reopens holding the last name typed.
    @Test func moveToNewSessionStartsEmpty() {
        let state = WindowActionsState()
        state.moveSessionName = "leftover"
        state.requestMoveToNewSession(a)
        #expect(state.pendingMove == a)
        #expect(state.moveSessionName.isEmpty)
    }

    @Test func endsCannotShiftPastThemselves() {
        let order = [a, b, c]
        #expect(!WindowActionsState.canShift(a, earlier: true, in: order))
        #expect(WindowActionsState.canShift(a, earlier: false, in: order))
        #expect(WindowActionsState.canShift(b, earlier: true, in: order))
        #expect(WindowActionsState.canShift(b, earlier: false, in: order))
        #expect(WindowActionsState.canShift(c, earlier: true, in: order))
        #expect(!WindowActionsState.canShift(c, earlier: false, in: order))
    }

    /// A window that's gone (closed from another client) can't move at all.
    @Test func aMissingWindowCannotShift() {
        #expect(!WindowActionsState.canShift(c, earlier: true, in: [a, b]))
        #expect(!WindowActionsState.canShift(c, earlier: false, in: [a, b]))
    }
}
