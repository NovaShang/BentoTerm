import SwiftUI
import BentoTerminalCore

// MARK: - Create sheet

/// The pre-session "where to / what to create" sheet — iOS's form of the
/// Mac launcher's creation panel. Level 1: pick a host. Level 2: that
/// host's sessions (live enumeration) plus the creation entries.
///
/// All SSH round-trips (enumeration, connection, session start) and all
/// failure display happen HERE, before any terminal exists. The terminal is
/// only pushed once a real session is attached — so it never has to express
/// a connection failure (the structural root of the Mac's "open remote tmux
/// and hang" bug, fixed on both platforms the same way).
struct CreateSheetView: View {
    var initialHost: Host?
    var initialSessionName: String?
    var initialIntent: CreateIntent?
    /// Called the moment a session is attached and ready to enter.
    var onSessionReady: (SessionKey) -> Void
    var onAddHost: () -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var hostStore: HostStore

    @State private var path = NavigationPath()
    @State private var prefillPushed = false

    var body: some View {
        NavigationStack(path: $path) {
            hostList
                .navigationDestination(for: Host.self) { host in
                    HostSessionsContent(
                        host: host,
                        initialSessionName: initialSessionName,
                        initialIntent: initialIntent,
                        onSessionReady: { key in
                            onSessionReady(key)
                            dismiss()
                        }
                    )
                }
                .navigationTitle("New")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
        .task {
            // Prefill: a cached-session tap or a recent-launch tap routes here
            // with a specific host. Push straight past the host list.
            guard !prefillPushed, let host = initialHost else { return }
            prefillPushed = true
            path.append(host)
        }
    }

    private var hostList: some View {
        Form {
            Section {
                if hostStore.hosts.isEmpty {
                    Text("No hosts yet — add the machine you want to reach.")
                        .font(.callout)
                        .foregroundStyle(Color.bentoInkDim)
                } else {
                    ForEach(hostStore.hosts) { host in
                        NavigationLink(value: host) {
                            HostRow(host: host)
                        }
                    }
                }
            } header: {
                BentoFormHeader("SSH Hosts")
            } footer: {
                BentoFormFooter("A host is any machine running sshd and tmux. Pick one to attach to a session or start a new one.")
            }
            .bentoSectionStyle()

            Section {
                Button {
                    onAddHost()
                } label: {
                    Label("Add SSH host…", systemImage: "plus.circle")
                }
            }
            .bentoSectionStyle()
        }
        .bentoForm()
    }
}

// MARK: - Per-host session content (level 2)

/// Lists the tmux sessions that exist on a host, plus a "new session" row
/// and a "no tmux" row. Selecting any of them attaches (or starts) the
/// session and calls `onSessionReady` — the sheet dismisses and the parent
/// pushes the terminal.
///
/// Opened with a `sessionName` it auto-attaches on appear (the cached-session
/// tap flow — one tap from Home should enter). Opened with an `intent` it
/// runs that creation flow (agent wizard / empty session / plain shell).
private struct HostSessionsContent: View {
    let host: Host
    var initialSessionName: String?
    var initialIntent: CreateIntent?
    var onSessionReady: (SessionKey) -> Void

    @EnvironmentObject private var hostStore: HostStore
    @EnvironmentObject private var sessionManager: SessionManager
    @StateObject private var lister: TmuxLister

    @State private var newSessionName: String = "bento"
    @FocusState private var nameFieldFocused: Bool
    @State private var pendingChoice: TmuxStartChoice?
    @State private var isStartingNew = false
    @State private var showAgentWizard = false
    @State private var autoStarted = false
    /// Connect failures surface HERE, in the sheet — the terminal never
    /// exists yet, so the sheet is the only place that can say what happened.
    @State private var connectError: String?

    init(host: Host,
         initialSessionName: String?,
         initialIntent: CreateIntent?,
         onSessionReady: @escaping (SessionKey) -> Void) {
        self.host = host
        self.initialSessionName = initialSessionName
        self.initialIntent = initialIntent
        self.onSessionReady = onSessionReady
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
        .task {
            await lister.refresh()
            applyInitialIntent()
            autoAttachIfRequested()
        }
        .alert("Error", isPresented: Binding(
            get: { lister.error != nil },
            set: { if !$0 { lister.clearError() } }
        )) {
            Button("Dismiss", role: .cancel) {}
        } message: {
            Text(lister.error ?? "")
        }
        .alert("Connection Failed", isPresented: Binding(
            get: { connectError != nil },
            set: { if !$0 { connectError = nil } }
        )) {
            Button("Dismiss", role: .cancel) {}
        } message: {
            Text(connectError ?? "")
        }
        .sheet(isPresented: $showAgentWizard) {
            AgentSessionWizardView { spec in
                startNewSession(.createAgent(spec: spec))
            }
        }
    }

    /// The creation verb that opened this screen drives what happens when it
    /// appears. Agent → straight into the wizard. Empty → the name field is
    /// the cursor's home (the user types the one thing it needs).
    private func applyInitialIntent() {
        switch initialIntent {
        case .agent:
            showAgentWizard = true
        case .empty:
            newSessionName = ""
            nameFieldFocused = true
        case .plainShell, .none:
            break
        }
    }

    /// A cached-session tap from Home means "take me back there". Attach on
    /// appear without asking: `new-session -A` re-creates a same-named
    /// session if it died, so even a stale cache lands somewhere real.
    private func autoAttachIfRequested() {
        guard !autoStarted, let name = initialSessionName, !name.isEmpty else { return }
        autoStarted = true
        startNewSession(.createOrAttach(name: name))
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
                    onSessionReady(entry.key)
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
                    .focused($nameFieldFocused)
                    .submitLabel(.go)
                    .onSubmit {
                        let name = newSessionName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        startNewSession(.createOrAttach(name: name))
                    }
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

    // MARK: - Pick

    /// Open a fresh VM (new SSH) for the picked choice, then hand the ready
    /// session to the parent — the sheet dismisses, the terminal is pushed.
    private func startNewSession(_ choice: TmuxStartChoice) {
        let name: String
        switch choice {
        case .noTmux: name = ""
        case .createOrAttach(let n): name = n
        case .shareWithDesktop(let target): name = "\(target)-mobile"
        case .createAgent(let spec): name = spec.sessionName
        }
        let key = SessionKey(hostID: host.id, tmuxSessionName: name)

        // If somehow already cached (e.g. user double-tapped), just go.
        if sessionManager.existingViewModel(for: key) != nil {
            onSessionReady(key)
            return
        }

        hostStore.markConnected(host)
        let vm = sessionManager.viewModel(for: host, tmuxSessionName: name)
        isStartingNew = true

        Task {
            await vm.connect()
            // Bail if SSH didn't come up — drop the half-registered VM so
            // the picker stays consistent, and say what happened right here
            // in the sheet (the terminal doesn't exist yet).
            guard case .connected = vm.connectionState else {
                isStartingNew = false
                connectError = vm.errorMessage
                    ?? "Couldn't reach \(host.displayName) — check the host and your SSH credentials."
                sessionManager.disconnect(key: key)
                return
            }
            await vm.applyTmuxChoice(choice)
            isStartingNew = false
            // The attach moment — this is what earns a Recent row (macOS
            // records the same moment: a session you actually entered).
            RecentLaunchStore.shared.record(host: host, sessionName: name)
            // Refresh the lister so the new session appears in the picker
            // next time and keeps our attached/unattached split correct.
            await lister.refresh()
            onSessionReady(key)
        }
    }
}
