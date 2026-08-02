import Foundation

/// Wire encoding for the mouse reports a terminal sends to a program that asked
/// for mouse tracking (an alt-screen TUI: Claude Code's fullscreen mode, vim,
/// htop, less…).
///
/// This lives apart from either surface because both platforms send the same
/// bytes and must keep sending the same bytes. macOS had the only copy, written
/// against real programs; iOS grew a second one for touch-scroll that handled
/// wheel notches and nothing else. Two copies of a protocol drift — and a drift
/// here is invisible until a TUI mysteriously ignores half the input.
public enum MouseReport {
    /// `button`: 0 = left, 1 = middle, 2 = right, 64 = wheel-up, 65 = wheel-down.
    /// `col`/`row` are 1-based cell coordinates. `mods` carries the xterm
    /// modifier bits (shift 4, alt 8, ctrl 16) — a touch has no modifier keys,
    /// so the iOS caller passes 0. `motion` marks a drag (adds 32).
    ///
    /// SGR (mode 1006) is the mode any modern program negotiates and the only
    /// one that can express coordinates past 223 or say WHICH button was
    /// released. Legacy X10 is the fallback for programs that never asked.
    public static func encode(button: Int, press: Bool, col: Int, row: Int,
                              mods: Int = 0, motion: Bool = false,
                              sgr: Bool) -> Data {
        if sgr {
            let b = button + mods + (motion ? 32 : 0)
            return Data("\u{1b}[<\(b);\(col);\(row)\(press ? "M" : "m")".utf8)
        }
        // ESC [ M (b+32) (col+32) (row+32). X10 has no room to name the button
        // that came up, so every release reports 3 — programs track which button
        // is down themselves. Coordinates clamp at 223: the field is one byte.
        let base = press ? button : 3
        let b = base + mods + (motion ? 32 : 0)
        return Data([
            0x1b, 0x5b, 0x4d,
            UInt8(clamping: b + 32),
            UInt8(clamping: min(col, 223) + 32),
            UInt8(clamping: min(row, 223) + 32),
        ])
    }
}
