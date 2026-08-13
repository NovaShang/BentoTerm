import SwiftUI
import BentoAgentKit
import BentoFoundationKit

/// The five-field agent-session form, shared by both platforms.
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
            Section {
                LayoutPickerGrid(selection: $model.layout)
            } header: {
                Text("Layout")
            } footer: {
                Text("\(model.layout.paneCount) pane\(model.layout.paneCount == 1 ? "" : "s") · \(model.layout.displayName)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .onAppear { model.recordAgentWizardLaunched() }
    }
}

/// LayoutPickerGrid renders the six preset layouts as a row of SF-Symbol
/// tiles. Tap to select; the chosen one gets the system accent border.
private struct LayoutPickerGrid: View {
    @Binding var selection: TmuxLayout

    private let columns = [GridItem(.adaptive(minimum: 72, maximum: 100), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(TmuxLayout.allCases) { layout in
                LayoutTile(layout: layout, isSelected: layout == selection)
                    .onTapGesture { selection = layout }
                    .accessibilityLabel(layout.displayName)
                    .accessibilityValue(layout == selection ? "Selected" : "")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { selection = layout }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct LayoutTile: View {
    let layout: TmuxLayout
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: layout.symbol)
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 24)
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            Text(layout.displayName)
                .font(.caption2)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary.opacity(0.25)), lineWidth: isSelected ? 2 : 1)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(Color.clear))
                )
        )
        .contentShape(Rectangle())
    }
}
