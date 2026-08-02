import UIKit
import SwiftUI
import BentoFoundationKit

enum AccessoryKey: CaseIterable {
    case escape, tab, ctrl, enter
    case up, down, left, right
    case pipe, slash, tilde, dash
    case paste
}

/// Docked quick-keys bar above the keyboard.
///
/// The shell is a `.keyboard` UIInputView — `inputAccessoryView` must be a
/// UIView, and the style gives the keyboard's own material around the row. The
/// CONTENT, however, is SwiftUI: the same Liquid Glass recipe as the compose
/// bar, which renders in this exact spot on the same screen. The first UIKit
/// attempt hosted the keys inside the glass capsule's `contentView`; in the
/// keyboard-hosted hierarchy that contentView never gets sized, so every key
/// stayed at its zero frame — all icons stacked on one point. SwiftUI lays the
/// row out itself, so it is immune to that chain. The shell keeps the trait
/// pinned to the app's appearance for the dynamic colors.
final class KeyboardAccessoryView: UIInputView {
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
    private var hostingController: UIHostingController<AccessoryKeyRow>?

    init() {
        // The bar's frame is SHORTER than the glass row. The row is top-aligned
        // and hangs below the bar's bottom edge, into the keyboard's own top
        // inset (system-owned, ~16pt) — closing the dead gap between the keys
        // and the keyboard. The accessory can't sit any lower than the keyboard
        // top, so the row overlaps the inset instead.
        super.init(
            frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 28),
            inputViewStyle: .keyboard
        )

        let row = AccessoryKeyRow(
            model: rowModel,
            onKeyTap: { [weak self] key in self?.onKeyTap?(key) },
            onDismissKeyboard: { [weak self] in self?.onDismissKeyboard?() },
            onSwitchToCompose: { [weak self] in self?.onSwitchToCompose?() }
        )
        let host = UIHostingController(rootView: row)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: topAnchor),
            host.view.bottomAnchor.constraint(equalTo: bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        hostingController = host

        // Pin the trait to the app's effective appearance so the dynamic Bento
        // colors resolve on the right side — works even though the bar lives
        // inside the keyboard hierarchy.
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyAppearance),
            name: .terminalThemeChanged, object: nil)
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    var isCtrlActive: Bool { rowModel.isCtrlActive }

    func toggleCtrl() {
        rowModel.isCtrlActive.toggle()
    }

    func deactivateCtrl() {
        rowModel.isCtrlActive = false
    }

    @objc private func applyAppearance() {
        overrideUserInterfaceStyle = ThemeStore.shared.effectiveIsDark ? .dark : .light
    }
}

/// Ctrl toggle state, observable by the SwiftUI row. Ctrl is a lock — it
/// stays until consumed by a ctrl byte or re-tapped.
final class AccessoryRowModel: ObservableObject {
    @Published var isCtrlActive = false
}

/// One floating glass circle, ComposeBar family — used for the two leading
/// utility buttons. The icon is the glass content: `.glassEffect` applied
/// after `.frame`, never as an overlay sibling.
private struct GlassKeyButton: View {
    var systemName: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.bentoInk)
                .frame(width: 40, height: 40)
                .modifier(GlassChrome(shape: .circle))
        }
        .buttonStyle(.plain)
    }
}

/// The bar's content. Left to right: two INDEPENDENT glass circles (dismiss
/// keyboard, switch to the compose box), then ONE glass capsule holding every
/// key as a plain native-style button — no per-key styling of our own. The
/// circles deliberately sit outside the capsule (not fused), per the design.
struct AccessoryKeyRow: View {
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
        // Top-aligned inside the (shorter) bar frame: the 40pt row hangs
        // 12pt below the bar's bottom edge, into the keyboard's top inset.
        VStack(spacing: 0) {
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
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
            }
            .frame(height: 40)
            .clipShape(Capsule())
            .modifier(GlassChrome(shape: .capsule))

                // Paste is its own standalone button at the far right (not
                // buried in the scrollable capsule).
                GlassKeyButton(systemName: "doc.on.clipboard") {
                    onKeyTap(.paste)
                }
            }
            .padding(.horizontal, 12)

            Spacer(minLength: 0)
        }
    }
}
