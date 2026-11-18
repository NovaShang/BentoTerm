import XCTest
@testable import BentoVoiceKit

final class ContextVocabularyTests: XCTestCase {

    // MARK: Splitting

    func testPathGivesProjectComponentsDeepestFirst() {
        XCTAssertEqual(ContextVocabulary.pathPhrases("/Users/nova/code/bento-term/Modules"),
                       ["Modules", "bento-term", "bento term", "code"])
    }

    func testPathDropsSystemPrefixesHomeOwnerAndDotDirs() {
        XCTAssertEqual(ContextVocabulary.pathPhrases("/home/deploy/.config/my_app"),
                       ["my_app", "my app"])
        XCTAssertEqual(ContextVocabulary.pathPhrases("~/src/api"), ["api", "src"])
        XCTAssertEqual(ContextVocabulary.pathPhrases("/"), [])
    }

    func testCommandIsTheProgramNameAndIdleShellsAreDropped() {
        XCTAssertEqual(ContextVocabulary.commandPhrases("node"), ["node"])
        XCTAssertEqual(ContextVocabulary.commandPhrases("/usr/local/bin/claude"), ["claude"])
        XCTAssertEqual(ContextVocabulary.commandPhrases("npm run dev --port 3000"),
                       ["npm run dev", "npm"], "the spoken part, up to the first flag")
        XCTAssertEqual(ContextVocabulary.commandPhrases("docker-compose"), ["docker-compose", "docker compose"])
        XCTAssertEqual(ContextVocabulary.commandPhrases("zsh"), [])
        XCTAssertEqual(ContextVocabulary.commandPhrases("-bash"), [])
    }

    func testTitleKeepsBranchesAndNamesDropsGlue() {
        let phrases = ContextVocabulary.titlePhrases("✳ Fix the voice-bug on feat/speechanalyzer")
        XCTAssertEqual(phrases, ["Fix", "voice-bug", "voice bug", "feat/speechanalyzer", "feat", "speechanalyzer"])
    }

    func testTitleSplitsUserAtHostAndItsPath() {
        XCTAssertEqual(ContextVocabulary.titlePhrases("nova@mbp: ~/code/bento-web"),
                       ["nova", "mbp", "bento-web", "bento web", "code"])
    }

    func testHashesVersionsAndNumbersAreNotWords() {
        XCTAssertFalse(ContextVocabulary.isWordLike("3f9a2c1e"))
        XCTAssertFalse(ContextVocabulary.isWordLike("1234"))
        XCTAssertFalse(ContextVocabulary.isWordLike("x"))
        XCTAssertTrue(ContextVocabulary.isWordLike("v2"))
        XCTAssertTrue(ContextVocabulary.isWordLike("部署"))
        XCTAssertTrue(ContextVocabulary.isWordLike("cafe"), "hex letters without digits are a word")
    }

    func testDefaultNumericSessionAndWindowNamesAreDropped() {
        XCTAssertEqual(ContextVocabulary.namePhrases("0"), [])
        XCTAssertEqual(ContextVocabulary.namePhrases(" api-server "), ["api-server", "api server"])
    }

    func testHostsKeepAliasesAndFirstLabelSkipIPs() {
        XCTAssertEqual(ContextVocabulary.hostPhrases("build.example.com"), ["build.example.com", "build"])
        XCTAssertEqual(ContextVocabulary.hostPhrases("prod-db"), ["prod-db", "prod db"])
        XCTAssertEqual(ContextVocabulary.hostPhrases("10.0.0.12"), [])
    }

    // MARK: Building

    func testOrderIsPaneThenSessionThenBuiltInsThenAliases() {
        let s = VoiceContextSnapshot(command: "claude", cwd: "/Users/nova/code/bento-term",
                                     paneTitle: "feat/voice", sessionName: "work",
                                     windowNames: ["api", "web"], hostNames: ["mbp"])
        let list = ContextVocabulary.build(s, hostAliases: ["gpu-box"])
        XCTAssertEqual(Array(list.prefix(11)),
                       ["claude", "bento-term", "bento term", "code", "feat/voice", "feat", "voice",
                        "api", "web", "work", "mbp"])
        let builtInStart = list.firstIndex(of: "tmux")!
        XCTAssertEqual(Array(list[builtInStart..<builtInStart + ContextVocabulary.builtIn.count]),
                       ContextVocabulary.builtIn)
        XCTAssertEqual(Array(list.suffix(2)), ["gpu-box", "gpu box"])
    }

    func testDedupeIsCaseInsensitiveAndKeepsTheFirstSpelling() {
        let s = VoiceContextSnapshot(command: "Git", windowNames: ["tmux", "TMUX", "git"])
        let list = ContextVocabulary.build(s)
        XCTAssertEqual(list.filter { $0.lowercased() == "git" }, ["Git"])
        XCTAssertEqual(list.filter { $0.lowercased() == "tmux" }, ["tmux"])
        XCTAssertEqual(Set(list.map { $0.lowercased() }).count, list.count)
    }

    func testCapCutsTheTailNotThePane() {
        let aliases = (1...500).map { "host\($0)" }
        let s = VoiceContextSnapshot(command: "codex", cwd: "/srv/app")
        let list = ContextVocabulary.build(s, hostAliases: aliases)
        XCTAssertEqual(list.count, ContextVocabulary.defaultCap)
        XCTAssertEqual(Array(list.prefix(3)), ["codex", "app", "srv"])
        XCTAssertTrue(list.contains("Bento"), "built-ins come before the long alias list")
        XCTAssertFalse(list.contains("host500"))
        XCTAssertEqual(ContextVocabulary.build(s, cap: 2), ["codex", "app"])
    }

    func testEmptySnapshotIsJustTheBuiltIns() {
        XCTAssertEqual(ContextVocabulary.build(VoiceContextSnapshot()), ContextVocabulary.builtIn)
    }

    func testGatherRunsTheDiskLoaderOffTheMainThread() async {
        let s = VoiceContextSnapshot(loadHostAliases: {
            XCTAssertFalse(Thread.isMainThread)
            return ["staging"]
        })
        let list = await ContextVocabulary.gather(s)
        XCTAssertEqual(list.last, "staging")
        let none = await ContextVocabulary.gather(nil)
        XCTAssertEqual(none, ContextVocabulary.builtIn)
    }
}
