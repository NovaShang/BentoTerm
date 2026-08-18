import Foundation
import Testing
@testable import BentoSessionKit

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

    /// The "Duplicate Current" bug, seen from the store's side: a version
    /// number is what tmux reports as the *command* of a pane running a
    /// versioned install, and it is not a command at all.
    @Test func aVersionNumberIsNotAReplayableCommand() {
        #expect(!RecentLaunchPolicy.isReplayableCommand("2.1.234"))
        #expect(!RecentLaunchPolicy.isReplayableCommand("2.1.228"))
        #expect(!RecentLaunchPolicy.isReplayableCommand(" 0.3.1 "))
        // Real launches must survive: the rule rejects what cannot be a program
        // name, not what looks unusual.
        #expect(RecentLaunchPolicy.isReplayableCommand("claude"))
        #expect(RecentLaunchPolicy.isReplayableCommand("claude --resume"))
        #expect(RecentLaunchPolicy.isReplayableCommand("python3"))
        #expect(RecentLaunchPolicy.isReplayableCommand("./run.sh"))
        #expect(RecentLaunchPolicy.isReplayableCommand(""))  // plain shell
    }

    @Test func loadingRepairsRowsPoisonedByAnOlderBuild() {
        // Verbatim shapes from a shipped 0.3.1 store.
        let stored = [
            LaunchRecord(dir: home + "/Work", command: "2.1.234"),
            LaunchRecord(dir: home, command: "2.1.228"),
            LaunchRecord(dir: home + "/code", command: "claude"),
            LaunchRecord(dir: home + "/Work", command: ""),
        ]
        let clean = PaletteRecents.repaired(stored)

        // The version rows keep their directory and lose the bogus command; the
        // one at $HOME becomes the plain default and drops out entirely; the
        // real launch is untouched; and the repair does not duplicate the row it
        // now collides with.
        #expect(clean == [LaunchRecord(dir: home + "/Work", command: ""),
                          LaunchRecord(dir: home + "/code", command: "claude")])
        #expect(!clean.contains { $0.command.contains("2.1.") })
    }

    @Test func directoriesNormalizeSoOneFolderIsOneRow() {
        let a = RecentLaunchPolicy.record(dir: "~/code/foo/", command: "vim")
        let b = RecentLaunchPolicy.record(dir: " " + NSHomeDirectory() + "/code/foo ", command: " vim ")
        #expect(a == b)
        #expect(a?.dir == NSHomeDirectory() + "/code/foo")
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
