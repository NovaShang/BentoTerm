import CoreGraphics
import BentoFoundationKit

#if canImport(AppKit)
import AppKit
public typealias PaneChromeColor = NSColor
#elseif canImport(UIKit)
import UIKit
public typealias PaneChromeColor = UIColor
#endif

/// The pane title bar's band and ink.
///
/// One algorithm for both platforms (2026-08-07, user decision: the macOS
/// treatment wins). The band is an independent strip whose darkness follows the
/// app's light/dark, tinted by the pane's state accent and strengthened on the
/// focused pane. iOS previously derived the band from the terminal's *reported*
/// background instead, so the same pane wore different chrome on each device
/// and a TUI repainting its background moved the strip with it.
///
/// Colors are computed in sRGB, so they land the same regardless of the display
/// or the source color's space, and they're concrete snapshots — a light/dark
/// flip must recompute them (both hosts have a recolor pass for exactly this).
/// (MainActor because the appearance it reads from `ThemeStore` is; every
/// caller is a view repainting itself.)
@MainActor
public enum PaneChromeColors {

    /// The light/dark the chrome should paint for. Read once per recolor pass.
    /// Follows the app's appearance setting, not the trait environment, so the
    /// terminal chrome matches the terminal.
    public static var isDark: Bool { ThemeStore.shared.effectiveIsDark }

    /// Title-bar band for a state accent (nil = idle → neutral). Active panes
    /// get a brighter/heavier band so focus reads within one state color. Dark
    /// mode = dark band; light mode = light band, with colored accents tinted
    /// to match.
    public static func titleBand(accent: PaneChromeColor?, active: Bool) -> PaneChromeColor {
        guard let a = accent else {
            return isDark ? PaneChromeColor(white: active ? 0.16 : 0.12, alpha: 1)
                          : PaneChromeColor(white: active ? 0.86 : 0.92, alpha: 1)
        }
        return isDark ? a.paneChromeDarkened(to: active ? 0.30 : 0.17)
                      : a.paneChromeLightened(to: active ? 0.74 : 0.86)
    }

    /// Label / button ink over the band: muted when inactive, a tint of the
    /// accent when active. Light text on the dark band; dark text on the light
    /// band.
    public static func ink(accent: PaneChromeColor?, active: Bool) -> PaneChromeColor {
        if isDark {
            guard active else { return PaneChromeColor(white: 0.62, alpha: 1) }
            guard let a = accent else { return PaneChromeColor(white: 0.95, alpha: 1) }
            return a.paneChromeMixed(with: .paneChromeWhite, fraction: 0.45)
        } else {
            guard active else { return PaneChromeColor(white: 0.42, alpha: 1) }
            guard let a = accent else { return PaneChromeColor(white: 0.16, alpha: 1) }
            return a.paneChromeMixed(with: .paneChromeBlack, fraction: 0.55)
        }
    }

    /// Neutral hairline for a pane's border before chrome is computed, and for
    /// the unfocused panes' frame.
    public static func neutralHairline() -> PaneChromeColor {
        isDark ? PaneChromeColor(white: 1, alpha: 0.10) : PaneChromeColor(white: 0, alpha: 0.14)
    }

    /// The near-invisible frame an unfocused pane wears. The focused pane's
    /// border uses the platform's accent instead — that one color is the one
    /// piece of this the hosts still source themselves (macOS window highlight
    /// vs. the iOS view tint).
    public static func idleBorder() -> PaneChromeColor {
        isDark ? PaneChromeColor(white: 1, alpha: 0.06) : PaneChromeColor(white: 0, alpha: 0.09)
    }
}

private extension PaneChromeColor {
    static var paneChromeWhite: PaneChromeColor { PaneChromeColor(white: 1, alpha: 1) }
    static var paneChromeBlack: PaneChromeColor { PaneChromeColor(white: 0, alpha: 1) }

    /// This color's sRGB components. NSColor must be converted first (a catalog
    /// or pattern color has no components); UIColor already answers in RGB.
    var paneChromeRGBA: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        #if canImport(AppKit)
        let c = usingColorSpace(.sRGB) ?? .white
        return (c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
        #endif
    }

    static func paneChromeSRGB(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> PaneChromeColor {
        #if canImport(AppKit)
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
        #else
        return UIColor(red: r, green: g, blue: b, alpha: a)
        #endif
    }

    /// Multiply RGB toward black by `factor` (0…1), preserving alpha.
    func paneChromeDarkened(to factor: CGFloat) -> PaneChromeColor {
        let c = paneChromeRGBA
        return Self.paneChromeSRGB(c.r * factor, c.g * factor, c.b * factor, c.a)
    }

    /// Mix RGB toward white by `amount` (0…1) — the light-mode analog of
    /// `paneChromeDarkened`, for tinting a colored band on a light surface.
    func paneChromeLightened(to amount: CGFloat) -> PaneChromeColor {
        let c = paneChromeRGBA
        return Self.paneChromeSRGB(c.r + (1 - c.r) * amount,
                                   c.g + (1 - c.g) * amount,
                                   c.b + (1 - c.b) * amount, c.a)
    }

    /// Blend `fraction` of `other` into this color (AppKit's
    /// `blended(withFraction:of:)`, spelled once for both platforms).
    func paneChromeMixed(with other: PaneChromeColor, fraction f: CGFloat) -> PaneChromeColor {
        let a = paneChromeRGBA, b = other.paneChromeRGBA
        return Self.paneChromeSRGB(a.r + (b.r - a.r) * f,
                                   a.g + (b.g - a.g) * f,
                                   a.b + (b.b - a.b) * f, a.a)
    }
}
