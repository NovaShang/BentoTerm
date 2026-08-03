import SwiftUI
import BentoUISharedKit

/// SettingsView is the content of the app's Settings scene. macOS renders it
/// as a plain window with one scrolling grouped form: the shared
/// `BentoSettingsForm` supplies the six common sections, this file the
/// Mac-only ones (Full Screen, Sessions) and the About block.
struct SettingsView: View {
    @AppStorage(BentoTerminalWindow.defaultSessionNameKey) private var defaultSessionName: String = "bento"
    @AppStorage(BentoTerminalWindow.autoHideToolbarFullscreenKey) private var autoHideToolbar = true
    @AppStorage(BentoTerminalWindow.newSessionPlacementKey) private var newSessionPlacement = "system"

    var body: some View {
        BentoSettingsForm {
            Section {
                Toggle("Auto-hide toolbar in full screen", isOn: $autoHideToolbar)
            } header: { Text("Full Screen") } footer: {
                Text("Hide the toolbar and session tabs in full screen, revealing them when the pointer reaches the top. Takes effect the next time you enter full screen.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextField("Default session name", text: $defaultSessionName, prompt: Text("bento"))
                Picker("Open a new session", selection: $newSessionPlacement) {
                    ForEach(BentoTerminalWindow.NewSessionPlacement.allCases, id: \.rawValue) {
                        Text($0.title).tag($0.rawValue)
                    }
                }
            } header: { Text("Sessions") } footer: {
                Text("Clicking the app icon opens the terminal window and reconnects the session you last had open. With no previous session, it creates one with this name.\n\nmacOS already has a system-wide answer for tabs vs. windows (System Settings → Desktop & Dock → “Prefer tabs when opening documents”), which Bento follows by default. Either way you can still merge windows into tabs or drag a tab out into its own window.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            SettingsAboutSection(
                icon: Image(nsImage: NSApp.applicationIconImage),
                tagline: "A tmux-native terminal for the Mac.")
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
    }
}
