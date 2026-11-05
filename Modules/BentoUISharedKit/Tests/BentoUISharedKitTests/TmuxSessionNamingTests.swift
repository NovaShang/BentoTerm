import Testing
@testable import BentoUISharedKit

/// A typed session name keeps what tmux takes and loses only the target
/// separators, which tmux would otherwise rewrite behind our back.
@Suite("Typed tmux session names")
struct TypedSessionNameTests {

    @Test func separatorsBecomeDashes() {
        #expect(TmuxSessionNaming.typed("foo.bar") == "foo-bar")
        #expect(TmuxSessionNaming.typed("a:b") == "a-b")
    }

    @Test func spacesInsideAreTheUsersToKeep() {
        #expect(TmuxSessionNaming.typed("  my project \n") == "my project")
    }

    @Test func blankIsNoName() {
        #expect(TmuxSessionNaming.typed("") == nil)
        #expect(TmuxSessionNaming.typed("   ") == nil)
    }
}
