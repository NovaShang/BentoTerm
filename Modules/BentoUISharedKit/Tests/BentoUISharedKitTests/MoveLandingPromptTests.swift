import Testing
import BentoSessionKit
@testable import BentoUISharedKit

/// The SwiftUI hosts' landing question as an `await`: the dialog is state, so
/// the prompt has to turn a button tap back into the move's answer.
@MainActor
@Suite("Move landing prompt")
struct MoveLandingPromptTests {

    @Test func theTappedChoiceIsTheAnswer() async {
        let prompt = MoveLandingPrompt()
        async let answer = prompt.ask("work")
        await settle { prompt.session == "work" }
        #expect(prompt.session == "work")
        prompt.answer(.newWindow)
        #expect(await answer == .newWindow)
        #expect(prompt.session == nil)
    }

    /// A second question retires an unanswered first one as a cancel, so a
    /// move can never be left waiting on a dialog that is no longer up.
    @Test func aNewQuestionCancelsTheUnansweredOne() async {
        let prompt = MoveLandingPrompt()
        async let first = prompt.ask("a")
        await settle { prompt.session == "a" }
        async let second = prompt.ask("b")
        #expect(await first == nil)
        await settle { prompt.session == "b" }
        #expect(prompt.session == "b")
        prompt.answer(.joinCurrentWindow)
        #expect(await second == .joinCurrentWindow)
    }

    /// Let the `async let` child reach its `ask` (it hops onto the main actor).
    private func settle(_ done: () -> Bool) async {
        for _ in 0..<1000 where !done() { await Task.yield() }
    }

    @Test func copyNamesTheTarget() {
        #expect(SessionPromptCopy.landing("work").title == "Move to “work”")
        #expect(SessionPromptCopy.closeWindow("1:zsh").title == "Close “1:zsh”?")
        #expect(SessionPromptCopy.killSession(nil).title == "Kill this session?")
    }
}
