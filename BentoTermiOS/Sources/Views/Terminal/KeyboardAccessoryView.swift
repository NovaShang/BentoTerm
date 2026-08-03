import SwiftUI

enum AccessoryKey: CaseIterable {
    case escape, tab, ctrl, enter
    case up, down, left, right
    case pipe, slash, tilde, dash
    case paste
}

/// Controller for the quick-keys bar that floats above the keyboard in raw
/// keyboard mode. NOT a UIView anymore (2026-08-02 unification): the row
/// (`AccessoryKeyRow`) is shown by the terminal host in the shared
/// `FloatingKeyboardBar` overlay — the same positioning mechanism the compose
/// bar uses, replacing the old `inputAccessoryView`. This object owns the Ctrl
/// state and the callbacks; the host creates one per pane and the overlay binds
/// to the active pane's row.
@MainActor
final class KeyboardAccessoryView {
    var onKeyTap: ((AccessoryKey) -> Void)?
    /// Tapped the "hide keyboard" button (double-tap no longer dismisses, since
    /// in keyboard mode it selects text).
    var onDismissKeyboard: (() -> Void)?
    /// Tapped the "switch to the compose box" button — the one-tap way back from
    /// raw keyboard to the managed input box.
    var onSwitchToCompose: (() -> Void)?

    /// Ctrl state lives here (the shell API `toggleCtrl`/`deactivateCtrl` and
    /// the key's emerald tint both read it) — one source of truth, mutated by
    /// the shell so taps through `onKeyTap` never double-toggle.
    private let rowModel = AccessoryRowModel()

    var isCtrlActive: Bool { rowModel.isCtrlActive }

    func toggleCtrl() {
        rowModel.isCtrlActive.toggle()
    }

    func deactivateCtrl() {
        rowModel.isCtrlActive = false
    }

    /// The bar's SwiftUI content, bound to this controller.
    func makeRow() -> AccessoryKeyRow {
        AccessoryKeyRow(
            model: rowModel,
            onKeyTap: { [weak self] key in self?.onKeyTap?(key) },
            onDismissKeyboard: { [weak self] in self?.onDismissKeyboard?() },
            onSwitchToCompose: { [weak self] in self?.onSwitchToCompose?() }
        )
    }
}

/// Ctrl toggle state, observable by the SwiftUI row. Ctrl is a lock — it
/// stays until consumed by a ctrl byte or re-tapped.
final class AccessoryRowModel: ObservableObject {
    @Published var isCtrlActive = false
}

/// One floating glass circle, ComposeBar family — used for the two leading
/// utility buttons. GlassChrome goes OUTSIDE the Button: with the glass inside
/// the label, the interactive glass eats taps outside the icon (glow feedback
/// but no action); wrapping the Button makes the whole glass circle tappable.
/// The icon is the button's content, i.e. still the glass's content.
private struct GlassKeyButton: View {
    var systemName: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.bentoInk)
                .frame(width: 40, height: 40)
        }
        // NO explicit buttonStyle — byte-for-byte the composer's circle
        // structure (that one's trigger area is verified correct).
        .modifier(GlassChrome(shape: .circle))
    }
}

/// The quick-keys bar's content. Left to right: two INDEPENDENT glass circles
/// (dismiss keyboard, switch to the compose box), then ONE glass capsule
/// holding every key as a plain native-style button — no per-key styling of
/// our own. Paste is a standalone trailing button (not buried in the
/// scrollable capsule). Floats via `FloatingKeyboardBar`; the height is fixed
/// and known to the occlusion pipeline (`barHeight`).
struct AccessoryKeyRow: View {
    /// Fixed height of the bar. The host's `bottomOcclusion` adds this to the
    /// bare keyboard's inset while the bar is up, so it must match the rendered
    /// row (40pt circles + capsule, no vertical padding).
    static let barHeight: CGFloat = 40

    @ObservedObject var model: AccessoryRowModel
    var onKeyTap: (AccessoryKey) -> Void
    var onDismissKeyboard: () -> Void
    var onSwitchToCompose: () -> Void

    private let keys: [(AccessoryKey, String)] = [
        (.escape, "Esc"),
        (.tab, "Tab"),
        (.ctrl, "Ctrl"),
        (.up, "\u{2191}"),
        (.down, "\u{2193}"),
        (.left, "\u{2190}"),
        (.right, "\u{2192}"),
        (.pipe, "|"),
        (.slash, "/"),
        (.tilde, "~"),
        (.dash, "-"),
    ]

    var body: some View {
        HStack(spacing: 8) {
            GlassKeyButton(systemName: "keyboard.chevron.compact.down") {
                onDismissKeyboard()
            }

            GlassKeyButton(systemName: "square.and.pencil") {
                onSwitchToCompose()
            }

            // One capsule container; the keys are plain Buttons inside.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(keys, id: \.0) { key, label in
                        Button {
                            onKeyTap(key)
                        } label: {
                            Text(label)
                                .font(.system(size: 14, weight: .regular))
                                .foregroundStyle(
                                    key == .ctrl && model.isCtrlActive
                                        ? Color.bentoEmerald : Color.primary)
                        }
                        // NO explicit buttonStyle — same as the composer's
                        // verified buttons.
                    }
                }
                .padding(.horizontal, 14)
            }
            .frame(height: Self.barHeight)
            .clipShape(Capsule())
            .modifier(GlassChrome(shape: .capsule))

            // Paste is its own standalone button at the far right (not
            // buried in the scrollable capsule).
            GlassKeyButton(systemName: "doc.on.clipboard") {
                onKeyTap(.paste)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Self.barHeight)
    }
}
