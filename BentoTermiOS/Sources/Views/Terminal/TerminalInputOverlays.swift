import SwiftUI
import BentoVoiceKit

/// The input chrome every terminal screen floats over its panes — the tmux
/// session screen and the plain shell alike: the voice compass, the quick-keys
/// bar riding the keyboard, and the inline compose bar.
///
/// One modifier so both screens get the same keyboard tracking. That tracking
/// is easy to get subtly wrong (third-party IMEs only send
/// `keyboardWillChangeFrame`, never willShow), and a second copy is a second
/// place for it to drift.
struct TerminalInputOverlays: ViewModifier {
    @ObservedObject var voiceController: VoiceInputController
    @ObservedObject var paneBridge: PaneContainerBridge

    /// Keyboard top edge in global (screen) coordinates; nil while hidden.
    /// Tracked ONCE here and shared by both floating keyboard bars (compose +
    /// quick-keys) so they move with the same animated value.
    @State private var keyboardTopGlobal: CGFloat?

    /// The quick-keys bar floats whenever the raw keyboard is up and nothing
    /// else owns the bottom strip (compose bar, find bar).
    private var showRawKeyboardBar: Bool {
        keyboardTopGlobal != nil && !voiceController.showPreview && !paneBridge.findBarActive
    }

    func body(content: Content) -> some View {
        content
            .overlay { voiceOverlay }
            // The managed input surface: an inline bar riding the keyboard's top
            // edge (NOT a modal — the terminal stays visible and pans clear, so
            // you compose while watching output). Both keyboard bars float
            // through FloatingKeyboardBar, sharing the keyboard top tracked
            // above — switching modes is a pure overlay swap, the keyboard
            // never collapses. The hit target is just the bar, the rest of the
            // overlay passes touches through to the panes.
            .overlay(alignment: .bottom) {
                if showRawKeyboardBar,
                   let row = paneBridge.container?.focusedOrActiveVC?.accessoryView.makeRow() {
                    FloatingKeyboardBar(keyboardTopGlobal: keyboardTopGlobal,
                                        onHeightChanged: { _ in }) {
                        row
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if voiceController.showPreview {
                    ComposeBar(controller: voiceController, keyboardTopGlobal: keyboardTopGlobal)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: voiceController.showPreview)
            .animation(.easeInOut(duration: 0.2), value: showRawKeyboardBar)
            .onReceive(NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillChangeFrameNotification)) { note in
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
            .onReceive(NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillHideNotification)) { _ in
                withAnimation(.easeOut(duration: 0.25)) {
                    keyboardTopGlobal = nil
                }
            }
    }

    @ViewBuilder
    private var voiceOverlay: some View {
        if voiceController.showOverlay {
            GeometryReader { geo in
                let anchor = compassAnchor(in: geo)
                VoiceCompassView(controller: voiceController,
                                 placement: .resolve(anchor: anchor,
                                                     in: geo.frame(in: .local),
                                                     insets: compassInsets(in: geo)))
                .position(anchor)
            }
            .ignoresSafeArea()
            // No transition here on purpose: the compass choreographs its own
            // entrance and exit internally (macOS can't use a transition at all
            // — it keeps one hosting view around — so the animation had to live
            // in the shared view). `showOverlay` only drops once the outro has
            // finished, by which point there is nothing left to fade.
        }
    }

    /// Edges the compass cannot use: the safe areas, plus the floating quick-keys
    /// toolbar at the bottom (the down target has to clear it).
    private func compassInsets(in geo: GeometryProxy) -> EdgeInsets {
        let safe = geo.safeAreaInsets
        return EdgeInsets(top: safe.top,
                          leading: safe.leading,
                          bottom: safe.bottom + FloatingQuickKeysToolbar.reservedBand,
                          trailing: safe.trailing)
    }

    /// Keep the compass on screen when the press starts near an edge — only
    /// as far as the ring needs, inside the safe areas and above the quick-keys
    /// band (`VoiceCompassView.Placement.clampedAnchor`).
    private func compassAnchor(in geo: GeometryProxy) -> CGPoint {
        VoiceCompassView.Placement.clampedAnchor(voiceController.fingerScreenPosition,
                                                 in: geo.frame(in: .local),
                                                 insets: compassInsets(in: geo))
    }
}
