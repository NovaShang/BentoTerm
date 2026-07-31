import UIKit
import BentoTerminalCore

// `TerminalColorTheme`, `ThemeStore`, `fromITermColors`, and the
// `.terminalThemeChanged` / `.terminalFontChanged` notifications now live in the
// shared `BentoTerminalCore` package (so macOS + iOS use one store and schema).
// Only the iOS-only UIKit color helpers remain here.

extension TerminalColorTheme {
    var bgColor: UIColor { UIColor(hex: bg) }
    var fgColor: UIColor { UIColor(hex: fg) }
    var cursorColor: UIColor { UIColor(hex: cursor) }
}
