import XCTest
@testable import BentoVoiceKit

/// A cloud engine needs the user's own key: there is no shared server behind
/// it, so one selected without its key has to run as Apple's engine.
final class SpeechEngineKindTests: XCTestCase {
    private func freshDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "bento.enginekind.\(name)"
        UserDefaults().removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }

    func testCloudEngineWithoutKeyRunsAsApple() {
        let defaults = freshDefaults()
        defaults.set("qwen", forKey: "speech_engine")
        XCTAssertEqual(SpeechEngineKind.current(defaults: defaults), .apple)
        defaults.set("   ", forKey: "dashscope_api_key")
        XCTAssertEqual(SpeechEngineKind.current(defaults: defaults), .apple, "whitespace is not a key")
    }

    func testCloudEngineWithItsOwnKeyIsUsed() {
        let defaults = freshDefaults()
        defaults.set("qwen", forKey: "speech_engine")
        defaults.set("sk-test", forKey: "dashscope_api_key")
        XCTAssertEqual(SpeechEngineKind.current(defaults: defaults), .qwen)
    }

    func testAnotherEnginesKeyDoesNotCount() {
        let defaults = freshDefaults()
        defaults.set("openai", forKey: "speech_engine")
        defaults.set("sk-test", forKey: "dashscope_api_key")
        XCTAssertEqual(SpeechEngineKind.current(defaults: defaults), .apple)
    }

    func testUnsetOrUnknownIsApple() {
        let defaults = freshDefaults()
        XCTAssertEqual(SpeechEngineKind.current(defaults: defaults), .apple)
        defaults.set("whisper", forKey: "speech_engine")
        XCTAssertEqual(SpeechEngineKind.current(defaults: defaults), .apple)
    }
}
