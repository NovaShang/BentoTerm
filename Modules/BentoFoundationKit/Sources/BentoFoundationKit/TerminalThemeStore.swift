import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// A terminal color scheme — background, foreground, cursor, and the 16 ANSI
/// colors, as 24-bit `0xRRGGBB`. Shared by iOS + macOS (one source of truth).
/// Platform UIColor/NSColor helpers live in the app targets.
public struct TerminalColorTheme: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let isDark: Bool
    public let bg: UInt32
    public let fg: UInt32
    public let cursor: UInt32
    /// 16 ANSI colors: indices 0-7 normal, 8-15 bright.
    public let ansi: [UInt32]

    public init(id: String, name: String, isDark: Bool, bg: UInt32, fg: UInt32, cursor: UInt32, ansi: [UInt32]) {
        self.id = id; self.name = name; self.isDark = isDark
        self.bg = bg; self.fg = fg; self.cursor = cursor; self.ansi = ansi
    }

    // Lenient decoder — defaults every field so a saved custom theme survives
    // future schema additions.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        self.name = (try? c.decode(String.self, forKey: .name)) ?? "Untitled"
        self.isDark = (try? c.decode(Bool.self, forKey: .isDark)) ?? true
        self.bg = (try? c.decode(UInt32.self, forKey: .bg)) ?? 0x000000
        self.fg = (try? c.decode(UInt32.self, forKey: .fg)) ?? 0xFFFFFF
        self.cursor = (try? c.decode(UInt32.self, forKey: .cursor)) ?? 0xFFFFFF
        // The ghostty consumer writes exactly 16 entries (0-7 normal, 8-15
        // bright); a corrupt/short palette would silently render a truncated
        // ansi table, so anything but 16 falls back to the default.
        let ansi = (try? c.decode([UInt32].self, forKey: .ansi)) ?? []
        self.ansi = ansi.count == 16 ? ansi : TerminalColorTheme.defaultAnsi
    }
}

public extension TerminalColorTheme {
    /// Sentinel ID for the system-adaptive DARK theme. Its declared colors are
    /// written to the ghostty config like every other theme's (see
    /// GhosttyRuntime.writeColorConfig) — it once wrote nothing, so ghostty
    /// rendered its built-in dark default (#292C33) while the chrome's fallback
    /// painted this theme's declared bg (0x0F1115) → the dark-mode seam.
    static let systemID = "system"
    /// Sentinel ID for the default LIGHT theme (warm paper, dark ink).
    static let systemLightID = "system-light"

    static let builtIn: [TerminalColorTheme] = [
        TerminalColorTheme(id: systemID, name: "System", isDark: true,
                           bg: 0x0F1115, fg: 0xE6E8EE, cursor: 0xE6E8EE, ansi: defaultAnsi),
        TerminalColorTheme(id: systemLightID, name: "System (Light)", isDark: false,
                           bg: 0xFFFFFF, fg: 0x2E2E2E, cursor: 0x2E2E2E, ansi: lightAnsi),
        TerminalColorTheme(id: "dracula", name: "Dracula", isDark: true,
                           bg: 0x282A36, fg: 0xF8F8F2, cursor: 0xF8F8F2, ansi: [
            0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
            0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF]),
        TerminalColorTheme(id: "solarized-dark", name: "Solarized Dark", isDark: true,
                           bg: 0x002B36, fg: 0x839496, cursor: 0x93A1A1, ansi: [
            0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
            0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3]),
        TerminalColorTheme(id: "solarized-light", name: "Solarized Light", isDark: false,
                           bg: 0xFDF6E3, fg: 0x657B83, cursor: 0x586E75, ansi: [
            0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
            0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3]),
        TerminalColorTheme(id: "tokyo-night", name: "Tokyo Night", isDark: true,
                           bg: 0x1A1B26, fg: 0xC0CAF5, cursor: 0xC0CAF5, ansi: [
            0x15161E, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
            0x414868, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xC0CAF5]),
        TerminalColorTheme(id: "nord", name: "Nord", isDark: true,
                           bg: 0x2E3440, fg: 0xD8DEE9, cursor: 0xD8DEE9, ansi: [
            0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
            0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4]),
        TerminalColorTheme(id: "gruvbox-dark", name: "Gruvbox Dark", isDark: true,
                           bg: 0x282828, fg: 0xEBDBB2, cursor: 0xEBDBB2, ansi: [
            0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
            0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2]),
        TerminalColorTheme(id: "monokai", name: "Monokai", isDark: true,
                           bg: 0x272822, fg: 0xF8F8F2, cursor: 0xF8F8F2, ansi: [
            0x272822, 0xF92672, 0xA6E22E, 0xF4BF75, 0x66D9EF, 0xAE81FF, 0xA1EFE4, 0xF8F8F2,
            0x75715E, 0xF92672, 0xA6E22E, 0xF4BF75, 0x66D9EF, 0xAE81FF, 0xA1EFE4, 0xF9F8F5]),
    ]

    static let defaultAnsi: [UInt32] = [
        0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
        0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF,
    ]

    /// ANSI palette tuned for a light background (Tomorrow light by Chris
    /// Kempson) — saturated/darkened so all 8 colors stay legible on white,
    /// unlike `defaultAnsi`'s bright variants which wash out.
    static let lightAnsi: [UInt32] = [
        0x000000, 0xC82829, 0x718C00, 0xEAB700, 0x4271AE, 0x8959A8, 0x3E999F, 0xFFFFFF,
        0x000000, 0xC82829, 0x718C00, 0xEAB700, 0x4271AE, 0x8959A8, 0x3E999F, 0xFFFFFF,
    ]

    /// Resolve a theme id to a concrete theme: built-ins, then custom themes
    /// saved on disk. An unknown id falls back to the built-in for the slot's
    /// own appearance — a light slot never silently lands on a dark palette.
    static func resolve(id: String, isDark: Bool) -> TerminalColorTheme {
        if let m = builtIn.first(where: { $0.id == id }) { return m }
        if let m = ThemeStore.loadCustomThemes().first(where: { $0.id == id }) { return m }
        return isDark ? builtIn[0]
                      : builtIn.first { $0.id == systemLightID } ?? builtIn[0]
    }

    /// Parse an iTerm2 `.itermcolors` plist into a theme.
    static func fromITermColors(data: Data, name: String) throws -> TerminalColorTheme {
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dict = plist as? [String: [String: Any]] else {
            throw NSError(domain: "iTerm2Theme", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Not a valid .itermcolors file"])
        }
        func hex(_ key: String, _ fallback: UInt32) -> UInt32 {
            guard let e = dict[key] else { return fallback }
            let r = UInt32(max(0, min(1, (e["Red Component"] as? Double) ?? 0)) * 255)
            let g = UInt32(max(0, min(1, (e["Green Component"] as? Double) ?? 0)) * 255)
            let b = UInt32(max(0, min(1, (e["Blue Component"] as? Double) ?? 0)) * 255)
            return (r << 16) | (g << 8) | b
        }
        let bg = hex("Background Color", 0x000000)
        let fg = hex("Foreground Color", 0xCCCCCC)
        let cursor = hex("Cursor Color", fg)
        let ansi = (0..<16).map { hex("Ansi \($0) Color", 0) }
        let r = Double((bg >> 16) & 0xFF), g = Double((bg >> 8) & 0xFF), b = Double(bg & 0xFF)
        let isDark = (0.2126 * r + 0.7152 * g + 0.0722 * b) < 128
        return TerminalColorTheme(id: "imported-" + UUID().uuidString.prefix(8).lowercased(),
                                  name: name, isDark: isDark, bg: bg, fg: fg, cursor: cursor, ansi: ansi)
    }
}

/// Persists the user's terminal theme + font choice and notifies observers.
/// Shared by iOS + macOS so the two clients use one schema and the same
/// UserDefaults keys (a later iCloud KVS layer can wrap these).
@MainActor
public final class ThemeStore: ObservableObject {
    public static let shared = ThemeStore()
    nonisolated private static let customKey = "terminal_custom_themes_v1"

    /// App-wide light/dark appearance. The master switch: it drives both the
    /// SwiftUI/UIKit chrome AND which terminal theme slot (`darkThemeID` /
    /// `lightThemeID`) is active. Default `.system`.
    @Published public var appearanceMode: AppearanceMode {
        didSet {
            guard oldValue != appearanceMode else { return }
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: "appearance_mode")
            NotificationCenter.default.post(name: .appearanceModeChanged, object: nil)
            // The effective terminal theme may have changed too (mode flips which
            // slot is active), so recolor open surfaces.
            NotificationCenter.default.post(name: .terminalThemeChanged, object: nil)
        }
    }

    /// The OS's current light/dark, pushed by each app target when its trait
    /// collection / effective appearance changes (the store can't reliably read
    /// the platform appearance on its own). Only matters when mode == .system.
    @Published public private(set) var systemIsDark: Bool

    /// Terminal theme for dark appearance (the slot edited by the "Dark theme"
    /// picker). Migrated from the legacy single `terminal_theme_id`.
    @Published public var darkThemeID: String {
        didSet {
            guard oldValue != darkThemeID else { return }
            UserDefaults.standard.set(darkThemeID, forKey: "dark_theme_id")
            if effectiveIsDark { NotificationCenter.default.post(name: .terminalThemeChanged, object: nil) }
        }
    }

    /// Terminal theme for light appearance (the "Light theme" picker slot).
    @Published public var lightThemeID: String {
        didSet {
            guard oldValue != lightThemeID else { return }
            UserDefaults.standard.set(lightThemeID, forKey: "light_theme_id")
            if !effectiveIsDark { NotificationCenter.default.post(name: .terminalThemeChanged, object: nil) }
        }
    }

    @Published public var customThemes: [TerminalColorTheme] {
        didSet { saveCustomThemes() }
    }

    public var allThemes: [TerminalColorTheme] { TerminalColorTheme.builtIn + customThemes }

    /// Themes appropriate for one appearance — feeds the per-slot pickers so the
    /// "Light theme" picker only lists light themes (and vice versa).
    public func themes(forDark dark: Bool) -> [TerminalColorTheme] {
        allThemes.filter { $0.isDark == dark }
    }

    /// The resolved light/dark the whole app should render right now.
    public var effectiveIsDark: Bool {
        switch appearanceMode {
        case .dark:   return true
        case .light:  return false
        case .system: return systemIsDark
        }
    }

    /// The active terminal theme, resolved from the appearance + per-slot choice.
    /// Replaces the old stored `current`; setting it routes to the active slot.
    public var current: TerminalColorTheme {
        get { TerminalColorTheme.resolve(id: effectiveIsDark ? darkThemeID : lightThemeID, isDark: effectiveIsDark) }
        set { select(id: newValue.id, forDark: effectiveIsDark) }
    }

    /// Called by app targets when the OS appearance changes (iOS trait change /
    /// macOS effectiveAppearance). Recolors open surfaces if it flips the
    /// effective theme while in follow-system mode.
    public func updateSystemIsDark(_ value: Bool) {
        guard value != systemIsDark else { return }
        let before = effectiveIsDark
        systemIsDark = value
        if before != effectiveIsDark {
            NotificationCenter.default.post(name: .terminalThemeChanged, object: nil)
        }
    }

    /// Detect the platform's current light/dark. Best-effort; defaults to dark.
    public static func detectSystemIsDark() -> Bool {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        if let appearance = NSApp?.effectiveAppearance {
            return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        return true
        #elseif canImport(UIKit)
        return UITraitCollection.current.userInterfaceStyle != .light
        #else
        return true
        #endif
    }

    // MARK: Font prefs (same UserDefaults keys both platforms use)

    /// Last non-zero size this process read from defaults. UserDefaults can
    /// transiently read EMPTY right after device unlock (the prefs plist is
    /// protected until first post-unlock read); a config reload in that window
    /// must answer with the real size, not the fallback, or every live surface
    /// snaps to the wrong font. Mirrors STTheme.terminalFontSize's cache.
    private var lastKnownFontSize: Double = 0

    /// Terminal font size in points. Falls back to the last value this process
    /// saw, then to the platform default — which must match what the app
    /// targets use to CREATE surfaces (iPad 14 / iPhone 12 / mac 13), or a
    /// config reload nudges untouched-slider installs to a different size.
    public var fontSize: Double {
        resolveFontSize(UserDefaults.standard.double(forKey: "terminal_font_size"))
    }

    /// Resolve the persisted size, seeding the unlock-race cache in the
    /// process. UserDefaults can transiently read EMPTY right after device
    /// unlock (the prefs plist is protected until the first post-unlock read);
    /// a config reload in that window must answer with the real size, not the
    /// fallback, or every live surface snaps to the wrong font. Mirrors
    /// STTheme.terminalFontSize's cache. (An explicit method rather than a
    /// side-effectful getter so the mutation is visible at the call site.)
    private func resolveFontSize(_ persisted: Double) -> Double {
        if persisted > 0 {
            lastKnownFontSize = persisted
            return persisted
        }
        if lastKnownFontSize > 0 { return lastKnownFontSize }
        #if canImport(UIKit)
        return UIDevice.current.userInterfaceIdiom == .pad ? 14 : 12
        #else
        return 13
        #endif
    }

    /// Selected font-family token (e.g. "jetbrains"); nil = engine default.
    public var fontFamilyToken: String? {
        UserDefaults.standard.string(forKey: "terminal_font_family")
    }

    /// ghostty font-family name for the selected token, or nil for the default.
    public var ghosttyFontFamily: String? {
        switch fontFamilyToken {
        case "menlo":        return "Menlo"
        case "courier":      return "Courier New"
        case "jetbrains":    return "JetBrains Mono"
        case "maple-nf-cn":  return "Maple Mono NF CN"
        case "sf-mono", "system", "system-medium", nil, "": return nil
        default:             return fontFamilyToken
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        self.appearanceMode = AppearanceMode(rawValue: defaults.string(forKey: "appearance_mode") ?? "") ?? .system
        // Migrate the legacy single theme id into the dark slot (existing installs
        // were dark-only, so their chosen theme is their dark theme).
        let legacy = defaults.string(forKey: "terminal_theme_id")
        self.darkThemeID = defaults.string(forKey: "dark_theme_id") ?? legacy ?? TerminalColorTheme.systemID
        self.lightThemeID = defaults.string(forKey: "light_theme_id") ?? TerminalColorTheme.systemLightID
        self.customThemes = ThemeStore.loadCustomThemes()
        self.systemIsDark = ThemeStore.detectSystemIsDark()
    }

    nonisolated public static func loadCustomThemes() -> [TerminalColorTheme] {
        guard let data = UserDefaults.standard.data(forKey: customKey) else { return [] }
        do {
            return try JSONDecoder().decode([TerminalColorTheme].self, from: data)
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            UserDefaults.standard.set(data, forKey: "\(customKey)_broken_\(stamp)")
            dlog("Failed to decode custom themes: \(error)")
            return []
        }
    }

    private func saveCustomThemes() {
        guard let data = try? JSONEncoder().encode(customThemes) else { return }
        UserDefaults.standard.set(data, forKey: Self.customKey)
    }

    public func addCustomTheme(_ theme: TerminalColorTheme) {
        customThemes.append(theme)
        // Assign the new theme to the slot matching its own light/dark, and switch
        // appearance to show it (so importing a theme has an immediate effect).
        select(id: theme.id, forDark: theme.isDark)
        appearanceMode = theme.isDark ? .dark : .light
    }

    public func removeCustomTheme(_ id: String) {
        customThemes.removeAll { $0.id == id }
        if darkThemeID == id { darkThemeID = TerminalColorTheme.systemID }
        if lightThemeID == id { lightThemeID = TerminalColorTheme.systemLightID }
    }

    /// Set the terminal theme for a specific appearance slot.
    public func select(id: String, forDark dark: Bool) {
        if dark { darkThemeID = id } else { lightThemeID = id }
    }

    /// Set the terminal theme for the currently-effective appearance.
    public func select(id: String) {
        select(id: id, forDark: effectiveIsDark)
    }
}

/// App-wide light/dark preference. `.system` follows the OS; `.light` / `.dark`
/// pin it. Persisted as its raw value under `appearance_mode`.
public enum AppearanceMode: String, Sendable, CaseIterable, Identifiable {
    case system, light, dark
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system: return "Follow System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
}

public extension Notification.Name {
    static let terminalThemeChanged = Notification.Name("terminalThemeChanged")
    static let terminalFontChanged = Notification.Name("terminalFontChanged")
    /// Posted when the app-wide light/dark appearance preference changes. Chrome
    /// that isn't driven by terminal-theme colors (SwiftUI/AppKit views) listens
    /// to re-resolve its appearance.
    static let appearanceModeChanged = Notification.Name("appearanceModeChanged")
}
