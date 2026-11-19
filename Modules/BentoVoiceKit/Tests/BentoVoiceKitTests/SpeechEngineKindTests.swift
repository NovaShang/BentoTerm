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

    // MARK: Apple (new model)

    func testNewAppleModelIsSelectableOnASupportedOS() {
        let defaults = freshDefaults()
        defaults.set("speechanalyzer", forKey: "speech_engine")
        XCTAssertEqual(SpeechEngineKind.current(defaults: defaults, analyzerSupported: true), .speechAnalyzer)
    }

    func testNewAppleModelBelowIOS26RunsAsTheOldAppleEngine() {
        let defaults = freshDefaults()
        defaults.set("speechanalyzer", forKey: "speech_engine")
        XCTAssertEqual(SpeechEngineKind.current(defaults: defaults, analyzerSupported: false), .apple)
    }

    func testOldAppleEngineIsUnaffectedByAnalyzerSupport() {
        let defaults = freshDefaults()
        defaults.set("apple", forKey: "speech_engine")
        XCTAssertEqual(SpeechEngineKind.current(defaults: defaults, analyzerSupported: true), .apple)
        XCTAssertEqual(SpeechEngineKind.current(defaults: defaults, analyzerSupported: false), .apple)
    }

    func testEngineTraits() {
        XCTAssertEqual(SpeechEngineKind.speechAnalyzer.rawValue, "speechanalyzer")
        XCTAssertTrue(SpeechEngineKind.speechAnalyzer.isOnDevice)
        XCTAssertNil(SpeechEngineKind.speechAnalyzer.keyDefaultsKey)
        XCTAssertNil(SpeechEngineKind.speechAnalyzer.onDeviceModel, "Apple's assets aren't our model download")
        XCTAssertEqual(SpeechEngineKind.allCases.filter(\.isApple), [.apple, .speechAnalyzer])
    }

    func testUnsetOrUnknownIsApple() {
        let defaults = freshDefaults()
        XCTAssertEqual(SpeechEngineKind.current(defaults: defaults), .apple)
        defaults.set("whisper", forKey: "speech_engine")
        XCTAssertEqual(SpeechEngineKind.current(defaults: defaults), .apple)
    }
}
