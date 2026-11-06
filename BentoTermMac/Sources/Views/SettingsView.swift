import SwiftUI
import AppKit
import BentoGhosttyKit
import BentoUISharedKit

/// Settings: the three shared pages as tabs, with the Mac's own rows passed
/// in (see `MacSettingsPage`).
struct SettingsView: View {
    @State private var selection: SettingsPage = .appearance

    var body: some View {
        TabView(selection: $selection) {
            ForEach(SettingsPage.allCases) { page in
                MacSettingsPage(page: page)
                    .tabItem { Label(page.title, systemImage: page.symbol) }
                    .tag(page)
            }
        }
        .frame(width: 560, height: 620)
    }
}

/// The one place that maps a `SettingsPage` onto its panel plus the Mac-only
/// rows that belong on it.
struct MacSettingsPage: View {
    let page: SettingsPage

    var body: some View {
        switch page {
        case .appearance:
            AppearancePanel(preview: AnyView(GhosttyThemePreview()))
        case .voice:
            VoicePanel()
        case .general:
            GeneralPanel(facts: TmuxResolver.facts()) {
                SettingsAboutSection(
                    icon: Image(nsImage: NSApp.applicationIconImage),
                    tagline: "A tmux-native terminal for the Mac.")
                // Directly under the version it is about.
                SoftwareUpdateSection()
            }
        }
    }
}
