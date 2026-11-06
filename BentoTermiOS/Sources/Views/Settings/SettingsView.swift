import SwiftUI
import BentoFoundationKit
import BentoGhosttyKit
import BentoUISharedKit

/// iOS settings: the three shared pages as a list you drill into, with the
/// iOS-only rows passed in (see `IOSSettingsPage`).
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(SettingsPage.allCases) { page in
                    NavigationLink {
                        IOSSettingsPage(page: page)
                            .bentoForm()
                            .navigationTitle(page.title)
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label(page.title, systemImage: page.symbol)
                    }
                }
            }
            .tint(Color.bentoEmerald)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// The open-source notices, read from the `Acknowledgements.txt` generated
/// against the resolved package graph.
///
/// Kept as a bundled text file rather than a Swift literal so regenerating it
/// after a dependency bump is a file write, not a source edit — and so the
/// notices are verbatim upstream text, which is what MIT, Apache-2.0 and the
/// SIL OFL actually require to accompany a redistributed binary.
struct AcknowledgementsView: View {
    @State private var text: String?

    var body: some View {
        ScrollView {
            Text(text ?? "Acknowledgements are unavailable in this build.")
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard text == nil,
                  let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt")
            else { return }
            // ~110 KB off the main thread — the view is pushed before it lands.
            text = await Task.detached { try? String(contentsOf: url, encoding: .utf8) }.value
        }
    }
}

/// The one place that maps a `SettingsPage` onto its panel plus the iOS-only
/// rows that belong on it.
struct IOSSettingsPage: View {
    let page: SettingsPage

    var body: some View {
        switch page {
        case .appearance:
            AppearancePanel(preview: AnyView(GhosttyThemePreview()))
        case .voice:
            VoicePanel()
        case .general:
            GeneralPanel {
                SettingsAboutSection(
                    icon: BentoAppIcon.image,
                    tagline: "A tmux-native terminal for iPhone & iPad.")

                Section {
                    NavigationLink {
                        AcknowledgementsView()
                    } label: {
                        Label("Acknowledgements", systemImage: "doc.text")
                    }
                } footer: {
                    PanelNote("BentoTerm redistributes MIT, Apache and SIL-licensed components — the terminal engine, the SSH stack, the bundled font — and each of those licenses requires its text to travel with the binary.")
                }
            }
        }
    }
}

/// The app icon, for the About row.
///
/// `UIImage(named: "AppIcon")` alone does NOT work on iOS: the catalogue holds
/// an *app icon set*, which is not addressable by name at runtime, so it
/// returns nil and About renders with a hole where the icon goes.
/// The primary-icon file list in Info.plist is the way in. (The name lookup is
/// kept first so a plain imageset would still win if one is ever added.)
enum BentoAppIcon {
    static var image: Image? {
        if let ui = UIImage(named: "AppIcon") { return Image(uiImage: ui) }
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let name = files.last,
              let ui = UIImage(named: name)
        else { return nil }
        return Image(uiImage: ui)
    }
}
