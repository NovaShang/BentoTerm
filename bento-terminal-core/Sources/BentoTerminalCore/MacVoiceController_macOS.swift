#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import Combine
import SwiftUI

/// macOS hold-to-talk voice controller. Wraps the shared `VoiceSession` (engine
/// + permissions + audio) and adds the compass direction + published state the
/// overlay binds to. One per terminal window, owned by `GhosttyTiledPaneHost`.
@MainActor
public final class MacVoiceController: ObservableObject {
    @Published public private(set) var isRecording = false
    @Published public private(set) var transcript = ""
    @Published public private(set) var activeDirection: VoiceDirection = .none

    private let session = VoiceSession()
    private var originScreen: CGPoint = .zero
    private var errorClear: DispatchWorkItem?

    /// Fired with the final utterance + direction (unless cancelled/empty).
    public var onResult: ((VoiceInputResult) -> Void)?

    /// Supplies the active pane's recent on-screen text for Qwen context biasing;
    /// set by the pane host (which owns the terminal surface). Forwarded to the
    /// shared `VoiceSession` so the Qwen engine can bias toward on-screen entities.
    public var readScreenText: (() -> String?)?

    /// Right-swipe "transcribe → preview → edit → send" flow. `previewText` is the
    /// editable transcription; `previewLoading` is true while the higher-accuracy
    /// batch model is still running.
    @Published public private(set) var showPreview = false
    @Published public var previewText = ""
    @Published public private(set) var previewLoading = false

    public init() {
        session.contextProvider = { [weak self] in self?.readScreenText?() }
    }

    /// Pre-allocate the mic engine the moment a voice gesture becomes likely (the
    /// right button goes down), so the recording that may follow starts instantly.
    public func prewarm() {
        session.prewarm()
    }

    /// Begin hold-to-talk, anchored at a screen point (for direction tracking).
    public func begin(originScreen: CGPoint) {
        guard !isRecording else { return }
        errorClear?.cancel()
        self.originScreen = originScreen
        isRecording = true
        transcript = ""
        activeDirection = .none
        session.start(
            onPartial: { [weak self] t in self?.transcript = t },
            onError: { [weak self] msg in self?.fail(msg) })
    }

    /// Update the compass from the current cursor location (screen points).
    public func update(toScreen p: CGPoint) {
        guard isRecording else { return }
        // macOS screen coords are y-up; flip dy so an upward drag reads as `.up`.
        let t = CGSize(width: p.x - originScreen.x, height: -(p.y - originScreen.y))
        activeDirection = voiceDirection(forTranslation: t)
    }

    /// End hold-to-talk; routes the result unless cancelled (↓) or empty.
    public func end() {
        guard isRecording else { return }
        let dir = activeDirection
        activeDirection = .none

        if dir == .down {
            session.cancel()
            isRecording = false
            return
        }
        if dir == .right {
            // Re-transcribe the full clip with a better model, then preview/edit
            // before sending. (Left swipe still does NL→shell-command.) The preview
            // batches the captured PCM itself, so just stop capture here.
            let streamed = session.currentTranscript
            session.cancel()
            isRecording = false
            beginPreview(streamed: streamed)
            return
        }
        // up / none / left → resolve the reliable final. A settled utterance sends
        // instantly; only a mid-speech release waits. Show "识别中…" only if that
        // wait actually drags on (>200ms), so fast sends never flash it.
        Task { [weak self] in
            guard let self else { return }
            let lang = openAILanguageHint(for: UserDefaults.standard.string(forKey: "speech_locale") ?? "auto")
            let indicator = DispatchWorkItem { [weak self] in self?.transcript = "识别中…" }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: indicator)
            let text = await self.session.finish(language: lang)
            indicator.cancel()
            self.isRecording = false
            guard !text.isEmpty else { return }
            self.onResult?(VoiceInputResult(text: text, direction: dir))
        }
    }

    // MARK: - Preview (right-swipe)

    private func beginPreview(streamed: String) {
        previewText = streamed
        // No PCM (Apple engine) → refine is a no-op; the user edits the streamed text.
        previewLoading = session.refineRecordedPCM(screenText: readScreenText?()) { better in
            if let better, !better.isEmpty { self.previewText = better }
            self.previewLoading = false
        }
        showPreview = true
    }

    /// Send the (possibly edited) preview text to the active pane (insert + send).
    public func sendPreview() {
        let text = previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        showPreview = false
        previewLoading = false
        guard !text.isEmpty else { return }
        onResult?(VoiceInputResult(text: text, direction: .up))
    }

    /// Dismiss the preview without sending.
    public func cancelPreview() {
        showPreview = false
        previewLoading = false
        previewText = ""
    }

    private func fail(_ message: String) {
        // Release the mic engine + ASR NOW. Without this a failed/dropped session
        // (e.g. "network connection was lost") leaves the AVAudioEngine running;
        // the next recording then installs a SECOND tap on the same input bus,
        // corrupting CoreAudio and hanging the main thread — the terminal froze
        // after a "network lost" voice error.
        session.cancel()
        transcript = message
        // Leave the overlay up briefly so the error is readable, then dismiss.
        let work = DispatchWorkItem { [weak self] in self?.isRecording = false }
        errorClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
}

/// macOS editable preview for the right-swipe ("AI correct") flow: shows the
/// higher-accuracy batch transcription, editable with the keyboard, then send it
/// to the active pane. ⌘⏎ sends, ⎋ cancels (plain ⏎ stays a newline in the
/// editor). Hosted by `GhosttyTiledPaneHost` as a centered overlay card.
struct MacVoicePreviewView: View {
    @ObservedObject var controller: MacVoiceController
    @FocusState private var focused: Bool

    private var isEmpty: Bool {
        controller.previewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("语音预览").font(.headline)
                Spacer()
                if controller.previewLoading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("识别中…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            TextEditor(text: $controller.previewText)
                .font(.body)
                .frame(minHeight: 120)
                .focused($focused)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.4)))
            HStack {
                Text("⌘⏎ 发送 · ⎋ 取消").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { controller.cancelPreview() }
                    .keyboardShortcut(.cancelAction)
                Button("发送") { controller.sendPreview() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onAppear { focused = true }
    }
}

/// Compass + transcript overlay, rendered in SwiftUI (materials, shadows, smooth
/// highlight) and hosted in AppKit. The host sizes/positions and shows/hides it;
/// it never intercepts the mouse (the recording drag belongs to the surface).
@MainActor
public final class MacVoiceOverlay: NSView {
    public static let preferredSize = NSSize(width: 360, height: 380)

    private let hosting: NSHostingView<VoiceCompassView>

    public override init(frame frameRect: NSRect) {
        hosting = NSHostingView(rootView: VoiceCompassView(transcript: "", direction: .none))
        super.init(frame: frameRect)
        wantsLayer = true
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public var transcript: String = "" { didSet { rebuild() } }
    public var direction: VoiceDirection = .none { didSet { rebuild() } }

    private func rebuild() {
        hosting.rootView = VoiceCompassView(transcript: transcript, direction: direction)
    }
}

#endif
