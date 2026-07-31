import SwiftUI
import BentoTerminalCore

/// iOS counterpart to BentoTermMac's AgentWizardWindow. Users pick a
/// session name, working directory, agent command, and pane layout; the
/// caller wires the resulting AgentSpec into a `createAgent` start choice.
struct AgentSessionWizardView: View {
    let onLaunch: (AgentSpec) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var sessionName: String = "agent-\(Int(Date().timeIntervalSince1970) % 10_000)"
    @State private var workingDir: String = "~"
    @State private var agentPreset: AgentPreset = .claudeCode
    @State private var customCommand: String = ""
    @State private var layout: TmuxLayout = .sideBySide

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("name", text: $sessionName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                } header: {
                    BentoFormHeader("Session name")
                }
                .bentoSectionStyle()

                Section {
                    TextField("~/code", text: $workingDir)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                } header: {
                    BentoFormHeader("Working directory")
                }
                .bentoSectionStyle()

                Section {
                    Picker("Agent", selection: $agentPreset) {
                        ForEach(AgentPreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    if agentPreset == .custom {
                        TextField("e.g. cursor-agent", text: $customCommand)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                    }
                } header: {
                    BentoFormHeader("Agent")
                }
                .bentoSectionStyle()

                Section {
                    LayoutPickerGrid(selection: $layout)
                } header: {
                    BentoFormHeader("Layout")
                } footer: {
                    BentoFormFooter("\(layout.paneCount) pane\(layout.paneCount == 1 ? "" : "s") · \(layout.displayName)")
                }
                .bentoSectionStyle()
            }
            .bentoForm()
            .navigationTitle("New Agent Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Launch") { launch() }
                        .disabled(!canLaunch)
                }
            }
        }
    }

    private var canLaunch: Bool {
        !sessionName.trimmingCharacters(in: .whitespaces).isEmpty
            && !workingDir.trimmingCharacters(in: .whitespaces).isEmpty
            && resolvedAgentCommand != nil
    }

    /// nil = invalid (custom selected but field empty). "" = explicit shell.
    private var resolvedAgentCommand: String? {
        switch agentPreset {
        case .custom:
            let trimmed = customCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        default:
            return agentPreset.command
        }
    }

    private func launch() {
        let spec = AgentSpec(
            sessionName: sessionName.trimmingCharacters(in: .whitespaces),
            workingDir: workingDir.trimmingCharacters(in: .whitespaces),
            agentCommand: resolvedAgentCommand ?? "",
            layout: layout
        )
        dismiss()
        onLaunch(spec)
    }
}

private struct LayoutPickerGrid: View {
    @Binding var selection: TmuxLayout

    private let columns = [GridItem(.adaptive(minimum: 84, maximum: 120), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(TmuxLayout.allCases) { layout in
                LayoutTile(layout: layout, isSelected: layout == selection)
                    .onTapGesture { selection = layout }
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
                .foregroundStyle(isSelected ? Color.bentoEmerald : Color.bentoInkDim)
            Text(layout.displayName)
                .font(.caption2)
                .foregroundStyle(Color.bentoInk)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.bentoEmerald.opacity(0.12) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isSelected ? Color.bentoEmerald : Color.bentoBorder,
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
        .contentShape(Rectangle())
    }
}
