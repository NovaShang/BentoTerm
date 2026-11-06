import SwiftUI
import BentoFoundationKit
import BentoGhosttyKit
import BentoUISharedKit

/// The iOS side of the five shared setup panels.
///
/// Same panels as the Mac, same order, same explanation — only the platform
/// extras differ, and this is the one place that decides where each of them
/// hangs, so the setup flow and Settings can't put the same row in two
/// different boxes.
///
/// The tmux panel is here in full. Its explanation is not Mac-specific in the
/// slightest: a phone user has *more* reason to know that sessions live on the
/// host and keep running, since that is the entire reason a phone client is
/// worth having. What iOS omits is only the fact line (which tmux is in use —
/// that belongs to whatever host you connect to) and the Mac's tab/window
/// preference.
struct IOSSetupPanel: View {
    let page: PanelPage
    let context: PanelContext

    @AppStorage("haptics_enabled") private var hapticsEnabled = true
    @AppStorage("path_preview_enabled") private var pathPreviewEnabled = true

    var body: some View {
        switch page {
        case .appearance:
            AppearancePanel(context: context,
                            preview: AnyView(GhosttyThemePreview())) {
                Toggle("Haptic Feedback", isOn: $hapticsEnabled)
                Toggle("Tap to Preview Files", isOn: $pathPreviewEnabled)
                PanelNote("Tap a file path in terminal output to peek at the file without leaving the session.")
            }
        case .speech:
            SpeechPanel(context: context)
        case .tmux:
            TmuxPanel(context: context)
        case .agents:
            AgentsPanel(context: context)
        case .finish:
            FinishPanel(context: context) {
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
