import SwiftUI
import AppKit
import BentoAgentKit
import BentoFoundationKit
import BentoUISharedKit

/// AgentWizardWindow hosts the shared `AgentWizardForm` (see BentoUISharedKit)
/// in a titled NSWindow with the macOS action bar. The form itself — fields,
/// validity rules — is shared with iOS; only the chrome
/// is platform-specific. `Form().formStyle(.grouped)` keeps the visual
/// hierarchy in line with System Settings panes.
struct AgentWizardWindow: View {
    @StateObject private var model = AgentWizardModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            AgentWizardForm(model: model, onChooseDirectory: { binding in
                pickDirectory(binding)
            })
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Launch") { launch() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canLaunch)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 560, height: 440)
    }

    private func pickDirectory(_ binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            binding.wrappedValue = url.path
        }
    }

    /// Agent sessions always spin up in Bento's own in-app libghostty window
    /// (tmux -CC over a local pty) — sessions never bounce out to a
    /// third-party terminal anymore.
    private func launch() {
        model.error = nil
        BentoTerminalWindow.newWindow(agent: model.spec)
        dismiss()
    }
}
