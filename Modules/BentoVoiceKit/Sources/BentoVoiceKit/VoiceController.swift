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
        self.originScreen = originScreen
        isRecording = true
        showOverlay = true
        transcript = ""
        activeDirection = .none
        fingerOffset = .zero
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
    open func end() {
        guard isRecording else { return }
        let dir = activeDirection

        if dir == .down {
            activeDirection = .none
            session.cancel()
            isRecording = false
            feedback.cancelled()
            showOverlay = false
            return
        }
        if dir == .right {
            // Re-transcribe the full clip with a better model, then preview/edit
            // before sending. (Left swipe still does NL→shell-command.) The preview
            // batches the captured PCM itself, so just stop capture here.
            TelemetryService.shared.record(.voiceSwipeRightPreview)
            let streamed = session.currentTranscript
            activeDirection = .none
            session.cancel()
            isRecording = false
            showOverlay = false
            beginPreview(streamed: streamed)
            return
        }
        // up / none / left → resolve the reliable final. A settled utterance sends
        // instantly; only a mid-speech release waits. Show "识别中…" only if that
        // wait actually drags on (>200ms), so fast sends never flash it.
        //
        // KEEP `activeDirection` (and with it the release target's highlight and
        // the finger ball's rest point) lit while the final text resolves: the
        // overlay lingers here for up to a couple of seconds, and reverting the
        // compass to its neutral center mid-wait reads as the gesture dying. It
        // snaps to `.none` the moment the overlay hides.
        Task { [weak self] in
            guard let self else { return }
            let lang = openAILanguageHint(for: UserDefaults.standard.string(forKey: "speech_locale") ?? "auto")
            let indicator = DispatchWorkItem { [weak self] in self?.transcript = "识别中…" }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: indicator)
            let text = await self.session.finish(language: lang)
            indicator.cancel()
            self.activeDirection = .none
            self.isRecording = false
            self.showOverlay = false
            guard !text.isEmpty else { return }
            self.feedback.sent()
            TelemetryService.shared.record(.voiceSend)
            TelemetryService.shared.record(.voiceFirstSend)
            if dir == .left { TelemetryService.shared.record(.voiceSwipeLeftLLM) }
            self.onResult?(VoiceInputResult(text: text, direction: dir))
            self.voiceSendTotal = self.tipCenter.recordVoiceSend()
        }
    }

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
            self?.showOverlay = false
        }
    }
}
