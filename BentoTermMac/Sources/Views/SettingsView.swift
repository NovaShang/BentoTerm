import SwiftUI
import AppKit
import BentoGhosttyKit
import BentoUISharedKit

/// Settings = the setup pages, as tabs.
///
/// Same five panels, same names, same order, same Mac-only extras — the only
/// difference is that explanation arrives folded here and open there
/// (`PanelContext`). That correspondence is the point: whatever a user changed
/// while being set up, they come back to it in a box with the same name. It
/// also means there is exactly one implementation of every setting, which is
/// what the old flat `BentoSettingsForm` couldn't offer once setup needed
/// previews and prose around the same controls.
struct SettingsView: View {
    @State private var selection: PanelPage = .appearance

    var body: some View {
        TabView(selection: $selection) {
            ForEach(PanelPage.allCases) { page in
                MacSetupPanel(page: page, context: .settings)
                    .tabItem { Label(page.settingsTitle, systemImage: page.symbol) }
                    .tag(page)
            }
        }
        .frame(width: 560, height: 620)
    }
}

/// The one place that maps a `PanelPage` onto its panel plus the Mac-only
/// settings that belong beside it.
struct MacSetupPanel: View {
    let page: PanelPage
    let context: PanelContext

    @AppStorage(BentoTerminalWindow.autoHideToolbarFullscreenKey) private var autoHideToolbar = true

    var body: some View {
        switch page {
        case .appearance:
            AppearancePanel(context: context, preview: AnyView(GhosttyThemePreview())) {
                Toggle("Auto-hide toolbar in full screen", isOn: $autoHideToolbar)
                PanelNote("""
                    Hides the toolbar and session tabs in full screen, revealing them when \
                    the pointer reaches the top. Takes effect the next time you enter full \
                    screen.
                    """)
            }
        case .speech:
            SpeechPanel(context: context)
        case .tmux:
            TmuxPanel(context: context, facts: TmuxResolver.facts())
        case .agents:
            AgentsPanel(context: context)
        case .finish:
            FinishPanel(context: context) {
                SettingsAboutSection(
                    icon: Image(nsImage: NSApp.applicationIconImage),
                    tagline: "A tmux-native terminal for the Mac.")
                // Directly under the version it is about.
                SoftwareUpdateSection()
            }
        }
    }
}
