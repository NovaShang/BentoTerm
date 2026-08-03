import SwiftUI

extension Color {
    /// Build a SwiftUI Color from a 0xRRGGBB literal — one shared source for
    /// the `PaneState` palette hexes used by the sidebar wash and the legend.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
