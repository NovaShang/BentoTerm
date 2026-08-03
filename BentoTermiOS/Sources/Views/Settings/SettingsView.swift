import SwiftUI
import BentoAgentKit
import BentoFoundationKit
import BentoUISharedKit

/// iOS settings page. The shared sections (appearance, font, themes, speech,
/// LLM, privacy) come from BentoUISharedKit — the Mac rendering is the
/// reference — while this file keeps the NavigationStack container and the
/// iOS-only sections (haptics, tap-to-preview, state profiles, help, about).
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("haptics_enabled") private var hapticsEnabled = true
    @AppStorage("path_preview_enabled") private var pathPreviewEnabled = true
    @State private var showTipsResetConfirm = false

    var body: some View {
        NavigationStack {
            BentoSettingsForm(defaultFontSize: 10) {
                Section {
                    Toggle("Haptic Feedback", isOn: $hapticsEnabled)
                } header: {
                    Text("Feedback")
                }

                Section {
                    Toggle("Tap to Preview Files", isOn: $pathPreviewEnabled)
                } footer: {
                    Text("Tap a file path in terminal output to peek at the file without leaving the session.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    NavigationLink("State Detection Profiles") {
                        ProfileListView()
                    }
                } footer: {
                    Text("Configure patterns to detect when a pane is waiting for input, and which quick keys to show.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    NavigationLink {
                        HowBentoWorksSettingsPage()
                    } label: {
                        Label("How BentoTerm works", systemImage: "questionmark.circle")
                    }
                    Button {
                        TipCenter.shared.resetAll()
                        showTipsResetConfirm = true
                    } label: {
                        Label("Replay tips & gesture guide", systemImage: "arrow.counterclockwise")
                    }
                } header: {
                    Text("Help")
                } footer: {
                    Text("Replaying brings back every one-time hint — the gesture overlay, the color legend, and the coaching toasts — at their natural moments.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                SettingsAboutSection(
                    icon: appIcon,
                    tagline: "A tmux-native terminal for iPhone & iPad.")
            }
            .bentoForm()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Tips will replay", isPresented: $showTipsResetConfirm) {
                Button("OK") {}
            } message: {
                Text("Every one-time hint is armed again and will appear at its natural moment.")
            }
        }
    }

    private var appIcon: Image? {
        if let ui = UIImage(named: "AppIcon") { return Image(uiImage: ui) }
        return nil
    }
}

// MARK: - Profile List

struct ProfileListView: View {
    @ObservedObject private var store = ProfileStore.shared
    @State private var editingProfile: StateProfile?
    @State private var showAddSheet = false

    var body: some View {
        List {
            ForEach(store.profiles) { profile in
                Button {
                    editingProfile = profile
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(profile.name)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                if profile.isBuiltIn {
                                    Text("Built-in")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.quaternary)
                                        .clipShape(Capsule())
                                }
                            }
                            Text("\(profile.outputPatterns.count) patterns · \(profile.quickKeys.count) keys")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let cmd = profile.commandPattern {
                                Text("command: \(cmd)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .onDelete { indexSet in
                for i in indexSet where !store.profiles[i].isBuiltIn {
                    store.profiles.remove(at: i)
                }
                store.save()
            }
        }
        .bentoForm()
        .navigationTitle("Profiles")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: { showAddSheet = true }) {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("Reset to Defaults") { store.resetToDefaults() }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
            }
        }
        .sheet(item: $editingProfile) { profile in
            NavigationStack {
                ProfileEditView(profile: profile) { updated in
                    if let idx = store.profiles.firstIndex(where: { $0.id == updated.id }) {
                        store.profiles[idx] = updated
                    }
                    store.save()
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            NavigationStack {
                ProfileEditView(profile: StateProfile(
                    id: UUID().uuidString,
                    name: "",
                    outputPatterns: [],
                    commandPattern: nil,
                    quickKeys: []
                )) { newProfile in
                    store.profiles.append(newProfile)
                    store.save()
                }
            }
        }
    }
}

// MARK: - Profile Edit

struct ProfileEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State var profile: StateProfile
    let onSave: (StateProfile) -> Void

    @State private var newPattern = ""
    @State private var newKeyLabel = ""
    @State private var newKeyString = ""
    @State private var newKeyIsEnter = true

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $profile.name)
                TextField("Command pattern (optional)", text: Binding(
                    get: { profile.commandPattern ?? "" },
                    set: { profile.commandPattern = $0.isEmpty ? nil : $0 }
                ))
                .font(.system(.body, design: .monospaced))
                .autocapitalization(.none)
            } header: {
                BentoFormHeader("Profile")
            }
            .bentoSectionStyle()

            Section {
                ForEach(profile.outputPatterns.indices, id: \.self) { i in
                    Text(profile.outputPatterns[i])
                        .font(.system(.caption, design: .monospaced))
                }
                .onDelete { profile.outputPatterns.remove(atOffsets: $0) }

                HStack {
                    TextField("New regex pattern", text: $newPattern)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                    Button(action: {
                        guard !newPattern.isEmpty else { return }
                        profile.outputPatterns.append(newPattern)
                        newPattern = ""
                    }) {
                        Image(systemName: "plus.circle.fill")
                    }
                    .disabled(newPattern.isEmpty)
                }
            } header: {
                BentoFormHeader("Output Patterns (regex)")
            } footer: {
                BentoFormFooter("If any pattern matches the recent terminal output, the pane is considered 'awaiting input'.")
            }
            .bentoSectionStyle()

            Section {
                ForEach(profile.quickKeys) { key in
                    HStack {
                        Text(key.label)
                            .font(.body.weight(.medium))
                        Spacer()
                        if key.isEnter {
                            Text("+ Enter")
                                .font(.caption)
                                .foregroundStyle(Color.bentoInkDim)
                        }
                        Text(key.keys.isEmpty ? "(none)" : key.keys)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Color.bentoInkDim)
                    }
                }
                .onDelete { profile.quickKeys.remove(atOffsets: $0) }

                HStack(spacing: 8) {
                    TextField("Label", text: $newKeyLabel)
                        .frame(width: 60)
                    TextField("Keys", text: $newKeyString)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                    Toggle("↵", isOn: $newKeyIsEnter)
                        .labelsHidden()
                        .frame(width: 40)
                    Button(action: {
                        guard !newKeyLabel.isEmpty else { return }
                        profile.quickKeys.append(QuickKey(
                            id: UUID().uuidString,
                            label: newKeyLabel,
                            keys: newKeyString,
                            isEnter: newKeyIsEnter
                        ))
                        newKeyLabel = ""
                        newKeyString = ""
                    }) {
                        Image(systemName: "plus.circle.fill")
                    }
                    .disabled(newKeyLabel.isEmpty)
                }
            } header: {
                BentoFormHeader("Quick Keys")
            } footer: {
                BentoFormFooter("Keys shown when this profile matches. Toggle ↵ to send Enter after the key.")
            }
            .bentoSectionStyle()
        }
        .bentoForm()
        .navigationTitle(profile.name.isEmpty ? "New Profile" : profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    onSave(profile)
                    dismiss()
                }
                .disabled(profile.name.isEmpty || profile.outputPatterns.isEmpty)
            }
        }
    }
}
