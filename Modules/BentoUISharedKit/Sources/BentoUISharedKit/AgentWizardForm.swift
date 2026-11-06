import SwiftUI
import BentoAgentKit
import BentoFoundationKit

/// The agent-session form, shared by both platforms.
///
/// Renders with plain system styling — Mac's look, which is the reference —
/// and takes all its state from `AgentWizardModel`. The shell owns the chrome:
/// Mac hosts it in an NSWindow with `.formStyle(.grouped)` and a bottom
/// Cancel/Launch bar, iOS in a NavigationStack sheet with toolbar buttons.
public struct AgentWizardForm: View {
    @ObservedObject public var model: AgentWizardModel

    /// Directory-picker seam. When non-nil the row renders a "Choose…" button
    /// that calls this with the working-dir binding (Mac runs an NSOpenPanel).
    /// iOS has no picker — pass nil and the button is omitted.
    public let onChooseDirectory: ((Binding<String>) -> Void)?

    public init(model: AgentWizardModel, onChooseDirectory: ((Binding<String>) -> Void)? = nil) {
        self.model = model
        self.onChooseDirectory = onChooseDirectory
    }

    public var body: some View {
        Form {
            Section {
                TextField("Session name", text: $model.sessionName)
            }
            Section("Working directory") {
                HStack {
                    TextField("Path", text: $model.workingDir)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                    if let onChooseDirectory {
                        Button("Choose…") { onChooseDirectory($model.workingDir) }
                    }
                }
            }
            Section("Agent") {
                HStack(spacing: 8) {
                    Picker("Agent", selection: $model.agentPreset) {
                        ForEach(AgentPreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()

                    if model.agentPreset == .custom {
                        TextField("e.g. cursor-agent", text: $model.customCommand)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }
            if let error = model.error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
    }
}
