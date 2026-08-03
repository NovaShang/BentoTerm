import Foundation

/// Terminal text geometry: display-width (wcwidth-style) cell accounting and
/// soft-wrap row math. Shared by PathDetection (preview hit-testing) and
/// scrollback row math, so it lives in the foundation layer both can depend on.
public enum TerminalGeometry {
    /// Visual rows a logical line occupies when soft-wrapped at `cols` columns,
    /// using terminal display width (CJK / fullwidth / emoji = 2 cells). `cols<=0`
    /// → 1 (width unknown, or nothing to wrap).
    public static func visualRows(_ line: String, cols: Int) -> Int {
        guard cols > 0 else { return 1 }
        let cells = displayCells(line)
        return max(1, (cells + cols - 1) / cols)
    }

    /// Terminal display width of `line` in cells (wcwidth-style approximation).
    public static func displayCells(_ line: String) -> Int {
        var cells = 0
        for u in line.unicodeScalars { cells += scalarCells(u.value) }
        return cells
    }

    public static func scalarCells(_ v: UInt32) -> Int {
        if v == 0 { return 0 }
        // Combining marks / zero-width joiners & spaces / variation selectors
        // (VS15/VS16 select emoji vs. text presentation — they don't occupy
        // cells themselves, so "❤️" must not count U+FE0F as an extra cell).
        if (0x0300...0x036F).contains(v) || (0x200B...0x200F).contains(v) || v == 0xFEFF ||
           v == 0xFE0E || v == 0xFE0F { return 0 }
        // East Asian Wide / Fullwidth + emoji → 2 cells.
        if (0x1100...0x115F).contains(v) || (0x2E80...0x303E).contains(v) ||
           (0x3041...0x33FF).contains(v) || (0x3400...0x4DBF).contains(v) ||
           (0x4E00...0x9FFF).contains(v) || (0xA000...0xA4CF).contains(v) ||
           (0xAC00...0xD7A3).contains(v) || (0xF900...0xFAFF).contains(v) ||
           (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFF60).contains(v) ||
           (0xFFE0...0xFFE6).contains(v) || (0x1F300...0x1FAFF).contains(v) ||
           (0x20000...0x3FFFD).contains(v) {
            return 2
        }
        return 1
    }
}
