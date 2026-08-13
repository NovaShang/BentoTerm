import UIKit
import SwiftUI
import BentoAgentKit
import BentoSessionKit
import BentoFoundationKit

// MARK: - Design Tokens

/// Centralized design tokens matching the Bento design prototype.
/// iOS system color palette + terminal dark/light themes.
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

    // MARK: - Chrome Palettes (iOS System Colors)

    enum ChromeDark {
        static let app        = UIColor.black
        static let surface    = UIColor(hex: 0x1C1C1E)
        static let surface2   = UIColor(hex: 0x2C2C2E)
        static let grouped    = UIColor.black
        static let groupedSec = UIColor(hex: 0x1C1C1E)
        static let line       = UIColor(red: 84/255, green: 84/255, blue: 88/255, alpha: 0.65)
        static let lineO      = UIColor(red: 84/255, green: 84/255, blue: 88/255, alpha: 0.35)
        static let ink        = UIColor.white
        static let inkDim     = UIColor(red: 235/255, green: 235/255, blue: 245/255, alpha: 0.6)
        static let inkMute    = UIColor(red: 235/255, green: 235/255, blue: 245/255, alpha: 0.3)
        static let accent     = UIColor(hex: 0x0A84FF)
        static let amber      = UIColor(hex: 0xFF9F0A)
        static let green      = UIColor(hex: 0x30D158)
        static let red        = UIColor(hex: 0xFF453A)
    }

    enum ChromeLight {
        static let app        = UIColor(hex: 0xF2F2F7)
        static let surface    = UIColor.white
        static let surface2   = UIColor(hex: 0xF2F2F7)
        static let grouped    = UIColor(hex: 0xF2F2F7)
        static let groupedSec = UIColor.white
        static let line       = UIColor(red: 60/255, green: 60/255, blue: 67/255, alpha: 0.29)
        static let lineO      = UIColor(red: 60/255, green: 60/255, blue: 67/255, alpha: 0.12)
        static let ink        = UIColor.black
        static let inkDim     = UIColor(red: 60/255, green: 60/255, blue: 67/255, alpha: 0.6)
        static let inkMute    = UIColor(red: 60/255, green: 60/255, blue: 67/255, alpha: 0.3)
        static let accent     = UIColor(hex: 0x007AFF)
        static let amber      = UIColor(hex: 0xFF9500)
        static let green      = UIColor(hex: 0x34C759)
        static let red        = UIColor(hex: 0xFF3B30)
    }

    // MARK: - Pane State Visuals

    /// State dot colors (consistent across light/dark). `dotWorking` is sourced
    /// from the shared `PaneState` palette so the green↔blue swap stays global.
    static let dotWorking  = PaneState.uiColor(hex: PaneState.workingHex)
    static let dotIdle     = UIColor.systemGray
    static let dotAwaiting = UIColor(hex: 0xFF9F0A)

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

    // MARK: - Background-fused chrome
    //
    // Status chrome that emerges from the terminal's REAL background instead of
    // sitting on top as an independent colored strip. `bg` is the engine's
    // reported background (initial resolution / config reload / OSC 11), so the
    // band is always harmonious with whatever theme or program is running.

    // (The title BAND used to be fused from `bg` here too. 2026-08-07 it moved to
    // the shared `PaneChromeColors`, which is the macOS treatment: an
    // appearance-driven strip, not one cut from the terminal's own color.)

    /// The pane surround / reserved-band color: the terminal bg FUSED with the
    /// pane's running state — the old per-state pane background (bgWorking /
    /// bgAwait), now derived from the live terminal bg instead of a hardcoded
    /// hex. Idle = the plain bg (full fusion). Done-unseen (green ✓) has no
    /// PaneState case, so it layers on like the title bar does.
    ///
    /// The overlay is applied with the SAME alpha the surface wash uses
    /// (`PaneState.tintAlpha`; done-unseen 0.10 as the macOS wash) so the band
    /// and an empty washed terminal read as ONE color — not a darker cousin.
    static func fusedBackground(bg: UIColor, state: PaneState, doneUnseen: Bool) -> UIColor {
        if doneUnseen {
            return bg.mixed(with: PaneState.uiColor(hex: PaneState.doneUnseenHex), 0.10)
        }
        let alpha = state.tintAlpha   // 0 idle / 0.05 working / 0.12 awaiting
        guard alpha > 0 else { return bg }
        return bg.mixed(with: state.uiColor, alpha)
    }

    /// Dot color for pane state
    static func dotColor(for state: PaneState) -> UIColor {
        switch state {
        case .working:       return dotWorking
        case .idle:          return dotIdle
        case .awaitingInput: return dotAwaiting
        }
    }

    // MARK: - Glass Pill Style

    /// Glass pill background for dark chrome
    static let glassDark = UIColor(red: 120/255, green: 120/255, blue: 128/255, alpha: 0.32)

    // MARK: - Fonts

    static let mono = UIFont.monospacedSystemFont(ofSize: 11, weight: .medium)
    static let sans = UIFont.systemFont(ofSize: 14, weight: .regular)
    static let display = UIFont.systemFont(ofSize: 34, weight: .bold)

    /// Last non-zero font size this process read from defaults. UserDefaults
    /// can transiently read EMPTY right after unlocking the device (the prefs
    /// plist is protected until first read post-unlock, and the resume rebuild
    /// races that window) — surfaces rebuilt in that window picked up the
    /// device fallback and the terminal "grew" from 10pt to 14pt until the
    /// user touched the slider again. The cache answers with the real value.
    private nonisolated(unsafe) static var lastKnownFontSize: CGFloat = 0

    /// Terminal font size — reads from Settings slider, falls back to the last
    /// value this process saw, then to the iOS default (10).
    static var terminalFontSize: CGFloat {
        let stored = UserDefaults.standard.double(forKey: "terminal_font_size")
        if stored > 0 {
            lastKnownFontSize = CGFloat(stored)
            return CGFloat(stored)
        }
        if lastKnownFontSize > 0 { return lastKnownFontSize }
        return 10
    }

    /// User-selected terminal font for the CHROME beside the terminal, matching
    /// what the surface renders inside it.
    ///
    /// The stored value is a real family name now (the picker enumerates every
    /// monospaced family on the device); the legacy token cases stay because an
    /// install that hasn't opened the Appearance panel since the change still
    /// holds one, and they resolve to the same faces they always did. Anything
    /// else is passed to `UIFont(name:)` as a family, with the system monospace
    /// as the last resort — the same shape as
    /// `ThemeStore.ghosttyFontFamily`, so the chrome and the terminal can't
    /// disagree about which font was picked.
    static var terminalFont: UIFont {
        let size = terminalFontSize
        let family = UserDefaults.standard.string(forKey: "terminal_font_family") ?? "Maple Mono NF CN"
        switch family {
        case "maple-nf-cn", "Maple Mono NF CN":
            return UIFont(name: "MapleMono-NF-CN-Regular", size: size)
                ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        case "menlo":
            return UIFont(name: "Menlo-Regular", size: size)
                ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        case "courier":
            return UIFont(name: "CourierNewPSMT", size: size)
                ?? UIFont(name: "Courier", size: size)
                ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        case "sf-mono", "system", "system-medium":
            return UIFont.monospacedSystemFont(
                ofSize: size, weight: family == "system-medium" ? .medium : .regular)
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

// MARK: - UIColor Hex Initializer

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// A trait-reactive color that resolves to `light` or `dark` based on the
    /// rendering view's interface style. Bridged into SwiftUI as `Color(_:)`,
    /// these flip automatically when the app's appearance changes — no manual
    /// re-theming of SwiftUI chrome needed.
    static func bentoDynamic(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }

    /// Linear blend toward `other` by `t` (0…1), used to lighten the accent into
    /// readable ink over the dark band.
    func mixed(with other: UIColor, _ t: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t,
                       blue: b1 + (b2 - b1) * t, alpha: a1 + (a2 - a1) * t)
    }

    /// Relative luminance (Rec. 709), 0…1. Used to pick ink / band treatment
    /// from a background color the UI trait can't describe — a TUI or shell may
    /// repaint the terminal bg at runtime (OSC 11), so `isLight` would be wrong.
    var luminance: CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
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

// MARK: - SwiftUI Color Bridges
//
// Trait-reactive: each bridges the ChromeLight/ChromeDark (or TermLight/TermDark)
// pair through a dynamic UIColor so SwiftUI views recolor on an appearance flip.

private func stDyn(_ light: UIColor, _ dark: UIColor) -> Color {
    Color(UIColor.bentoDynamic(light: light, dark: dark))
}

extension Color {
    static let stAccent   = stDyn(STTheme.ChromeLight.accent,   STTheme.ChromeDark.accent)
    static let stAmber    = stDyn(STTheme.ChromeLight.amber,    STTheme.ChromeDark.amber)
    static let stGreen    = stDyn(STTheme.ChromeLight.green,    STTheme.ChromeDark.green)
    static let stRed      = stDyn(STTheme.ChromeLight.red,      STTheme.ChromeDark.red)
    static let stInk      = stDyn(STTheme.ChromeLight.ink,      STTheme.ChromeDark.ink)
    static let stInkDim   = stDyn(STTheme.ChromeLight.inkDim,   STTheme.ChromeDark.inkDim)
    static let stInkMute  = stDyn(STTheme.ChromeLight.inkMute,  STTheme.ChromeDark.inkMute)
    static let stSurface  = stDyn(STTheme.ChromeLight.surface,  STTheme.ChromeDark.surface)
    static let stSurface2 = stDyn(STTheme.ChromeLight.surface2, STTheme.ChromeDark.surface2)
    static let stLine     = stDyn(STTheme.ChromeLight.line,     STTheme.ChromeDark.line)
    static let stLineO    = stDyn(STTheme.ChromeLight.lineO,    STTheme.ChromeDark.lineO)
}
