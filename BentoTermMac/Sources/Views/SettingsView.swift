import SwiftUI
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
