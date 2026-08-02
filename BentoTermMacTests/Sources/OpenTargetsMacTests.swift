import Foundation
import Testing
import BentoTerm
import BentoTerminalCore

// MARK: - Session naming

@Suite struct TmuxSessionNamingTests {
    @Test func dotsAndColonsAreStripped() {
        // tmux reads `session:window.pane`, so a name holding either addresses
        // something else entirely.
        #expect(TmuxSessionNaming.sessionName(forDirectory: "/Users/x/code/foo.bar",
                                              existing: []) == "foo-bar")
        #expect(TmuxSessionNaming.sanitize("a:b.c") == "a-b-c")
        #expect(TmuxSessionNaming.sanitize("my project") == "my-project")
    }

    @Test func sanitizingNeverYieldsAnEmptyOrEdgeDashedName() {
        #expect(TmuxSessionNaming.sanitize("...") == "session")
        #expect(TmuxSessionNaming.sanitize("") == "session")
        #expect(TmuxSessionNaming.sanitize(".config") == "config")
        #expect(TmuxSessionNaming.sanitize("a...b") == "a-b")
    }

    @Test func collisionsGetASuffix() {
        #expect(TmuxSessionNaming.sessionName(forDirectory: "/a/bento",
                                              existing: ["bento"]) == "bento-2")
        #expect(TmuxSessionNaming.sessionName(forDirectory: "/a/bento",
                                              existing: ["bento", "bento-2"]) == "bento-3")
        // Dedupe happens AFTER sanitizing — otherwise `foo.bar` would never
        // collide with the `foo-bar` it actually becomes.
        #expect(TmuxSessionNaming.sessionName(forDirectory: "/a/foo.bar",
                                              existing: ["foo-bar"]) == "foo-bar-2")
    }
}

// MARK: - The provider

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
@Suite @MainActor struct OpenTargetProviderTests {
    @MainActor private func provider() -> OpenTargetProvider {
        OpenTargetProvider(
            sessions: { ["bento", "session-2"] },
            sshHosts: { ["box", "gpu"] },
            launches: { [LaunchRecord(dir: "/Users/x/code/bento", command: "claude"),
                         LaunchRecord(dir: "/Users/x/notes", command: "")] })
    }

    @Test func composesAllThreeKinds() {
        let all = provider().allTargets()
        #expect(all.count == 6)
        // Order is what a flat consumer (Dock menu, Shortcuts) should show:
        // what's running, what you ran recently, where you can reach.
        #expect(all[0].kind == .tmuxSession(name: "bento"))
        #expect(all[2].kind == .recentLaunch(LaunchRecord(dir: "/Users/x/code/bento", command: "claude")))
        #expect(all[4].kind == .sshHost(alias: "box"))
    }

    @Test func identitiesAreStableAndDistinctAcrossKinds() {
        let ids = provider().allTargets().map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.contains("session:bento"))
        #expect(ids.contains("ssh:gpu"))
        #expect(ids.contains("launch:|/Users/x/code/bento|claude"))
        // Same inputs → same ids, so a menu/entity can key off them.
        #expect(provider().allTargets().map(\.id) == ids)
    }

    @Test func recentRowsNameTheProgramAndAbbreviateTheDirectory() {
        let recents = OpenTargetProvider(
            sessions: { [] }, sshHosts: { [] },
            launches: { [LaunchRecord(dir: NSHomeDirectory() + "/code/x", command: "claude"),
                         LaunchRecord(dir: "/tmp", command: "")] }
        ).recentTargets()
        #expect(recents[0].title == "claude  ·  ~/code/x")
        #expect(recents[1].title == "shell  ·  /tmp")
    }

    @Test func targetsCarryNoPaletteOrSwiftUITypes() {
        // The contract that lets the Dock menu and App Intents consume this:
        // a target is inert data. Equality across two independently built
        // providers only holds because nothing in it is a closure.
        #expect(provider().allTargets() == provider().allTargets())
    }
}
#endif
