import UIKit
import SwiftUI
import BentoVoiceKit
import BentoTerminalCore

/// Manages the voice input gesture + recording lifecycle.
/// Added to a pane's terminal view as a long-press gesture recognizer.
///
/// Thin iOS shell over the shared `BentoTerminalCore.VoiceController` state
/// machine (recording, compass-direction routing, preview, error handling and
/// telemetry). This shell only maps the UIKit gesture onto the shared
/// begin/update/end lifecycle, injects iOS haptics, and adds the iOS-only
/// manual-compose state — the SAME bar as the right-swipe preview, entered by
/// double-tap keyboard. `isManualCompose` just tweaks the copy (输入 placeholder).
///
/// Flow: hold >180ms → start recording → move finger → direction detection →
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
final class VoiceInputController: VoiceController {
    /// Anchor of the compass overlay in screen points — the host clamps it
    /// against `VoiceCompassView.Metrics` so a press near an edge stays on screen.
    @Published var fingerScreenPosition: CGPoint = .zero

    /// True when the managed bar was opened by double-tap keyboard typing rather
    /// than a voice right-swipe.
    @Published var isManualCompose = false

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

    override init() {
        super.init()
        feedback = HapticFeedbackAdapter()
    }

    // MARK: - Gesture Handling

    /// UIKit gesture → shared lifecycle. The compass overlay is anchored at the
    /// press origin and must NOT track the finger — the four arrows sit at fixed
    /// offsets, so they'd move away otherwise; direction is conveyed by the
    /// highlighted arrow, not overlay position.
    func handleLongPress(state: UIGestureRecognizer.State, location: CGPoint) {
        switch state {
        case .began:
            fingerScreenPosition = location
            begin(originScreen: location)

        case .changed:
            update(toScreen: location)

        case .ended, .cancelled:
            end()

        default:
            break
        }
    }

    // MARK: - Manual compose (double-tap keyboard entry)

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

    // Voice's right-swipe preview and the keyboard's manual compose share one
    // bar surface, so every way out of it clears the manual-compose flag.
    override func beginPreview(streamed: String) {
        isManualCompose = false
        super.beginPreview(streamed: streamed)
    }

    override func sendPreview() {
        isManualCompose = false
        super.sendPreview()
    }

    override func cancelPreview() {
        isManualCompose = false
        super.cancelPreview()
    }
}

/// iOS haptics at the shared state machine's feedback moments.
@MainActor
private struct HapticFeedbackAdapter: VoiceFeedbackProviding {
    func prepare() { HapticService.shared.prepare() }
    func recordingStarted() { HapticService.shared.recordingStarted() }
    func directionChanged() { HapticService.shared.directionChanged() }
    func sent() { HapticService.shared.sent() }
    func cancelled() { HapticService.shared.cancelled() }
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
/// Internal (not private) so the fullscreen floating buttons reuse it.
struct GlassChrome: ViewModifier {
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
