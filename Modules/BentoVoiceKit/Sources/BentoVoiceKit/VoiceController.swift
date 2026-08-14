import Foundation
import Combine
import BentoFoundationKit

// MARK: - Feedback seam

/// Per-platform feedback (haptics on iOS, no-op on macOS) fired at the moments
/// the voice gesture's state machine lands. Injected by the platform shells —
/// the shared controller never touches UIKit/AppKit.
@MainActor
public protocol VoiceFeedbackProviding {
    func prepare()               // begin: mic arming
    func recordingStarted()      // begin: overlay + recording live
    func directionChanged()      // update: first entry into a non-.none direction
    func sent()                  // successful send / preview send
    func cancelled()             // .down release
}

public struct NoopVoiceFeedback: VoiceFeedbackProviding {
    public init() {}
    public func prepare() {}
    public func recordingStarted() {}
    public func directionChanged() {}
    public func sent() {}
    public func cancelled() {}
}

// MARK: - Shared voice controller state machine

/// The hold-to-talk voice state machine, shared by iOS + macOS: press lifecycle
/// (begin/update/end), compass-direction routing, the right-swipe preview flow,
/// error handling, telemetry and the send-count pacing. Renders nothing — the
/// platform shells host the shared `VoiceCompassView` against its published
/// state and map the platform gesture onto `begin(originScreen:)` /
/// `update(toScreen:)` / `end()`.
///
/// Coordinate convention: **y-down point space** (screen points). The delta math
/// is origin-anchored, so any uniform flip of the input space is exact as long
/// as `begin` and `update` see the same space — iOS passes UIKit coords as-is;
/// the macOS shell flips y (its screen coords are y-up).
///
/// The audio/engine work all lives in the shared `VoiceSession` (via
/// `VoiceSessionProtocol`, a test seam) — this class is gesture + direction +
/// preview + telemetry only.
@MainActor
open class VoiceController: ObservableObject {
    @Published public private(set) var isRecording = false
    @Published public private(set) var transcript = ""
    @Published public private(set) var activeDirection: VoiceDirection = .none
    @Published public private(set) var showOverlay = false

    /// The overlay is playing its EXIT animation: still on screen (`showOverlay`
    /// stays true for `dismissDuration`), but the compass is folding away. The
    /// shared view reads this to run its outro; hosts keep following
    /// `showOverlay` alone and see no extra state.
    @Published public private(set) var isDismissing = false

    /// How long the compass gets to fold away before the overlay is torn down.
    /// The view choreographs its outro against the same number, so it lives here
    /// as the one source of truth.
    public static let dismissDuration: Duration = .milliseconds(560)

    /// Drag delta from the press origin (y-down point space), fed to the shared
    /// compass so the finger ball can track the drag.
    @Published public private(set) var fingerOffset: CGSize = .zero

    /// Right-swipe "transcribe → preview → edit → send" flow. `previewText` is the
    /// editable transcription; `previewLoading` is true while the higher-accuracy
    /// batch model is still running. Setters public because the iOS shell's
    /// manual-compose flow drives the same surface (its `beginManualCompose` /
    /// `switchToRawKeyboard` open/close the bar).
    @Published public var showPreview = false
    /// Public setter: both platforms bind an editor (`$controller.previewText`).
    @Published public var previewText = ""
    @Published public var previewLoading = false

    /// Lifetime count of successful voice sends, published so the iOS wrapper can
    /// pace the advanced-gesture tip (3rd send) and the one-time Qwen suggestion
    /// (1st send). TipCenter owns the persistent value — shared by both platforms.
    @Published public private(set) var voiceSendTotal = 0

    /// The pacing-counter store (test seam; defaults to the app-wide singleton).
    var tipCenter: TipCenter = .shared

    /// Fired with the final utterance + direction (unless cancelled/empty).
    public var onResult: ((VoiceInputResult) -> Void)?

    /// Supplies the active pane's recent on-screen text for Qwen context biasing;
    /// set by the platform host (which owns the terminal surface). Forwarded to
    /// the shared `VoiceSession`.
    public var readScreenText: (() -> String?)?

    /// Platform feedback injection (iOS haptics; macOS no-op).
    public var feedback: any VoiceFeedbackProviding = NoopVoiceFeedback()

    private let session: any VoiceSessionProtocol
    private var originScreen: CGPoint = .zero

    /// Cancellable dismissal of the error overlay. Cancelled on the next `begin`
    /// so a new recording inside the error window isn't yanked by the stale
    /// sleep (the iOS pre-refactor race).
    private var errorDismissTask: Task<Void, Never>?

    /// The outro timer (see `dismissOverlay`). Cancelled by a new `begin`, so a
    /// press landing inside the fold-away keeps the overlay instead of having it
    /// pulled out from under the fresh recording.
    private var dismissTask: Task<Void, Never>?

    public init() {
        self.session = VoiceSession()
        voiceSendTotal = tipCenter.recordedVoiceSendCount
        wireContextProvider()
    }

    /// Test seam: inject a fake session (see VoiceControllerTests).
    init(session: any VoiceSessionProtocol) {
        self.session = session
        voiceSendTotal = tipCenter.recordedVoiceSendCount
        wireContextProvider()
    }

    private func wireContextProvider() {
        session.contextProvider = { [weak self] in self?.readScreenText?() }
    }

    /// Pre-allocate the mic engine the moment a voice gesture becomes likely (the
    /// right button / finger goes down), so the recording that may follow starts
    /// instantly instead of paying the AVAudioEngine cold-start tax.
    public func prewarm() {
        session.prewarm()
    }

    /// Begin hold-to-talk, anchored at a screen point (y-down, see type doc).
    open func begin(originScreen: CGPoint) {
        guard !isRecording else { return }
        errorDismissTask?.cancel()
        // A press during the previous overlay's fold-away: keep the overlay and
        // replay the intro from wherever it got to, rather than letting the
        // stale outro tear it down mid-recording.
        dismissTask?.cancel()
        isDismissing = false
        self.originScreen = originScreen
        isRecording = true
        showOverlay = true
        transcript = ""
        activeDirection = .none
        fingerOffset = .zero
        startWatchdog("recording begins")
        feedback.prepare()
        feedback.recordingStarted()
        // The shared VoiceSession handles permissions + engine selection + audio.
        session.start(
            onPartial: { [weak self] t in self?.transcript = t },
            onError: { [weak self] msg in self?.fail(msg) })
    }

    /// Update the compass from the current cursor/finger location (y-down).
    open func update(toScreen p: CGPoint) {
        guard isRecording else { return }
        // Dead-zone + dominant-axis classification is shared with the compass.
        let t = CGSize(width: p.x - originScreen.x, height: p.y - originScreen.y)
        fingerOffset = t
        let newDirection = voiceDirection(forTranslation: t)
        if newDirection != activeDirection {
            activeDirection = newDirection
            if newDirection != .none { feedback.directionChanged() }
        }
    }

    /// End hold-to-talk; routes the result unless cancelled (↓) or empty.
    ///
    /// The RELEASE is the end of the gesture, so the overlay leaves on the
    /// release — every direction, no waiting. Resolving the final text can take
    /// the better part of a second (Qwen commits the buffer and waits for its
    /// authoritative `completed`, and a thin clip may fall back to a batch
    /// transcription); that work now finishes with the compass already gone and
    /// delivers its text whenever it lands. Holding the overlay up for it read
    /// as the app hanging on mouse-up.
    open func end() {
        guard isRecording else { return }
        let dir = activeDirection
        isRecording = false
        dlog("[watchdog] RELEASE dir=\(dir) — outro starts now")
        dismissOverlay()
        // The main thread has to be free for the compass to fade out: anything
        // blocking here (CoreAudio teardown was the offender) freezes the
        // animation and the release looks like a hang. Logged so a regression
        // shows up as a number instead of a feeling.
        let t0 = Date()
        defer {
            let ms = Date().timeIntervalSince(t0) * 1000
            if ms > 16 { dlog("[voice] end() blocked the main thread for \(Int(ms))ms") }
        }

        if dir == .down {
            session.cancel()
            feedback.cancelled()
            return
        }
        if dir == .right {
            // Re-transcribe the full clip with a better model, then preview/edit
            // before sending. (Left swipe still does NL→shell-command.) The preview
            // batches the captured PCM itself, so just stop capture here.
            TelemetryService.shared.record(.voiceSwipeRightPreview)
            let streamed = session.currentTranscript
            session.cancel()
            beginPreview(streamed: streamed)
            return
        }
        // up / none / left → resolve the reliable final in the background.
        Task { [weak self] in
            guard let self else { return }
            let lang = openAILanguageHint(for: UserDefaults.standard.string(forKey: "speech_locale") ?? "auto")
            let text = await self.session.finish(language: lang)
            guard !text.isEmpty else { return }
            self.feedback.sent()
            TelemetryService.shared.record(.voiceSend)
            TelemetryService.shared.record(.voiceFirstSend)
            if dir == .left { TelemetryService.shared.record(.voiceSwipeLeftLLM) }
            self.onResult?(VoiceInputResult(text: text, direction: dir))
            self.voiceSendTotal = self.tipCenter.recordVoiceSend()
        }
    }

    /// Take the overlay down THROUGH its outro instead of yanking it: the
    /// compass gets `dismissDuration` to fold away, and only then does
    /// `showOverlay` drop (which is all the hosts watch).
    ///
    /// `activeDirection` is cleared at the END, not here — the outro's whole
    /// idea is that the target the release acted on outlives everything else,
    /// so it has to stay lit for the length of the animation.
    private func dismissOverlay() {
        guard showOverlay else {
            activeDirection = .none
            return
        }
        guard !isDismissing else { return }
        isDismissing = true
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: VoiceController.dismissDuration)
            guard !Task.isCancelled, let self else { return }
            dlog("[watchdog] overlay torn down")
            self.stopWatchdog()
            self.showOverlay = false
            self.isDismissing = false
            self.activeDirection = .none
        }
    }

    // MARK: - Main-thread stall watchdog

    /// A repeating main-actor tick that reports its own lateness while the
    /// overlay is up. The compass animating and the compass being ON SCREEN but
    /// frozen look identical from the outside; this tells them apart, with the
    /// stall's size and its offset from the release.
    ///
    /// Opt in with `defaults write com.bento.term.mac voice_watchdog -bool YES`
    /// (off by default — it is a diagnostic, not a feature).
    private var watchdog: Timer?
    private var watchdogLast = Date()
    private static var watchdogEnabled: Bool {
        UserDefaults.standard.bool(forKey: "voice_watchdog")
    }

    private func startWatchdog(_ tag: String) {
        guard Self.watchdogEnabled else { return }
        stopWatchdog()
        dlog("[watchdog] \(tag) t=0")
        let t0 = Date()
        watchdogLast = t0
        // .common so it keeps ticking through event tracking (a mouse drag).
        let timer = Timer(timeInterval: 0.008, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Date()
                let gap = now.timeIntervalSince(self.watchdogLast) * 1000
                if gap > 50 {
                    dlog("[watchdog] MAIN THREAD STALLED \(Int(gap))ms, at +\(Int(now.timeIntervalSince(t0) * 1000))ms")
                }
                self.watchdogLast = now
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    // MARK: - Debug harness

    /// Put the overlay up with no microphone and no ASR session, so the compass
    /// choreography can be driven and measured on its own (a probe app, a
    /// preview). Not part of the gesture path.
    public func debugPresentOverlay(direction: VoiceDirection = .up, transcript text: String = "") {
        showOverlay = true
        isDismissing = false
        activeDirection = direction
        transcript = text
    }

    /// Take it down again through the real exit path.
    public func debugDismissOverlay() { dismissOverlay() }

    // MARK: - Preview (right-swipe)

    /// Open the editable preview seeded with the fast streamed transcript, then —
    /// if we captured the full audio (realtime engine) — replace it with a
    /// higher-accuracy batch transcription. On the Apple engine (no PCM) the user
    /// just edits the streamed text.
    open func beginPreview(streamed: String) {
        previewText = streamed
        previewLoading = session.refineRecordedPCM(screenText: readScreenText?()) { better in
            if let better, !better.isEmpty { self.previewText = better }
            self.previewLoading = false
        }
        showPreview = true
    }

    /// Send the (possibly edited) preview text to the active pane (insert + send).
    open func sendPreview() {
        let text = previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        showPreview = false
        previewLoading = false
        guard !text.isEmpty else {
            dlog("[voice] sendPreview EMPTY — previewText='\(previewText)'")
            return
        }
        feedback.sent()
        TelemetryService.shared.record(.voiceSend)
        TelemetryService.shared.record(.voiceFirstSend)
        onResult?(VoiceInputResult(text: text, direction: .up))
        voiceSendTotal = tipCenter.recordVoiceSend()
    }

    /// Dismiss the preview without sending.
    open func cancelPreview() {
        showPreview = false
        previewLoading = false
        previewText = ""
    }

    // MARK: - Error

    private func fail(_ message: String) {
        dlog("[voice] error: \(message)")
        // Release the mic engine + ASR NOW. Without this a failed/dropped session
        // (e.g. "network connection was lost") leaves the AVAudioEngine running;
        // the next recording then installs a SECOND tap on the same input bus,
        // corrupting CoreAudio and hanging the main thread — the terminal froze
        // after a "network lost" voice error.
        session.cancel()
        transcript = message
        activeDirection = .none
        isRecording = false
        // Leave the overlay up briefly so the error is readable, then dismiss.
        // Cancellable so a new recording inside the window isn't yanked.
        errorDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            self?.dismissOverlay()
        }
    }
}
