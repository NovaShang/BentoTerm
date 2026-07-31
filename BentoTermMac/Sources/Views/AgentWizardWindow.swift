import SwiftUI
import AppKit
import BentoTerminalCore

/// AgentWizardWindow uses `Form().formStyle(.grouped)` so the visual hierarchy
/// matches System Settings panes. Agent is chosen from a curated picker;
/// layout is chosen from a visual grid of SF-symbol previews.
struct AgentWizardWindow: View {
    @State private var sessionName: String = "agent-\(Int(Date().timeIntervalSince1970) % 10_000)"
    @State private var workingDir: String = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("code").path
    @State private var agentPreset: AgentPreset = .claudeCode
    @State private var customCommand: String = ""
    @State private var layout: TmuxLayout = .sideBySide
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Session name", text: $sessionName)
                }
                Section("Working directory") {
                    HStack {
                        TextField("Path", text: $workingDir)
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                        Button("Choose…") { pickDirectory() }
                    }
                }
                Section("Agent") {
                    HStack(spacing: 8) {
                        Picker("Agent", selection: $agentPreset) {
                            ForEach(AgentPreset.allCases) { preset in
                                Text(preset.rawValue).tag(preset)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()

                        if agentPreset == .custom {
                            TextField("e.g. cursor-agent", text: $customCommand)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                }
                Section {
                    LayoutPickerGrid(selection: $layout)
                } header: {
                    Text("Layout")
                } footer: {
                    Text("\(layout.paneCount) pane\(layout.paneCount == 1 ? "" : "s") · \(layout.displayName)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Launch") { Task { await launch() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canLaunch)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 560, height: 620)
        .onAppear { TelemetryService.shared.record(.agentWizardLaunched) }
    }

    private var canLaunch: Bool {
        !sessionName.isEmpty
            && !workingDir.isEmpty
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

    private var spec: AgentSpec {
        AgentSpec(
            sessionName: sessionName,
            workingDir: workingDir,
            agentCommand: resolvedAgentCommand ?? "",
            layout: layout
        )
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            workingDir = url.path
        }
    }

    private func launch() async {
        do {
            error = nil
            let kind = TerminalAppKind.preferred
            // Native Bento terminal: spin the agent session up directly in our
            // in-app libghostty window (tmux -CC over a local pty) instead of
            // bouncing to a third-party terminal.
            if kind.isNative {
                let coreSpec = BentoTerminalCore.AgentSpec(
                    sessionName: spec.sessionName,
                    workingDir: spec.workingDir,
                    agentCommand: spec.agentCommand,
                    layout: BentoTerminalCore.TmuxLayout(rawValue: spec.layout.rawValue) ?? .solo
                )
                await MainActor.run { BentoTerminalWindow.newWindow(agent: coreSpec) }
                TelemetryService.shared.record(.workspaceCreated)
                dismiss()
                return
            }
            let script = TmuxCLI.buildAgentScript(spec: spec, useTmuxControlMode: kind.supportsTmuxControlMode)
            try await TmuxCLI.openInTerminal(command: script, kind: kind)
            TelemetryService.shared.record(.workspaceCreated)
            dismiss()
        } catch {
            self.error = "\(error)"
        }
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
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            Text(layout.displayName)
                .font(.caption2)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isSelected ? 2 : 1)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
                )
        )
        .contentShape(Rectangle())
    }
}
