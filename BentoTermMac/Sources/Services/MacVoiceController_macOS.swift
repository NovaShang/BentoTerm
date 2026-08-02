import BentoVoiceKit
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import Combine
import SwiftUI
import BentoTerminalCore

/// macOS hold-to-talk voice controller — a thin shell over the shared
/// `BentoTerminalCore.VoiceController` state machine (recording, compass-
/// direction routing, preview, error handling, telemetry). Its only job here is
/// the platform seam: macOS screen coords are y-up, the shared controller works
/// in y-down point space, so both entry points flip y. One per terminal window,
/// owned by `GhosttyTiledPaneHost`; the shared published state drives
/// `MacVoiceOverlay` / `MacVoicePreviewView` below.
@MainActor
public final class MacVoiceController: VoiceController {
    public override func begin(originScreen p: CGPoint) {
        super.begin(originScreen: CGPoint(x: p.x, y: -p.y))
    }

    public override func update(toScreen p: CGPoint) {
        super.update(toScreen: CGPoint(x: p.x, y: -p.y))
    }

    // prewarm / end / preview send+cancel / onResult / readScreenText inherited
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
    public static let preferredSize = NSSize(width: 360, height: 580)

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
    public var fingerOffset: CGSize = .zero { didSet { rebuild() } }

    private func rebuild() {
        hosting.rootView = VoiceCompassView(transcript: transcript,
                                            direction: direction,
                                            fingerOffset: fingerOffset)
    }
}

#endif
