import XCTest
import CoreGraphics
@testable import BentoTerminalCore

/// Deterministic tests for the shared voice logic (the compass that decides what
/// happens to a transcript, the language mapping, and that the engine + Mac
/// objects construct). The live ASR loop itself needs a real mic and is verified
/// by hand.
final class VoiceTests: XCTestCase {

    func testCompassDeadZoneAndAxes() {
        XCTAssertEqual(voiceDirection(forTranslation: .init(width: 0, height: 0)), .none)
        XCTAssertEqual(voiceDirection(forTranslation: .init(width: 30, height: 30)), .none,
                       "within the 40pt dead zone")
        XCTAssertEqual(voiceDirection(forTranslation: .init(width: 0, height: -60)), .up,
                       "y-up (negative) drag = send")
        XCTAssertEqual(voiceDirection(forTranslation: .init(width: 0, height: 60)), .down,
                       "y-down drag = cancel")
        XCTAssertEqual(voiceDirection(forTranslation: .init(width: 60, height: 0)), .right)
        XCTAssertEqual(voiceDirection(forTranslation: .init(width: -60, height: 0)), .left)
        // Axis dominance: the larger component wins.
        XCTAssertEqual(voiceDirection(forTranslation: .init(width: 60, height: 20)), .right)
        XCTAssertEqual(voiceDirection(forTranslation: .init(width: 20, height: -60)), .up)
    }

    func testCompassThreshold() {
        XCTAssertEqual(voiceDirection(forTranslation: .init(width: 50, height: 0), threshold: 100), .none)
        XCTAssertEqual(voiceDirection(forTranslation: .init(width: 50, height: 0), threshold: 30), .right)
    }

    func testLanguageHint() {
        XCTAssertEqual(openAILanguageHint(for: "zh-Hans"), "zh")
        XCTAssertEqual(openAILanguageHint(for: "en-US"), "en")
        XCTAssertEqual(openAILanguageHint(for: "ja-JP"), "ja")
        XCTAssertEqual(openAILanguageHint(for: "auto"), "")
    }

    func testResultRoundTrips() {
        let r = VoiceInputResult(text: "ls -la", direction: .right)
        XCTAssertEqual(r.text, "ls -la")
        XCTAssertEqual(r.direction, .right)
    }

    @MainActor
    func testVoiceObjectsConstruct() {
        _ = VoiceSession()
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        let controller = MacVoiceController()
        XCTAssertFalse(controller.isRecording)
        XCTAssertEqual(controller.activeDirection, .none)
        let overlay = MacVoiceOverlay(frame: .init(x: 0, y: 0, width: 300, height: 320))
        overlay.transcript = "hello"
        overlay.direction = .up
        overlay.layout()   // exercises the compass layout math
        #endif
    }

    // MARK: - Speech gate (silence must never reach the ASR model)

    /// PCM chunk of constant-amplitude Int16 samples.
    private func chunk(amplitude: Int16, samples: Int = 1600) -> Data {
        var data = Data(capacity: samples * 2)
        for _ in 0..<samples {
            withUnsafeBytes(of: amplitude.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    func testRMSOfSilenceAndTone() {
        XCTAssertEqual(SpeechGate.rms16(Data()), 0)
        XCTAssertEqual(SpeechGate.rms16(chunk(amplitude: 0)), 0)
        // Constant amplitude → RMS == |amplitude|.
        XCTAssertEqual(SpeechGate.rms16(chunk(amplitude: 1000)), 1000, accuracy: 0.5)
        XCTAssertEqual(SpeechGate.rms16(chunk(amplitude: -1000)), 1000, accuracy: 0.5)
    }

    func testGateStaysClosedOnSilence() {
        var gate = SpeechGate(sampleRate: 16000)
        for _ in 0..<50 {
            XCTAssertTrue(gate.admit(chunk(amplitude: 40)).isEmpty, "room tone must not pass")
        }
        XCTAssertFalse(gate.isOpen)
        XCTAssertEqual(Int(gate.maxRMS), 40)
    }

    func testGateOpensOnSpeechAndFlushesPreRoll() {
        var gate = SpeechGate(sampleRate: 16000)
        let quiet1 = chunk(amplitude: 30)
        let quiet2 = chunk(amplitude: 50)
        XCTAssertTrue(gate.admit(quiet1).isEmpty)
        XCTAssertTrue(gate.admit(quiet2).isEmpty)
        let loud = chunk(amplitude: 2000)
        let out = gate.admit(loud)
        XCTAssertTrue(gate.isOpen)
        // Pre-roll (both quiet chunks) then the triggering chunk, in order.
        XCTAssertEqual(out, [quiet1, quiet2, loud])
        // Once open, chunks flow straight through — including later pauses.
        XCTAssertEqual(gate.admit(quiet1), [quiet1])
    }

    func testPreRollIsBounded() {
        var gate = SpeechGate(sampleRate: 16000)   // cap = 0.6s ≈ 19200 bytes
        // 20 quiet chunks × 3200 bytes = 64000 buffered bytes → must be trimmed.
        for _ in 0..<20 { _ = gate.admit(chunk(amplitude: 20)) }
        let out = gate.admit(chunk(amplitude: 2000))
        let preRollBytes = out.dropLast().reduce(0) { $0 + $1.count }
        XCTAssertLessThanOrEqual(preRollBytes, Int(16000 * 0.6) * 2)
        XCTAssertGreaterThan(preRollBytes, 0, "some pre-roll must survive")
    }

    func testGateThresholdBoundary() {
        var gate = SpeechGate(threshold: 180, sampleRate: 16000)
        XCTAssertTrue(gate.admit(chunk(amplitude: 179)).isEmpty)
        XCTAssertFalse(gate.isOpen)
        XCTAssertFalse(gate.admit(chunk(amplitude: 181)).isEmpty)
        XCTAssertTrue(gate.isOpen)
    }
}
