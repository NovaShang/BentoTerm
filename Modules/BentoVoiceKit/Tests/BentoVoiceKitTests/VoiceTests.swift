import XCTest
import CoreGraphics
@testable import BentoVoiceKit

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
        // The platform controllers (MacVoiceController / VoiceInputController)
        // live in the app targets — not in this package — so only the shared
        // engine is constructible here. The shared controller state machine is
        // tested in bento-terminal-core (VoiceControllerTests).
        _ = VoiceSession()
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

    /// The gate latches open, so "how much did it forward" says nothing about
    /// how much was spoken — only loud audio counts toward `voicedDuration`,
    /// which is what tells a blip from an utterance.
    func testVoicedDurationCountsOnlySpeechLevelAudio() {
        var gate = SpeechGate(sampleRate: 16000)
        XCTAssertEqual(gate.voicedDuration, 0)
        // One 1600-sample (0.1s) loud chunk opens the gate and counts.
        _ = gate.admit(chunk(amplitude: 2000))
        XCTAssertEqual(gate.voicedDuration, 0.1, accuracy: 0.001)
        // Silence after the latch flows through but must NOT count as speech.
        for _ in 0..<10 { _ = gate.admit(chunk(amplitude: 20)) }
        XCTAssertEqual(gate.voicedDuration, 0.1, accuracy: 0.001,
                       "a hold that opened on a click and then said nothing is still a blip")
        for _ in 0..<3 { _ = gate.admit(chunk(amplitude: 2000)) }
        XCTAssertEqual(gate.voicedDuration, 0.4, accuracy: 0.001)
    }

    // MARK: - Transcript sanity (Qwen echoing the biasing corpus back)

    /// The reported bug: a very short / empty utterance came back as the on-screen
    /// context we had sent as the biasing corpus, and got typed into the shell.
    func testCorpusEchoOnShortClipIsRejected() {
        let corpus = """
        $ npm run build
        error TS2345: Argument of type 'string' is not assignable to parameter of type 'number'
        $ git status
        """
        // 0.9s of audio cannot have produced a whole line of the screen.
        XCTAssertTrue(isImplausibleTranscript(
            "error TS2345: Argument of type 'string' is not assignable",
            clipSeconds: 0.9, corpus: corpus))
        // Reflowed / re-punctuated echoes are the same echo.
        XCTAssertTrue(isImplausibleTranscript(
            "error TS2345 argument of type string is not assignable",
            clipSeconds: 0.9, corpus: corpus))
    }

    func testRealSpeechSurvivesTheGuards() {
        let corpus = "$ npm run build\n$ git status\n"
        // Ordinary dictation, nothing like the corpus.
        XCTAssertFalse(isImplausibleTranscript("帮我把这个提交一下", clipSeconds: 2.0, corpus: corpus))
        // A short command that IS on screen still goes through — under the
        // verbatim-length floor, which is exactly why that floor exists.
        XCTAssertFalse(isImplausibleTranscript("npm run build", clipSeconds: 1.2, corpus: corpus))
        // A long hold that genuinely contains a lot of speech is not capped.
        XCTAssertFalse(isImplausibleTranscript(String(repeating: "话", count: 100),
                                               clipSeconds: 20, corpus: corpus))
        // No corpus (OpenAI/Apple engines) → only the rate test applies.
        XCTAssertFalse(isImplausibleTranscript("git commit", clipSeconds: 1.0, corpus: ""))
        // No audio duration at all (Apple records internally) → no judgement.
        XCTAssertFalse(isImplausibleTranscript("anything at all here", clipSeconds: 0, corpus: corpus))
    }

    // MARK: - Compass placement near the window edges

    /// A 1200x800 window, the anchor well away from every edge: the bubble keeps
    /// its default spot above the compass and does not slide.
    func testPlacementLeavesTheBubbleAloneInTheMiddle() {
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let p = VoiceCompassView.Placement.resolve(anchor: CGPoint(x: 600, y: 400), in: bounds)
        XCTAssertFalse(p.bubbleBelow)
        XCTAssertEqual(p.bubbleShift, 0)
    }

    /// Near the top there is no room for the bubble above the anchor — it flips
    /// below rather than dragging the whole compass down away from the cursor.
    func testBubbleFlipsBelowNearTheTop() {
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        XCTAssertTrue(VoiceCompassView.Placement.resolve(
            anchor: CGPoint(x: 600, y: 140), in: bounds).bubbleBelow)
        // Just past the bubble's reach it stays above.
        XCTAssertFalse(VoiceCompassView.Placement.resolve(
            anchor: CGPoint(x: 600, y: 300), in: bounds).bubbleBelow)
    }

    /// Near a side the bubble slides inward by exactly the overhang; the compass
    /// itself (and so the anchor) does not move.
    func testBubbleSlidesInFromTheSides() {
        typealias M = VoiceCompassView.Metrics
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let left = VoiceCompassView.Placement.resolve(anchor: CGPoint(x: 40, y: 400), in: bounds)
        XCTAssertEqual(left.bubbleShift, M.bubbleHalfWidth + 8 - 40, accuracy: 0.01,
                       "shifted right by the overhang")
        let right = VoiceCompassView.Placement.resolve(anchor: CGPoint(x: 1180, y: 400), in: bounds)
        XCTAssertEqual(right.bubbleShift, 1200 - 8 - M.bubbleHalfWidth - 1180, accuracy: 0.01,
                       "shifted left by the overhang")
        XCTAssertLessThan(right.bubbleShift, 0)
    }

    /// A window narrower than the bubble: the range inverts, and the shift must
    /// collapse to zero instead of flinging the bubble somewhere arbitrary.
    func testPlacementSurvivesAWindowNarrowerThanTheBubble() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 400)
        let p = VoiceCompassView.Placement.resolve(anchor: CGPoint(x: 100, y: 200), in: bounds)
        XCTAssertEqual(p.bubbleShift, 0)
    }

    func testPhysicallyImpossibleTextIsRejectedEvenWithoutACorpus() {
        // 200 characters out of a third of a second is not speech, whatever it is.
        XCTAssertTrue(isImplausibleTranscript(String(repeating: "字", count: 200),
                                              clipSeconds: 0.35, corpus: ""))
    }
}
