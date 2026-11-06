import Foundation
import Testing
@testable import BentoUISharedKit

@Suite("Default session name")
struct DefaultSessionNameTests {

    private func defaults(_ value: String?) -> UserDefaults {
        let d = UserDefaults(suiteName: "DefaultSessionNameTests-\(UUID().uuidString)")!
        if let value { d.set(value, forKey: TmuxSessionNaming.defaultNameKey) }
        return d
    }

    @Test func unsetIsBento() {
        #expect(TmuxSessionNaming.configuredDefault(defaults(nil)) == "bento")
    }

    @Test func blankIsBento() {
        #expect(TmuxSessionNaming.configuredDefault(defaults("   ")) == "bento")
    }

    @Test func configuredNameIsMadeAddressable() {
        #expect(TmuxSessionNaming.configuredDefault(defaults("work")) == "work")
        #expect(TmuxSessionNaming.configuredDefault(defaults("my.box")) == "my-box")
    }
}

@Suite("Numbered extra sessions")
struct NumberedSessionNameTests {

    @Test func firstExtraIsTwo() {
        #expect(TmuxSessionNaming.numbered("bento", existing: []) == "bento-2")
        #expect(TmuxSessionNaming.numbered("bento", existing: ["bento"]) == "bento-2")
    }

    @Test func takesTheLowestGap() {
        #expect(TmuxSessionNaming.numbered("bento", existing: ["bento", "bento-2", "bento-4"]) == "bento-3")
        #expect(TmuxSessionNaming.numbered("work", existing: ["work-2", "work-3"]) == "work-4")
    }

    @Test func otherNamesDoNotCount() {
        #expect(TmuxSessionNaming.numbered("bento", existing: ["work-2", "bento-x"]) == "bento-2")
    }
}

@Suite("Reopen target")
struct ReopenTargetTests {

    @Test func lastSessionStillAliveWins() {
        #expect(TmuxSessionNaming.reopenTarget(last: "api", live: ["bento", "api"],
                                               defaultName: "bento") == "api")
    }

    @Test func goneLastSessionFallsBackToDefault() {
        #expect(TmuxSessionNaming.reopenTarget(last: "api", live: ["bento"],
                                               defaultName: "bento") == "bento")
    }

    /// No server at all is a real answer: nothing to go back to.
    @Test func emptyServerFallsBackToDefault() {
        #expect(TmuxSessionNaming.reopenTarget(last: "api", live: [],
                                               defaultName: "work") == "work")
    }

    /// Not having heard from tmux yet is NOT "it's gone".
    @Test func unknownServerTrustsTheRecord() {
        #expect(TmuxSessionNaming.reopenTarget(last: "api", live: nil,
                                               defaultName: "bento") == "api")
    }

    @Test func nothingRememberedIsTheDefault() {
        #expect(TmuxSessionNaming.reopenTarget(last: nil, live: ["api"],
                                               defaultName: "bento") == "bento")
        #expect(TmuxSessionNaming.reopenTarget(last: "", live: nil,
                                               defaultName: "bento") == "bento")
    }
}
