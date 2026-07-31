import Foundation
import Testing
@testable import BentoTerminalCore

// MARK: - The noise rule

@Suite struct RecentLaunchPolicyTests {
    private let home = NSHomeDirectory()

    @Test func plainShellAtHomeIsNoise() {
        // The default "new window" — carries no information the launcher
        // doesn't already offer, and would otherwise be every other row.
        #expect(RecentLaunchPolicy.record(dir: home, command: nil) == nil)
        #expect(RecentLaunchPolicy.record(dir: home, command: "") == nil)
        #expect(RecentLaunchPolicy.record(dir: home, command: "   ") == nil)
        #expect(RecentLaunchPolicy.record(dir: "~", command: nil) == nil)
    }

    @Test func aRealCommandIsWorthKeepingEvenAtHome() {
        let r = RecentLaunchPolicy.record(dir: home, command: "claude")
        #expect(r?.dir == home)
        #expect(r?.command == "claude")
        #expect(r?.host == nil)
    }

    @Test func aNonHomeDirectoryIsWorthKeepingEvenAsAPlainShell() {
        let r = RecentLaunchPolicy.record(dir: home + "/code/bento-term", command: nil)
        #expect(r?.dir == home + "/code/bento-term")
        #expect(r?.command == "")
    }

    @Test func noDirectoryMeansNothingToReopen() {
        #expect(RecentLaunchPolicy.record(dir: nil, command: "claude") == nil)
        #expect(RecentLaunchPolicy.record(dir: "  ", command: "claude") == nil)
    }

    @Test func directoriesNormalizeSoOneFolderIsOneRow() {
        let a = RecentLaunchPolicy.record(dir: "~/code/foo/", command: "vim")
        let b = RecentLaunchPolicy.record(dir: " " + NSHomeDirectory() + "/code/foo ", command: " vim ")
        #expect(a == b)
        #expect(a?.dir == NSHomeDirectory() + "/code/foo")
    }
}

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

// MARK: - Store shape

@Suite struct LaunchRecordCodableTests {
    @Test func oldStoredJSONWithoutHostStillDecodes() throws {
        // Exactly what shipped builds wrote before `host` existed. Users have
        // this on disk; it must not silently reset their recents to empty.
        let old = Data("""
        [{"dir":"/Users/x/code/bento","command":"claude"},{"dir":"/tmp","command":""}]
        """.utf8)
        let decoded = try JSONDecoder().decode([LaunchRecord].self, from: old)
        #expect(decoded.count == 2)
        #expect(decoded[0].dir == "/Users/x/code/bento")
        #expect(decoded[0].command == "claude")
        #expect(decoded[0].host == nil)
        #expect(decoded[1].host == nil)
    }

    @Test func localEntriesOmitHostSoOlderBuildsCanStillReadThem() throws {
        let data = try JSONEncoder().encode([LaunchRecord(dir: "/tmp", command: "vim")])
        #expect(!String(decoding: data, as: UTF8.self).contains("host"))
    }

    @Test func hostRoundTripsWhenItIsSet() throws {
        let data = try JSONEncoder().encode([LaunchRecord(dir: "/tmp", command: "vim", host: "box")])
        #expect(try JSONDecoder().decode([LaunchRecord].self, from: data)[0].host == "box")
    }
}

// MARK: - The provider

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
@Suite @MainActor struct OpenTargetProviderTests {
    private func provider() -> OpenTargetProvider {
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
