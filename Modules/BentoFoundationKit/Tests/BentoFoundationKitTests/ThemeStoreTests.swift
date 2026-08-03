import XCTest
@testable import BentoFoundationKit

/// The import path (addCustomTheme) must have an immediate visible effect:
/// beyond writing the theme into the slot matching its own light/dark, it
/// switches the app-wide appearance so the imported theme actually renders.
/// Tests run against the live singleton; the defaults keys it touches are
/// snapshotted and restored so the user's real prefs stay untouched.
@MainActor
final class ThemeStoreTests: XCTestCase {
    private static let touchedKeys = [
        "appearance_mode", "dark_theme_id", "light_theme_id", "terminal_custom_themes_v1",
    ]
    private var saved: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        for key in Self.touchedKeys {
            saved[key] = UserDefaults.standard.object(forKey: key)
        }
    }

    override func tearDown() {
        for key in Self.touchedKeys {
            if let value = saved[key], let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        super.tearDown()
    }

    /// Landmine, stated as a test: a user in Light mode importing a dark theme
    /// must flip the appearance to dark — otherwise the import writes the theme
    /// to the dark slot, `effectiveIsDark` never changes, no notification
    /// fires, and the import looks broken.
    func testImportingADarkThemeFromLightModeSwitchesAppearance() {
        let store = ThemeStore.shared
        store.appearanceMode = .light

        let dark = TerminalColorTheme(id: "test-import-dark", name: "Test Dark", isDark: true,
                                      bg: 0x000000, fg: 0xFFFFFF, cursor: 0xFFFFFF,
                                      ansi: TerminalColorTheme.defaultAnsi)
        store.addCustomTheme(dark)

        XCTAssertEqual(store.appearanceMode, .dark,
                       "importing a dark theme must flip the appearance to dark")
        XCTAssertEqual(store.darkThemeID, dark.id)
        XCTAssertTrue(store.effectiveIsDark)

        store.removeCustomTheme(dark.id)
        store.appearanceMode = .light
    }

    /// The converse: a dark-mode user importing a light theme lands in the
    /// light slot and the appearance follows.
    func testImportingALightThemeFromDarkModeSwitchesAppearance() {
        let store = ThemeStore.shared
        store.appearanceMode = .dark

        let light = TerminalColorTheme(id: "test-import-light", name: "Test Light", isDark: false,
                                       bg: 0xFFFFFF, fg: 0x000000, cursor: 0x000000,
                                       ansi: TerminalColorTheme.lightAnsi)
        store.addCustomTheme(light)

        XCTAssertEqual(store.appearanceMode, .light,
                       "importing a light theme must flip the appearance to light")
        XCTAssertEqual(store.lightThemeID, light.id)
        XCTAssertFalse(store.effectiveIsDark)

        store.removeCustomTheme(light.id)
        store.appearanceMode = .dark
    }
}
