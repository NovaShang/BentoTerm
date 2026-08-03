import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// View-facing color/tint language for `PaneState` (the enum lives in this
// module with the detection domain that produces it). Platform-specific
// NSColor/UIColor members are guarded per platform.

public extension PaneState {
    /// The canonical state palette as 0xRRGGBB — ONE source of truth for every
    /// surface (Tiled pane chrome, List window rows, iOS dots). `doneUnseenHex`
    /// (blue) isn't a PaneState case — an agent that finished its turn while
    /// unfocused — but it lives here with the rest so nothing re-hardcodes it.
    static var workingHex: UInt32    { 0x0A85FF }   // blue  — in progress / active
    static var idleHex: UInt32       { 0x8E8E93 }   // gray
    static var awaitingHex: UInt32   { 0xFF9F0A }   // amber — needs input
    static var doneUnseenHex: UInt32 { 0x30D158 }   // green — finished (✓ success)

    /// Status-dot color as 0xRRGGBB (working blue / idle gray / awaiting amber).
    var dotColorHex: UInt32 {
        switch self {
        case .working:       return Self.workingHex
        case .idle:          return Self.idleHex
        case .awaitingInput: return Self.awaitingHex
        }
    }

    #if canImport(AppKit)
    static func nsColor(hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
    var nsColor: NSColor { Self.nsColor(hex: dotColorHex) }
    #elseif canImport(UIKit)
    static func uiColor(hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
    var uiColor: UIColor { Self.uiColor(hex: dotColorHex) }
    #endif

    /// Alpha for the translucent state wash overlaid on the whole pane (over the
    /// terminal surface), so a pane's state reads from across the room — not just
    /// from the title-bar dot. Idle = 0 (neutral, no wash) so only attention
    /// states stand out; awaiting gets the strongest tint. One source of truth
    /// for both platforms, mirroring `dotColorHex`.
    var tintAlpha: CGFloat {
        switch self {
        case .idle:          return 0
        case .working:       return 0.05
        case .awaitingInput: return 0.12
        }
    }

    #if canImport(AppKit)
    /// Translucent wash color for this state, or nil when it should show no tint.
    var tintNSColor: NSColor? {
        tintAlpha > 0 ? nsColor.withAlphaComponent(tintAlpha) : nil
    }
    #elseif canImport(UIKit)
    var tintUIColor: UIColor? {
        tintAlpha > 0 ? uiColor.withAlphaComponent(tintAlpha) : nil
    }
    #endif

    /// Accent color (0xRRGGBB) for pane *chrome* — the title-bar band and the
    /// border — when the state should stand out. nil for idle = neutral chrome.
    /// Working/awaiting reuse the dot's blue/amber; "done, unseen" (green) isn't
    /// a PaneState, so the view layers that color on itself. One source of truth
    /// for both platforms, alongside `dotColorHex` / `tintAlpha`.
    var chromeAccentHex: UInt32? {
        switch self {
        case .working:       return Self.workingHex
        case .awaitingInput: return Self.awaitingHex
        case .idle:          return nil
        }
    }

    #if canImport(AppKit)
    var chromeAccentNSColor: NSColor? {
        chromeAccentHex.map {
            NSColor(srgbRed: CGFloat(($0 >> 16) & 0xFF) / 255,
                    green: CGFloat(($0 >> 8) & 0xFF) / 255,
                    blue: CGFloat($0 & 0xFF) / 255, alpha: 1)
        }
    }
    #elseif canImport(UIKit)
    var chromeAccentUIColor: UIColor? {
        chromeAccentHex.map {
            UIColor(red: CGFloat(($0 >> 16) & 0xFF) / 255,
                    green: CGFloat(($0 >> 8) & 0xFF) / 255,
                    blue: CGFloat($0 & 0xFF) / 255, alpha: 1)
        }
    }
    #endif
}
