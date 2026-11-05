import UIKit
import SwiftUI
import BentoSessionKit
import BentoFoundationKit

// MARK: - Design Tokens

/// The terminal-side design tokens: the pre-report terminal background and the
/// terminal font the chrome beside it should match. Pane state colors live in
/// the shared `PaneState` palette / `PaneChromeColors`; app chrome uses the
/// system semantic colors (`BentoBrand`).
enum STTheme {

    // MARK: - Terminal Palettes

    /// Dark terminal theme — bento brand palette (icon prompt cell as
    /// pane background; emerald/salmon for state).
    enum TermDark {
        static let bg = UIColor(hex: 0x0D0F13)   // bentoInset
    }

    /// Light terminal theme — warm paper
    enum TermLight {
        static let bg = UIColor.white
    }

    // MARK: - Appearance-Adaptive Helpers

    /// Whether the current trait collection is light mode
    static var isLight: Bool {
        UITraitCollection.current.userInterfaceStyle == .light
    }

    /// The terminal's default background by appearance — the fallback until the
    /// engine's real reported bg arrives, and the pre-report pane tint.
    static var term: UIColor {
        isLight ? TermLight.bg : TermDark.bg
    }

    // MARK: - Fonts

    /// Terminal font size — a CGFloat view onto `ThemeStore.fontSize`, which
    /// owns the stored value, the post-unlock cache, and the fallback.
    ///
    /// It must NOT re-derive any of those. This used to hold its own cache and
    /// its own fallback (10) while the engine's app-wide config reload read
    /// ThemeStore's (iPhone 12 / iPad 14) — surfaces were created at one size
    /// and every live surface was pushed to the other, so a pane opened after
    /// an app-switch didn't match the panes beside it.
    static var terminalFontSize: CGFloat { CGFloat(ThemeStore.fontSize) }

    /// User-selected terminal font for the CHROME beside the terminal, matching
    /// what the surface renders inside it.
    ///
    /// The family comes from `ThemeStore.ghosttyFontFamily` — the very answer
    /// the engine is configured with — so the chrome and the terminal can't
    /// disagree about which font was picked. (This used to keep its own token
    /// table, which defaulted to Maple while the engine defaulted to its
    /// built-in face, and didn't know "jetbrains".) nil means the engine's
    /// built-in default, which isn't a font UIKit can load, so the system
    /// monospace stands in.
    static var terminalFont: UIFont {
        let size = terminalFontSize
        let token = ThemeStore.storedFontFamilyToken
        guard let family = ThemeStore.ghosttyFontFamily(forToken: token) else {
            return .monospacedSystemFont(
                ofSize: size, weight: token == "system-medium" ? .medium : .regular)
        }
        switch family {
        case "Maple Mono NF CN":
            return UIFont(name: "MapleMono-NF-CN-Regular", size: size)
                ?? namedFont(family: family, size: size)
        case "Courier New":
            return UIFont(name: "CourierNewPSMT", size: size)
                ?? namedFont(family: family, size: size)
        default:
            return namedFont(family: family, size: size)
        }
    }

    /// Resolve a FAMILY name (what the picker stores) to a face.
    ///
    /// `UIFont(name:)` wants a PostScript name, so it only answers for families
    /// whose regular face shares the family name. `UIFont(descriptor:size:)`
    /// always returns something — it silently substitutes the system font for a
    /// family that isn't installed — so the result is checked before it is
    /// trusted, and an uninstalled font falls back to the system monospace
    /// rather than to a proportional one.
    private static func namedFont(family: String, size: CGFloat) -> UIFont {
        if let exact = UIFont(name: family, size: size) { return exact }
        let candidate = UIFont(
            descriptor: UIFontDescriptor(fontAttributes: [.family: family]), size: size)
        return candidate.familyName == family
            ? candidate
            : .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

// MARK: - UIColor helpers

extension UIColor {
    /// A trait-reactive color that resolves to `light` or `dark` based on the
    /// rendering view's interface style. Bridged into SwiftUI as `Color(_:)`,
    /// these flip automatically when the app's appearance changes — no manual
    /// re-theming of SwiftUI chrome needed.
    static func bentoDynamic(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }
}

// MARK: - Bento Brand Tokens
//
// Palette pulled directly from docs/bento-icon.svg — cold IDE-grey shell
// holding warm content cells (emerald prompt, salmon, rice-white, veg-green).
// No invented colors. Chrome stays GUI-clean; mono is reserved for places
// where monospace is literally true (host strings, terminal contents).

enum BentoBrand {
    // 2026-08-11: these used to be a warm "bento box" palette — rice-paper
    // light mode, emerald tint, hand-picked greys. That was right for the
    // earlier, friendlier product; Term is a tool now, so the chrome resolves
    // to the system's own semantic colours and the app looks like iOS instead
    // of like a brand. The NAMES stay (they have ~125 call sites); what changed
    // is what they resolve to, so light/dark, contrast settings and future OS
    // revisions come for free.
    static let shell      = UIColor.systemGroupedBackground            // app bg
    static let surface    = UIColor.secondarySystemGroupedBackground   // rows / cards
    static let surfaceHi  = UIColor.tertiarySystemGroupedBackground    // pressed / chip
    static let inset      = UIColor.secondarySystemBackground          // recessed
    static let border     = UIColor.separator
    static let borderHi   = UIColor.opaqueSeparator

    static let inkPrimary   = UIColor.label
    static let inkSecondary = UIColor.secondaryLabel
    static let inkMuted     = UIColor.tertiaryLabel

    // Meaning, not decoration: green reads "running / connected", orange
    // "waiting on you", red "failed" — the same vocabulary the pane state
    // colours use. System colours so they track accessibility settings.
    static let emerald = UIColor.systemGreen
    static let salmon  = UIColor.systemOrange
    static let red     = UIColor.systemRed

    // The app mark keeps the brand palette: a logo is the one place a product
    // is allowed to have its own colours, and it should not shift with the OS.
    static let markEmerald = UIColor(hex: 0x4ADE80)
    static let rice        = UIColor(hex: 0xF0EAD8)
    static let veg         = UIColor(hex: 0x6FA254)
    static let vegDeep     = UIColor(hex: 0x4D7C3F)
}

/// Call once at app launch to harmonize UIKit-backed surfaces (nav bars,
/// tab bars, table sections) with the bento palette. SwiftUI alone can't
/// reach grouped-list section headers and inset table backgrounds, so we
/// drive them through UIAppearance.
@MainActor
enum BentoAppearance {
    /// Nearly nothing now. This used to repaint nav bars, toolbars, table
    /// backgrounds and cells with the bento palette; all of that is gone, so
    /// UIKit draws its own chrome. What remains is a correctness fix, not a
    /// look: the keyboard follows the active interface style instead of being
    /// pinned dark.
    static func install() {
        UITextField.appearance().keyboardAppearance = .default
        // UIKit's own tint, which SwiftUI's `.tint(...)` does not set.
        //
        // A sheet is a UIKit presentation: SwiftUI draws its content with the
        // environment tint, then UIKit re-tints the hosting view with the
        // WINDOW's tint once the presentation settles — system blue unless
        // told otherwise. That is exactly the symptom: Settings icons came up
        // green and turned blue a moment later. The old code happened to avoid
        // it by forcing `UINavigationBar.appearance().tintColor`; that went
        // with the rest of the palette overrides, so set the window's tint
        // instead — one place, and both layers now agree.
        UIWindow.appearance().tintColor = BentoBrand.emerald
    }
}

// MARK: - Reusable view modifiers

extension View {
    /// One background across a whole sheet — including the parts of it that
    /// are not a `Form`, which would otherwise fall back to a different system
    /// colour and show as a slab behind the top of the page.
    ///
    /// The tint is restated here rather than relied on from the root: sheets
    /// are their own presentation, and this modifier is what every sheet in the
    /// app wears — so the green accent can't be one `.sheet` away from being
    /// system blue again.
    func bentoForm() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Color.bentoShell.ignoresSafeArea())
            .tint(Color.bentoEmerald)
    }

    /// Apply to a `Section` (or individual rows) so the row sits on the
    /// bento surface card instead of iOS system grouped white.
    func bentoFormRow() -> some View {
        self.listRowBackground(Color.bentoSurface)
    }

    /// Apply on a `Form` `Section`: rows render on the bento surface with
    /// subtle separators in bento border color. Uses native iOS grouped
    /// styling (rows joined into a section panel) — the design language
    /// is "native iOS chrome, recolored to bento", not custom cards.
    func bentoSectionStyle() -> some View {
        self
            .listRowBackground(Color.bentoSurface)
            .listRowSeparatorTint(Color.bentoBorder)
    }

    /// Big primary CTA (emerald fill, black ink). Used for "Get started",
    /// "Launch", etc.
    func bentoPrimaryButton() -> some View {
        self.buttonStyle(BentoPrimaryButtonStyle())
    }

    /// Outlined secondary CTA (bento surface fill, ink text, subtle border).
    func bentoSecondaryButton() -> some View {
        self.buttonStyle(BentoSecondaryButtonStyle())
    }
}

struct BentoPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.bentoEmerald)
                    .opacity(configuration.isPressed ? 0.85 : 1.0)
            )
    }
}

struct BentoSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.bentoInk)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.bentoSurface)
                    .opacity(configuration.isPressed ? 0.7 : 1.0)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.bentoBorder, lineWidth: 1)
            )
    }
}

extension Color {
    static let bentoShell      = Color(BentoBrand.shell)
    static let bentoSurface    = Color(BentoBrand.surface)
    static let bentoSurfaceHi  = Color(BentoBrand.surfaceHi)
    static let bentoInset      = Color(BentoBrand.inset)
    static let bentoBorder     = Color(BentoBrand.border)
    static let bentoBorderHi   = Color(BentoBrand.borderHi)
    static let bentoInk        = Color(BentoBrand.inkPrimary)
    static let bentoInkDim     = Color(BentoBrand.inkSecondary)
    static let bentoInkMute    = Color(BentoBrand.inkMuted)
    static let bentoEmerald    = Color(BentoBrand.emerald)
    static let bentoSalmon     = Color(BentoBrand.salmon)
    static let bentoRice       = Color(BentoBrand.rice)
    static let bentoMarkGreen  = Color(BentoBrand.markEmerald)
    static let bentoVeg        = Color(BentoBrand.veg)
    static let bentoVegDeep    = Color(BentoBrand.vegDeep)
    static let bentoRed        = Color(BentoBrand.red)
}
