import UIKit
import SwiftUI
import BentoTerminalCore

/// Manages the voice input gesture + recording lifecycle.
/// Added to a pane's terminal view as a long-press gesture recognizer.
///
/// Flow: hold >200ms → start recording → move finger → direction detection →
///       release → inject text based on direction
///
/// Two speech engines are supported and chosen per-recording from the
/// `speech_engine` user setting:
/// - "apple":  on-device `SFSpeechRecognizer` (no API key, may have lower
///   accuracy / language coverage; requires speech-recognition permission).
/// - "openai": cloud OpenAI Realtime API with `gpt-realtime-whisper`
///   (requires either `openai_api_key` direct BYOK, or `openai_proxy_url`
///   pointing at a token-mint server).
@MainActor
final class VoiceInputController: ObservableObject {
    @Published var isRecording = false
    @Published var transcript = ""
    @Published var activeDirection: VoiceDirection = .none
    @Published var showOverlay = false
    @Published var fingerScreenPosition: CGPoint = .zero

    /// Right-swipe "transcribe → preview → edit → send" flow. `previewText` is the
    /// editable transcription shown in the inline compose bar; `previewLoading` is
    /// true while the higher-accuracy batch model is still running.
    ///
    /// The SAME bar is the app's one managed input surface: voice fills it via
    /// `beginPreview`, the keyboard fills it via `beginManualCompose` (double-tap).
    /// `isManualCompose` just tweaks the copy (no re-transcription, 输入 placeholder).
    @Published var showPreview = false
    @Published var previewText = ""
    @Published var previewLoading = false
    @Published var isManualCompose = false

    /// Lifetime count of successful voice sends, published so the wrapper view
    /// can pace the advanced-gesture tip (3rd send) and the one-time Qwen
    /// suggestion (1st send). TipCenter owns the persistent value.
    @Published private(set) var voiceSendTotal = TipCenter.shared.recordedVoiceSendCount

    /// Measured height of the inline compose bar (content only, excluding its
    /// keyboard offset), published by `ComposeBar` so the pane container can pan
    /// terminal content clear of keyboard + bar — the whole point of the bar is
    /// composing while WATCHING the terminal, so the cursor line must stay
    /// visible above it.
    @Published var composeBarHeight: CGFloat = 0

    /// Escape hatch out of the managed box into the raw keyboard (direct-to-pane
    /// typing), for the minority interactive/TUI case. Set by the pane's VC to
    /// make its surface first responder.
    var onRequestRawKeyboard: (() -> Void)?

    /// Shared engine driver (engine selection + permissions + audio capture)
    /// lives in BentoTerminalCore so iOS + macOS run the same recording code.
    private let session = VoiceSession()

    private var holdOrigin: CGPoint = .zero

    /// Called when voice input produces a result
    var onResult: ((VoiceInputResult) -> Void)?

    /// Supplies the recording pane's on-screen text for Qwen context biasing; set
    /// by `TerminalContainerVC` (which owns the surface). Forwarded to the session.
    var readScreenText: (() -> String?)?

    init() {
        session.contextProvider = { [weak self] in self?.readScreenText?() }
    }

    /// Pre-allocate the mic engine the moment a voice gesture becomes likely
    /// (finger down, before the hold threshold), so the recording that may
    /// follow starts instantly instead of paying the AVAudioEngine cold-start
    /// tax — the parity twin of `MacVoiceController.prewarm()` (button-down).
    func prewarm() {
        session.prewarm()
    }

    /// `VoiceInputResult` now lives in BentoTerminalCore; alias keeps existing
    /// `VoiceInputController.VoiceInputResult` references working.
    typealias VoiceInputResult = BentoTerminalCore.VoiceInputResult

    // MARK: - Tap-to-Toggle (mic button)

    /// Tap-to-toggle recording, anchored at a screen point (used for overlay
    /// placement). First tap starts recording; second tap stops + submits the
    /// transcript with no directional modifier (plain text inject).
    func toggleRecording(anchorScreenPoint: CGPoint) {
        if isRecording {
            stopRecording(direction: .none)
        } else {
            fingerScreenPosition = anchorScreenPoint
            holdOrigin = anchorScreenPoint
            startRecording()
        }
    }

    // MARK: - Gesture Handling

    func handleLongPress(state: UIGestureRecognizer.State, location: CGPoint) {
        switch state {
        case .began:
            // Anchor the compass overlay at the press origin and keep it there.
            // The compass's center "finger dot" + 4 directional arrows are laid
            // out at fixed offsets, so the whole thing must NOT track the
            // finger — otherwise the arrows move with the user and can never
            // be reached. Direction feedback is conveyed by highlighting the
            // active arrow, not by moving the overlay.
            holdOrigin = location
            fingerScreenPosition = location
            startRecording()

        case .changed:
            updateDirection(currentLocation: location)

        case .ended, .cancelled:
            let finalDirection = activeDirection
            stopRecording(direction: finalDirection)

        default:
            break
        }
    }

    // MARK: - Recording

    private func startRecording() {
        // Show overlay immediately for responsiveness.
        isRecording = true
        showOverlay = true
        transcript = ""
        activeDirection = .none
        HapticService.shared.prepare()
        HapticService.shared.recordingStarted()
        // The shared VoiceSession handles permissions + engine selection + audio.
        session.start(
            onPartial: { [weak self] text in self?.transcript = text },
            onError: { [weak self] message in Task { await self?.showTransientError(message) } })
    }

    private func showTransientError(_ message: String) async {
        dlog(message)
        // Release the mic engine + ASR on error so a failed session can't leave a
        // running engine that the next recording stacks a second tap onto.
        session.cancel()
        transcript = message
        isRecording = false
        try? await Task.sleep(for: .milliseconds(1200))
        showOverlay = false
    }

    // MARK: - Stop

    private func stopRecording(direction: VoiceDirection) {
        if direction == .down {
            session.cancel()
            isRecording = false
            HapticService.shared.cancelled()
            showOverlay = false
            return
        }

        if direction == .right {
            // New flow: re-transcribe the full clip with a better (non-realtime)
            // model, then let the user preview/edit before sending — instead of
            // inserting directly. (Left swipe still does NL→shell-command.) The
            // preview batches the captured PCM itself, so just stop capture here.
            TelemetryService.shared.record(.voiceSwipeRightPreview)
            let streamed = session.currentTranscript
            session.cancel()
            isRecording = false
            showOverlay = false
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
            self.showOverlay = false
            guard !text.isEmpty else { return }
            HapticService.shared.sent()
            TelemetryService.shared.record(.voiceSend)
            TelemetryService.shared.record(.voiceFirstSend)
            if direction == .left { TelemetryService.shared.record(.voiceSwipeLeftLLM) }
            self.onResult?(VoiceInputResult(text: text, direction: direction))
            self.voiceSendTotal = TipCenter.shared.recordVoiceSend()
        }
    }

    // MARK: - Preview (right-swipe)

    /// Open the editable preview seeded with the fast streamed transcript, then —
    /// if we captured the full audio (OpenAI engine) — replace it with a higher-
    /// accuracy batch transcription. On the Apple engine (no PCM) the user just
    /// edits the streamed text.
    private func beginPreview(streamed: String) {
        isManualCompose = false
        previewText = streamed
        previewLoading = session.refineRecordedPCM(screenText: readScreenText?()) { better in
            if let better, !better.isEmpty { self.previewText = better }
            self.previewLoading = false
        }
        showPreview = true
    }

    /// Open the managed box empty for manual keyboard typing (double-tap entry).
    /// Same surface as voice; the bar auto-focuses so the keyboard comes up at
    /// once. Send is the same atomic paste + CR to the active pane.
    func beginManualCompose() {
        isManualCompose = true
        previewText = ""
        previewLoading = false
        showPreview = true
    }

    /// Leave the managed box and drop straight into the raw keyboard (the pane's
    /// VC wires `onRequestRawKeyboard` to make its surface first responder).
    func switchToRawKeyboard() {
        showPreview = false
        previewLoading = false
        previewText = ""
        isManualCompose = false
        onRequestRawKeyboard?()
    }

    /// Send the (possibly edited) preview text to the active pane (insert + send).
    func sendPreview() {
        let text = previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        showPreview = false
        previewLoading = false
        isManualCompose = false
        guard !text.isEmpty else { return }
        HapticService.shared.sent()
        TelemetryService.shared.record(.voiceSend)
        TelemetryService.shared.record(.voiceFirstSend)
        onResult?(VoiceInputResult(text: text, direction: .up))
        voiceSendTotal = TipCenter.shared.recordVoiceSend()
    }

    /// Dismiss the preview without sending.
    func cancelPreview() {
        showPreview = false
        previewLoading = false
        isManualCompose = false
        previewText = ""
    }

    // MARK: - Direction Detection

    private func updateDirection(currentLocation: CGPoint) {
        // Dead-zone + dominant-axis classification is shared with macOS in core.
        let newDirection = voiceDirection(forTranslation: CGSize(
            width: currentLocation.x - holdOrigin.x,
            height: currentLocation.y - holdOrigin.y))

        if newDirection != activeDirection {
            activeDirection = newDirection
            if newDirection != .none {
                HapticService.shared.directionChanged()
            }
        }
    }
}

// `TerminalViewModel.handleVoiceResult(_:)` now lives in BentoTerminalCore
// (shared by iOS + macOS).

/// The managed input surface as an INLINE BAR docked above the keyboard (like
/// the quick-keys accessory row) — deliberately NOT a modal: composing is
/// usually done while watching the terminal respond, so the panes stay visible
/// and the container pans them clear of keyboard + bar. Voice's right-swipe
/// preview and double-tap manual compose share it; while the batch model is
/// still re-transcribing, a slim "识别中…" row shows above the field.
///
/// The bar tracks the keyboard frame itself (UIKit notifications, same ground
/// truth as PaneContainerVC) instead of SwiftUI's automatic avoidance — the
/// terminal hierarchy deliberately ignores the keyboard safe area, so relying
/// on propagation here would be fragile. With the keyboard down it rests on
/// the bottom safe inset.
///
/// Lives here (not its own file) so it's picked up by the app target's source
/// list without a project.pbxproj edit.
struct ComposeBar: View {
    @ObservedObject var controller: VoiceInputController
    @FocusState private var focused: Bool
    /// Keyboard top edge in global (screen) coordinates; nil while hidden.
    @State private var keyboardTopGlobal: CGFloat?

    private var isEmpty: Bool {
        controller.previewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        GeometryReader { geo in
            bar
                .background(
                    GeometryReader { barGeo in
                        Color.clear
                            .onAppear { controller.composeBarHeight = barGeo.size.height }
                            .onChange(of: barGeo.size.height) { _, h in
                                controller.composeBarHeight = h
                            }
                    }
                )
                .padding(.bottom, bottomPadding(in: geo))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .ignoresSafeArea(.keyboard)
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillChangeFrameNotification)) { handleKeyboard($0) }
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillHideNotification)) { handleKeyboard($0) }
        .onAppear { focused = true }
        .onDisappear { controller.composeBarHeight = 0 }
    }

    /// Floating liquid-glass composer: no full-width slab, just glass elements
    /// hovering over the (still visible) terminal — any sliver of content
    /// showing between bar and keyboard reads as intentional, not as a gap.
    private var bar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if controller.previewLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("识别中…")
                        .font(.footnote)
                        .foregroundStyle(Color.bentoInkDim)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .modifier(GlassChrome(shape: .capsule))
            }
            inputRow
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    /// GlassEffectContainer lets adjacent glass shapes blend as one material
    /// (iOS 26); earlier systems just render the flat-styled row.
    @ViewBuilder
    private var inputRow: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 10) { inputRowContent }
        } else {
            inputRowContent
        }
    }

    private var inputRowContent: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button { controller.cancelPreview() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.bentoInkDim)
                    .frame(width: 38, height: 38)
            }
            .modifier(GlassChrome(shape: .circle))
            .accessibilityIdentifier("compose.cancel")

            // One-tap escape to the raw keyboard for interactive/TUI typing
            // (vim, mid-command Tab, etc.) — the minority case the bar can't
            // serve.
            Button { controller.switchToRawKeyboard() } label: {
                Image(systemName: "keyboard")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.bentoInkDim)
                    .frame(width: 38, height: 38)
            }
            .modifier(GlassChrome(shape: .circle))
            .accessibilityIdentifier("compose.raw")

            TextField(controller.isManualCompose ? "输入并发送" : "",
                      text: $controller.previewText, axis: .vertical)
                .lineLimit(1...5)
                .font(.body)
                .foregroundStyle(Color.bentoInk)
                .tint(Color.bentoEmerald)
                .focused($focused)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .modifier(GlassChrome(shape: .field))

            Button { controller.sendPreview() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(isEmpty ? Color.bentoInkDim : .white)
                    .frame(width: 38, height: 38)
            }
            .modifier(GlassChrome(shape: .circle, tint: isEmpty ? nil : Color.bentoEmerald))
            .disabled(isEmpty)
            .accessibilityIdentifier("compose.send")
        }
    }

    /// Lift the bar to the keyboard's top edge, measured in this view's own
    /// global frame so it's correct whatever safe-area context the overlay
    /// lands in. Keyboard down → rest on the bottom safe inset instead.
    private func bottomPadding(in geo: GeometryProxy) -> CGFloat {
        let frame = geo.frame(in: .global)
        let overlap = keyboardTopGlobal.map { max(0, frame.maxY - $0) } ?? 0
        return max(overlap, geo.safeAreaInsets.bottom)
    }

    private func handleKeyboard(_ note: Notification) {
        guard let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        else { return }
        let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey]
            as? Double ?? 0.25
        // Off-screen frame (hide / undock) → treat as no keyboard.
        let top: CGFloat? = end.minY >= UIScreen.main.bounds.maxY ? nil : end.minY
        withAnimation(.easeOut(duration: max(duration, 0.1))) {
            keyboardTopGlobal = top
        }
    }
}

/// Liquid-glass chrome for the compose bar's elements on iOS 26+, falling back
/// to the flat bento-surface look on earlier systems (deployment target 17).
/// `tint` colors the glass (the send button's emerald); nil = plain glass.
private struct GlassChrome: ViewModifier {
    enum Shape { case circle, capsule, field }
    var shape: Shape
    var tint: Color?

    init(shape: Shape, tint: Color? = nil) {
        self.shape = shape
        self.tint = tint
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            let glass: Glass = tint.map { Glass.regular.tint($0).interactive() }
                ?? Glass.regular.interactive()
            switch shape {
            case .circle:  content.glassEffect(glass, in: .circle)
            case .capsule: content.glassEffect(glass, in: .capsule)
            case .field:   content.glassEffect(glass, in: .rect(cornerRadius: 20))
            }
        } else {
            switch shape {
            case .circle:
                content
                    .background(Circle().fill(tint ?? Color.bentoSurface))
                    .overlay(Circle().strokeBorder(Color.bentoBorder, lineWidth: tint == nil ? 1 : 0))
            case .capsule:
                content
                    .background(Capsule().fill(tint ?? Color.bentoSurface))
                    .overlay(Capsule().strokeBorder(Color.bentoBorder, lineWidth: tint == nil ? 1 : 0))
            case .field:
                content
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.bentoSurface))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.bentoBorder, lineWidth: 1))
            }
        }
    }
}
