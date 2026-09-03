import BentoUISharedKit
import SwiftUI

/// Settings → Privacy, under About: the update switch and a way to ask now.
///
/// It sits on the privacy page because that is the honest place for it — the
/// scheduled check is the one thing this app does over the network without
/// being asked, so it belongs next to the other switch that says so.
struct SoftwareUpdateSection: View {
    @ObservedObject private var updater = AppUpdater.shared
    /// Mirrors Sparkle's stored preference. A local copy because the source of
    /// truth is a plain property on the updater, not something a Binding can
    /// observe — the toggle would otherwise not move when clicked.
    @State private var checksAutomatically = AppUpdater.shared.checksAutomatically

    var body: some View {
        Section {
            Toggle("Check for updates automatically", isOn: $checksAutomatically)
                .onChange(of: checksAutomatically) { _, on in
                    updater.checksAutomatically = on
                }
            HStack {
                Button("Check Now") { updater.checkForUpdates() }
                    .disabled(!updater.canCheck)
                Spacer()
                Text(lastCheckedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: { Text("Software Update") } footer: {
            PanelNote("""
                Updates come from this project's GitHub releases and are only \
                installed if they carry Bento's signature. Nothing about you or \
                this Mac is sent — the check asks GitHub what the latest \
                version is. Bento never restarts itself; you pick when.
                """)
        }
    }

    /// "Never" is a real answer, not a missing one — a build that has never
    /// checked (or a debug build, which has no updater at all) should say so
    /// rather than show an empty space where a date goes.
    private var lastCheckedText: String {
        guard let date = updater.lastCheck else { return "Never checked" }
        return "Last checked \(date.formatted(.relative(presentation: .named)))"
    }
}
