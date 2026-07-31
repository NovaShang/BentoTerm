import SwiftUI
import BentoTerminalCore

/// Second-level navigation: shows the tmux sessions that exist on a host,
/// plus a "new session" row and a "no tmux" row. Selecting any of them
/// pushes the terminal view onto the navigation stack with the choice
/// already applied.
struct HostSessionsView: View {
    let host: Host

    @EnvironmentObject private var hostStore: HostStore
    @EnvironmentObject private var sessionManager: SessionManager

    var body: some View {
        HostSessionsContent(host: host)
    }
}

/// Inner view: owns the transient TmuxLister (independent SSH used purely
/// for discovery), the per-host VoiceInputController, and routes session
/// picks into the SessionManager.
private struct HostSessionsContent: View {
    let host: Host

    @EnvironmentObject private var hostStore: HostStore
    @EnvironmentObject private var sessionManager: SessionManager
    @StateObject private var lister: TmuxLister
    @StateObject private var voiceController = VoiceInputController()

    @State private var newSessionName: String = "bento"
    @State private var pushKey: SessionKey?
    @State private var pendingChoice: TmuxStartChoice?
    @State private var isStartingNew = false
    @State private var showAgentWizard = false

    init(host: Host) {
        self.host = host
        _lister = StateObject(wrappedValue: TmuxLister(host: host))
    }

    /// Sessions currently attached on this host, keyed by tmux session name.
    private var activeForHost: [SessionManager.SessionEntry] {
        sessionManager.sessions(forHostID: host.id)
    }

    /// Names of tmux sessions we're already attached to (so we don't list
    /// them twice in "Other sessions").
    private var attachedNames: Set<String> {
        Set(activeForHost.map { $0.key.tmuxSessionName })
    }

    /// Tmux sessions reported by `tmux ls` that we are NOT currently attached to.
    private var unattachedTmuxSessions: [String] {
        lister.sessions.filter { !attachedNames.contains($0) }
    }

    var body: some View {
        Form {
            connectionStatusSection

            if !activeForHost.isEmpty {
                activeSection
            }

            otherSessionsSection
            newSessionSection
            noTmuxSection
        }
        .bentoForm()
        .disabled(isStartingNew)
        .overlay {
            if isStartingNew {
                ZStack {
                    Color.black.opacity(0.45).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large).tint(Color.bentoEmerald)
                        Text("Starting session…")
                            .font(.callout)
                            .foregroundStyle(Color.bentoInkDim)
                    }
                    .padding(24)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.bentoSurface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.bentoBorder, lineWidth: 1)
                    )
                }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isStartingNew)
        .navigationTitle(host.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await lister.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(lister.isLoading)
            }
        }
        .navigationDestination(item: $pushKey) { key in
            if let entry = sessionManager.activeSessions.first(where: { $0.key == key }) {
                TerminalWrapperView(
                    viewModel: entry.viewModel,
                    voiceController: voiceController
                )
                // Use the system navigation bar (Liquid Glass on iOS 26) — the
                // terminal supplies its own back item, so only the default back
                // button is hidden; the bar itself is no longer hidden.
                .navigationBarBackButtonHidden()
            }
        }
        .task {
            voiceController.onResult = { result in
                handleVoiceResultForActivePane(result)
            }
            await lister.refresh()
        }
        .alert("Error", isPresented: Binding(
            get: { lister.error != nil },
            set: { if !$0 { lister.clearError() } }
        )) {
            Button("Dismiss", role: .cancel) {}
        } message: {
            Text(lister.error ?? "")
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var connectionStatusSection: some View {
        Section {
            HStack(spacing: 10) {
                if lister.isLoading {
                    ProgressView().controlSize(.small)
                } else if lister.error != nil {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.bentoRed)
                } else {
                    Image(systemName: "server.rack").foregroundStyle(Color.bentoEmerald)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(lister.isLoading ? "Listing sessions…" : host.displayName)
                        .font(.body)
                        .foregroundStyle(Color.bentoInk)
                    Text("\(host.username)@\(host.hostname):\(host.port)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.bentoInkDim)
                }
            }
        }
        .bentoSectionStyle()
    }

    /// Sessions on this host that already have a live VM in SessionManager.
    @ViewBuilder
    private var activeSection: some View {
        Section {
            ForEach(activeForHost) { entry in
                Button {
                    pushKey = entry.key
                } label: {
                    HStack(spacing: 10) {
                        Circle().fill(Color.bentoEmerald).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(displayLabel(for: entry.key))
                                .foregroundStyle(Color.bentoInk)
                            Text(statusText(for: entry.viewModel))
                                .font(.caption2)
                                .foregroundStyle(Color.bentoInkDim)
                        }
                        Spacer()
                        Image(systemName: "play.circle.fill").foregroundStyle(Color.bentoEmerald)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        sessionManager.disconnect(key: entry.key)
                    } label: {
                        Label("Disconnect", systemImage: "xmark.circle")
                    }
                }
            }
        } header: {
            BentoFormHeader("Active")
        } footer: {
            BentoFormFooter("Already connected. Tap to resume.")
        }
        .bentoSectionStyle()
    }

    /// Tmux sessions on the server that aren't yet attached.
    @ViewBuilder
    private var otherSessionsSection: some View {
        Section {
            if lister.isLoading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Listing tmux sessions…").foregroundStyle(Color.bentoInkDim)
                }
            } else if unattachedTmuxSessions.isEmpty {
                Text("No other tmux sessions on this host.")
                    .font(.callout)
                    .foregroundStyle(Color.bentoInkDim)
            } else {
                ForEach(unattachedTmuxSessions, id: \.self) { name in
                    Button {
                        startNewSession(.createOrAttach(name: name))
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "rectangle.stack")
                                .foregroundStyle(Color.bentoEmerald)
                            Text(name)
                                .foregroundStyle(Color.bentoInk)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(Color.bentoInkMute)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            BentoFormHeader(activeForHost.isEmpty ? "Sessions" : "Other sessions")
        } footer: {
            BentoFormFooter("Tap to open a new connection and attach.")
        }
        .bentoSectionStyle()
    }

    @ViewBuilder
    private var newSessionSection: some View {
        Section {
            HStack {
                Image(systemName: "plus.rectangle.on.rectangle")
                    .foregroundStyle(Color.bentoEmerald)
                TextField("Session name", text: $newSessionName)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                Button("Create") {
                    let name = newSessionName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    startNewSession(.createOrAttach(name: name))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Color.bentoEmerald)
                .disabled(newSessionName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Button {
                showAgentWizard = true
            } label: {
                Label("New agent session…", systemImage: "wand.and.stars")
            }
        } header: {
            BentoFormHeader("New tmux session")
        } footer: {
            BentoFormFooter("Quick session is an empty single-pane shell. Agent session lets you pick an agent (Claude / Codex / …), working directory, and pane layout.")
        }
        .bentoSectionStyle()
        .sheet(isPresented: $showAgentWizard) {
            AgentSessionWizardView { spec in
                startNewSession(.createAgent(spec: spec))
            }
        }
    }

    @ViewBuilder
    private var noTmuxSection: some View {
        let hasNoTmuxActive = activeForHost.contains { $0.key.tmuxSessionName.isEmpty }
        Section {
            if !hasNoTmuxActive {
                Button {
                    startNewSession(.noTmux)
                } label: {
                    Label("Connect without tmux", systemImage: "terminal")
                }
            }
        } footer: {
            BentoFormFooter(hasNoTmuxActive
                ? "A plain-shell session is already open — see Active."
                : "Plain shell. No split panes or session persistence.")
        }
        .bentoSectionStyle()
    }

    // MARK: - Helpers

    private func displayLabel(for key: SessionKey) -> String {
        key.tmuxSessionName.isEmpty ? "Shell" : key.tmuxSessionName
    }

    private func statusText(for vm: TerminalViewModel) -> String {
        switch vm.phase {
        case .tmuxReady:
            let n = vm.paneViewModels.count
            return "\(n) pane\(n == 1 ? "" : "s")"
        case .shellReady: return "Shell"
        case .sshConnecting: return "Connecting…"
        case .choosingSession, .starting: return "Starting…"
        case .suspended: return "Suspended"
        case .ended: return "Ended"
        }
    }

    private func handleVoiceResultForActivePane(_ result: VoiceInputController.VoiceInputResult) {
        // Voice input only makes sense once the user has pushed into a
        // specific terminal — the active VM is the one at `pushKey`.
        guard let key = pushKey,
              let entry = sessionManager.activeSessions.first(where: { $0.key == key }) else {
            return
        }
        entry.viewModel.handleVoiceResult(result)
    }

    // MARK: - Pick

    /// Open a fresh VM (new SSH) for the picked choice, then push the
    /// terminal once it's ready.
    private func startNewSession(_ choice: TmuxStartChoice) {
        let name: String
        switch choice {
        case .noTmux: name = ""
        case .createOrAttach(let n): name = n
        case .shareWithDesktop(let target): name = "\(target)-mobile"
        case .createAgent(let spec): name = spec.sessionName
        }
        let key = SessionKey(hostID: host.id, tmuxSessionName: name)

        // If somehow already cached (e.g. user double-tapped), just push.
        if sessionManager.existingViewModel(for: key) != nil {
            pushKey = key
            return
        }

        hostStore.markConnected(host)
        let vm = sessionManager.viewModel(for: host, tmuxSessionName: name)
        isStartingNew = true

        Task {
            await vm.connect()
            // Bail if SSH didn't come up — drop the half-registered VM so
            // the picker stays consistent.
            guard case .connected = vm.connectionState else {
                isStartingNew = false
                sessionManager.disconnect(key: key)
                return
            }
            await vm.applyTmuxChoice(choice)
            isStartingNew = false
            pushKey = key
            // Refresh the lister so the new session appears in the picker
            // next time and keeps our attached/unattached split correct.
            await lister.refresh()
        }
    }
}
