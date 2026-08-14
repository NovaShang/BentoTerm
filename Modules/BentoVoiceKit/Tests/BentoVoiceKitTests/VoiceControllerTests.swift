import Foundation
import Testing
@testable import BentoVoiceKit
import BentoFoundationKit   // TipCenter

/// Deterministic tests for the shared `VoiceController` state machine — the
/// press lifecycle, compass-direction routing, preview flow, error path and
/// send pacing. The live ASR loop needs a real mic and is verified by hand.
@Suite @MainActor
struct VoiceControllerTests {

    /// Fake session: records calls, never touches audio. `errorOnStart` makes
    /// `start` fail synchronously like a denied permission.
    final class FakeVoiceSession: VoiceSessionProtocol {
        var currentTranscript = ""
        var contextProvider: (() -> String?)?
        var prewarmCount = 0
        var startCount = 0
        var cancelCount = 0
        var finishLanguage: String?
        var finishResult = ""
        var refineResult = false
        var errorOnStart: String?
        /// When true, `finish` suspends until `allowFinish()` — the tests that
        /// need to observe the state DURING the finish wait (the release target
        /// staying lit) hold the final resolution open with it.
        var finishWaits = false
        private var finishContinuation: CheckedContinuation<Void, Never>?

        func prewarm() { prewarmCount += 1 }
        func start(onPartial: @escaping @MainActor (String) -> Void,
                   onError: @escaping @MainActor (String) -> Void) {
            startCount += 1
            if let m = errorOnStart { onError(m) }
        }
        func finish(language: String) async -> String {
            finishLanguage = language
            if finishWaits {
                await withCheckedContinuation { finishContinuation = $0 }
            }
            return finishResult
        }
        func allowFinish() {
            finishWaits = false
            finishContinuation?.resume()
            finishContinuation = nil
        }
        func cancel() { cancelCount += 1 }
        func refineRecordedPCM(screenText: String?,
                               completion: @escaping @MainActor (String?) -> Void) -> Bool {
            // Deliver asynchronously like the real session, so the caller's
            // `previewLoading = ...` assignment lands before the completion.
            if refineResult { Task { @MainActor in completion("refined") } }
            return refineResult
        }
    }

    @MainActor
    private func makeController(session: FakeVoiceSession? = nil)
        -> (controller: VoiceController, session: FakeVoiceSession) {
        // Construct inside the body: default-arg expressions evaluate in the
        // caller's context, and the fake is main-actor-isolated.
        let s = session ?? FakeVoiceSession()
        return (VoiceController(session: s), s)
    }

    /// Poll until a condition holds (the send path runs in a fire-and-forget
    /// Task, so assertions must wait for it).
    private func waitFor(timeoutMs: Int = 1000, _ condition: @MainActor () -> Bool) async {
        for _ in 0..<(timeoutMs / 20) {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Begin / update

    @Test func beginStartsSessionAndPublishesState() {
        let (c, s) = makeController()
        c.begin(originScreen: .init(x: 100, y: 100))
        #expect(s.startCount == 1)
        #expect(c.isRecording)
        #expect(c.showOverlay)
        #expect(c.transcript == "")
        #expect(c.activeDirection == .none)
        #expect(c.fingerOffset == .zero)
    }

    @Test func beginIgnoredWhileRecording() {
        let (c, s) = makeController()
        c.begin(originScreen: .zero)
        c.begin(originScreen: .init(x: 50, y: 50))
        #expect(s.startCount == 1)
    }

    @Test func updateTracksDirectionWithDeadZone() {
        let (c, _) = makeController()
        c.begin(originScreen: .init(x: 100, y: 100))
        c.update(toScreen: .init(x: 130, y: 130))
        #expect(c.activeDirection == .none, "within the 40pt dead zone")
        c.update(toScreen: .init(x: 100, y: 40))
        #expect(c.activeDirection == .up, "negative dy = up")
        c.update(toScreen: .init(x: 160, y: 100))
        #expect(c.activeDirection == .right)
    }

    @Test func updateIgnoredWhenNotRecording() {
        let (c, _) = makeController()
        c.update(toScreen: .init(x: 0, y: 0))
        #expect(c.activeDirection == .none)
        #expect(c.fingerOffset == .zero)
    }

    @Test func prewarmForwardsToSession() {
        let (c, s) = makeController()
        c.prewarm()
        #expect(s.prewarmCount == 1)
    }

    // MARK: - Release routing

    @Test func downCancelsWithoutResult() async {
        let (c, s) = makeController()
        var result: VoiceInputResult?
        c.onResult = { result = $0 }
        c.begin(originScreen: .zero)
        c.update(toScreen: .init(x: 0, y: 80))   // .down
        c.end()
        #expect(s.cancelCount == 1)
        #expect(!c.isRecording)
        #expect(c.isDismissing, "overlay plays its outro before it goes")
        #expect(c.activeDirection == .down, "the cancelled target is the last thing to leave")
        await waitFor { !c.showOverlay }
        #expect(!c.showOverlay)
        #expect(c.activeDirection == .none, "direction resets once the overlay is gone")
        #expect(result == nil)
    }

    @Test func beginDuringOutroKeepsOverlayUp() async {
        let (c, _) = makeController()
        c.begin(originScreen: .zero)
        c.update(toScreen: .init(x: 0, y: 80))   // .down → cancel
        c.end()
        #expect(c.isDismissing)
        // A new press lands while the compass is still folding away.
        c.begin(originScreen: .zero)
        #expect(!c.isDismissing, "the outro is called off, not left running")
        try? await Task.sleep(for: .milliseconds(600))
        #expect(c.showOverlay, "the stale outro must not yank the live recording's overlay")
        #expect(c.isRecording)
        c.end()
    }

    @Test func rightBeginsPreviewSeededWithStreamedTranscript() async {
        let (c, s) = makeController()
        s.currentTranscript = "ls -la"
        c.begin(originScreen: .zero)
        c.update(toScreen: .init(x: 80, y: 0))   // .right
        c.end()
        #expect(s.cancelCount == 1)
        #expect(!c.isRecording)
        await waitFor { !c.showOverlay }         // after the outro
        #expect(!c.showOverlay)
        #expect(c.showPreview)
        #expect(c.previewText == "ls -la")
    }

    @Test func rightPreviewReplacesTextWhenRefineDelivers() async {
        let (c, s) = makeController()
        s.currentTranscript = "streamed"
        s.refineResult = true
        c.begin(originScreen: .zero)
        c.update(toScreen: .init(x: 80, y: 0))
        c.end()
        await waitFor { !c.previewLoading }
        #expect(c.previewText == "refined", "higher-accuracy batch text wins")
        #expect(!c.previewLoading)
    }

    @Test func upSendsAfterFinish() async {
        let (c, s) = makeController()
        s.finishResult = "ls"
        var result: VoiceInputResult?
        c.onResult = { result = $0 }
        c.begin(originScreen: .zero)
        c.update(toScreen: .init(x: 0, y: -80))  // .up
        c.end()
        await waitFor { result != nil }
        #expect(result?.text == "ls")
        #expect(result?.direction == .up)
        #expect(s.finishLanguage != nil, "finish called with a language hint")
        #expect(!c.isRecording)
        await waitFor { !c.showOverlay }         // after the outro
        #expect(!c.showOverlay)
    }

    @Test func releaseDismissesOverlayWithoutWaitingForTheFinal() async {
        let (c, s) = makeController()
        s.finishResult = "ls"
        s.finishWaits = true
        var result: VoiceInputResult?
        c.onResult = { result = $0 }
        c.begin(originScreen: .zero)
        c.update(toScreen: .init(x: 0, y: -80))  // .up
        c.end()
        // Releasing ends the gesture: the compass starts leaving immediately,
        // with the release target still lit as the last thing to go.
        #expect(c.isDismissing)
        #expect(c.activeDirection == .up, "release target is lit through the outro")
        // Park inside `finish` — the final can take a couple of seconds (commit +
        // authoritative result, sometimes a batch fallback). The overlay must NOT
        // wait for it; that lag on mouse-up read as the app hanging.
        await waitFor { s.finishLanguage != nil }
        await waitFor { !c.showOverlay }
        #expect(!c.showOverlay, "compass is gone while the final is still resolving")
        #expect(c.activeDirection == .none, "direction resets once the overlay hides")
        #expect(result == nil, "nothing sent yet — the text has not resolved")
        // The work keeps running and delivers whenever it lands.
        s.allowFinish()
        await waitFor { result != nil }
        #expect(result?.text == "ls")
    }

    @Test func leftSendsWithLlmDirection() async {
        let (c, s) = makeController()
        s.finishResult = "npm start"
        var result: VoiceInputResult?
        c.onResult = { result = $0 }
        c.begin(originScreen: .zero)
        c.update(toScreen: .init(x: -80, y: 0))  // .left
        c.end()
        await waitFor { result != nil }
        #expect(result?.direction == .left)
    }

    @Test func noneSendsPlainText() async {
        let (c, s) = makeController()
        s.finishResult = "echo hi"
        var result: VoiceInputResult?
        c.onResult = { result = $0 }
        c.begin(originScreen: .zero)
        c.end()                                    // no movement → .none
        await waitFor { result != nil }
        #expect(result?.text == "echo hi")
        #expect(result?.direction == VoiceDirection.none)
    }

    @Test func emptyTranscriptSilentlyReturns() async {
        let (c, _) = makeController()
        var fired = false
        c.onResult = { _ in fired = true }
        c.begin(originScreen: .zero)
        c.update(toScreen: .init(x: 0, y: -80))
        c.end()
        await waitFor { !c.isRecording }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!fired, "silent hold / empty result must not fire onResult")
        await waitFor { !c.showOverlay }
        #expect(!c.showOverlay)
    }

    @Test func endIgnoredWhenNotRecording() {
        let (c, s) = makeController()
        c.end()
        #expect(s.cancelCount == 0)
    }

    // MARK: - Error path

    @Test func errorShowsMessageThenDismissesOverlay() async {
        let (c, s) = makeController()
        s.errorOnStart = "boom"
        c.begin(originScreen: .zero)
        #expect(s.cancelCount == 1, "session torn down so the mic engine can't leak")
        #expect(c.transcript == "boom")
        #expect(!c.isRecording)
        #expect(c.showOverlay, "error text stays visible")
        await waitFor(timeoutMs: 3000) { !c.showOverlay }
    }

    @Test func newBeginCancelsPendingErrorDismissal() async {
        let (c, s) = makeController()
        s.errorOnStart = "boom"
        c.begin(originScreen: .zero)
        // A new recording starts inside the 1.2s error window...
        s.errorOnStart = nil
        c.begin(originScreen: .zero)
        #expect(c.isRecording)
        #expect(c.showOverlay)
        // ...and the stale dismissal must NOT yank its overlay.
        try? await Task.sleep(for: .milliseconds(1500))
        #expect(c.showOverlay, "stale error dismissal was cancelled")
        c.end()
    }

    // MARK: - Preview send / cancel

    @Test func sendPreviewSendsUpAndTracksCount() {
        let (c, s) = makeController()
        let tipCenter = TipCenter(defaults: UserDefaults(suiteName: "voice-tests-\(UUID().uuidString)")!)
        c.tipCenter = tipCenter
        s.currentTranscript = "  ls -la  "
        var result: VoiceInputResult?
        c.onResult = { result = $0 }
        c.begin(originScreen: .zero)
        c.update(toScreen: .init(x: 80, y: 0))
        c.end()
        c.sendPreview()
        #expect(result?.text == "ls -la", "whitespace trimmed")
        #expect(result?.direction == .up)
        #expect(!c.showPreview)
        #expect(c.voiceSendTotal == 1)
        #expect(tipCenter.recordedVoiceSendCount == 1)
    }

    @Test func cancelPreviewClears() {
        let (c, s) = makeController()
        s.currentTranscript = "hello"
        c.begin(originScreen: .zero)
        c.update(toScreen: .init(x: 80, y: 0))
        c.end()
        c.cancelPreview()
        #expect(!c.showPreview)
        #expect(c.previewText == "")
    }

    @Test func sendAfterRecordingIncrementsTipCenter() async {
        let (c, s) = makeController()
        let tipCenter = TipCenter(defaults: UserDefaults(suiteName: "voice-tests-\(UUID().uuidString)")!)
        c.tipCenter = tipCenter
        s.finishResult = "ls"
        c.begin(originScreen: .zero)
        c.update(toScreen: .init(x: 0, y: -80))
        c.end()
        await waitFor { c.voiceSendTotal == 1 }
        #expect(tipCenter.recordedVoiceSendCount == 1)
    }
}
