import BentoVoiceKit
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import Combine
import SwiftUI
import BentoSessionKit
import BentoFoundationKit

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
///
/// The root view observes the controller directly, so the SwiftUI view tree is
/// created ONCE — state changes flow through `@ObservedObject` and the
/// animations (bubble growing line by line, discs morphing) actually run.
/// (Rebuilding the root view on every transcript update threw the animation
/// state away: the bubble jumped straight to full size instead of growing.)
@MainActor
public final class MacVoiceOverlay: NSView {
    public static let preferredSize = NSSize(width: 360, height: 580)

    private let hosting: NSHostingView<VoiceCompassView>
    private let controller: MacVoiceController

    /// Where the transcript bubble sits relative to the anchor. Set by the host
    /// when it positions the overlay — i.e. BEFORE the recording (and the
    /// compass's entrance animation) begins, which is why replacing the root
    /// view here is safe: mid-recording it would cancel the animation.
    public var placement = VoiceCompassView.Placement() {
        didSet {
            guard placement != oldValue else { return }
            hosting.rootView = VoiceCompassView(controller: controller, placement: placement)
        }
    }

    public init(controller: MacVoiceController, frame frameRect: NSRect) {
        self.controller = controller
        hosting = NSHostingView(rootView: VoiceCompassView(controller: controller))
        super.init(frame: frameRect)
        wantsLayer = true
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

#endif
