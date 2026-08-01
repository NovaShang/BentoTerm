import SwiftUI
import BentoTerminalCore

/// Home — the pre-session state surface, iOS's answer to the Mac launcher
/// ("the app's lock screen"): what's running, what I was doing, where I can
/// go. Same sections, same order, same vocabulary as the Mac — re-judged
/// for the phone.
///
/// - Sessions first (attached + cached-not-connected, state language on the
///   left), then Recent, then the creation verbs, then hosts.
/// - Depth = 1: the terminal is the only push; everything else (create,
///   host editor, settings) is a sheet.
/// - All SSH round-trips live in the create sheet, never here and never in
///   the terminal — Home is static and instant.
struct HomeView: View {
    @EnvironmentObject private var hostStore: HostStore
    @EnvironmentObject private var sessionManager: SessionManager
    @ObservedObject private var recentLaunches = RecentLaunchStore.shared

    @State private var showAddHost = false
    @State private var showOnboarding = false
    @State private var showSettings = false
    @State private var editingHost: Host?
    @State private var searchText = ""
    @State private var createRequest: CreateSheetRequest?

    /// What the create sheet should be born with. `sheet(item:)` treats nil
    /// as dismissed, so dismissing the sheet also clears the request.
    struct CreateSheetRequest: Identifiable {
        let id = UUID()
        var initialHost: Host?
        var initialSessionName: String?
        var initialIntent: CreateIntent?
    }

    private var filteredHosts: [Host] {
        if searchText.isEmpty { return hostStore.hosts }
        return hostStore.hosts.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText) ||
            $0.hostname.localizedCaseInsensitiveContains(searchText) ||
            $0.username.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// Recent launches whose host still exists, newest first.
    private var recentRows: [RecentLaunchStore.Launch] {
        recentLaunches.launches.filter { l in hostStore.hosts.contains { $0.id == l.hostID } }
    }

    var body: some View {
        Group {
            if hostStore.hosts.isEmpty {
                WelcomeFlowView(onAddSSH: { showAddHost = true })
            } else {
                homeForm
            }
        }
        .background(Color.bentoShell.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle("")
        .overlay(alignment: .bottom) {
            if let notice = sessionManager.evictionNotice {
                BentoToast(text: notice)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(3))
                        sessionManager.evictionNotice = nil
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: sessionManager.evictionNotice)
        .toolbar {
            ToolbarItem(placement: .principal) {
                BentoWordmark()
            }
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showOnboarding = true
                } label: {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(Color.bentoInkDim)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: { showSettings = true }) {
                    Image(systemName: "gearshape")
                        .foregroundStyle(Color.bentoInkDim)
                }
            }
        }
        .sheet(isPresented: $showAddHost) {
            NavigationStack {
                HostEditView(mode: .add) { host in
                    hostStore.add(host)
                }
            }
        }
        .sheet(item: $editingHost) { host in
            NavigationStack {
                HostEditView(mode: .edit(host)) { updated in
                    hostStore.update(updated)
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showOnboarding) {
            HowBentoWorksView()
        }
        .sheet(item: $createRequest) { request in
            CreateSheetView(
                initialHost: request.initialHost,
                initialSessionName: request.initialSessionName,
                initialIntent: request.initialIntent,
                onSessionReady: { key in
                    // The sheet did the connect; now the terminal is the only
                    // thing on the stack above Home. Pushing under the sheet
                    // is fine — the dismissal animation reveals it.
                    sessionManager.navigationPath = [.terminal(key)]
                },
                onAddHost: { showAddHost = true }
            )
            .environmentObject(hostStore)
            .environmentObject(sessionManager)
        }
        .onChange(of: sessionManager.openRequest) { _, request in
            guard let request else { return }
            sessionManager.openRequest = nil
            createRequest = CreateSheetRequest(
                initialHost: hostStore.hosts.first { $0.id == request.hostID },
                initialSessionName: request.sessionName,
                initialIntent: request.intent
            )
        }
    }

    // MARK: - Form

    @ViewBuilder
    private var homeForm: some View {
        Form {
            sessionsSection
            if !recentRows.isEmpty {
                recentSection
            }
            verbsSection
            hostsSection
        }
        .bentoForm()
        .searchable(text: $searchText, prompt: "Search hosts")
    }

    /// The state surface: exactly the sessions currently open from this
    /// phone. The phone is a remote control — what it claims to see is what
    /// it actually holds a connection to; nothing cached, nothing guessed.
    @ViewBuilder
    private var sessionsSection: some View {
        Section {
            ForEach(sessionManager.activeSessions) { entry in
                ActiveSessionRow(entry: entry)
                    .environmentObject(sessionManager)
            }
            if sessionManager.activeSessions.isEmpty {
                Text("Nothing running right now. Sessions you open show up here.")
                    .font(.callout)
                    .foregroundStyle(Color.bentoInkDim)
            }
        } header: {
            BentoFormHeader("Sessions")
        }
        .bentoSectionStyle()
    }

    @ViewBuilder
    private var recentSection: some View {
        Section {
            ForEach(recentRows) { launch in
                Button {
                    openRecent(launch)
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.bentoSurfaceHi)
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color.bentoInkDim)
                        }
                        .frame(width: 34, height: 34)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(launch.hostLabel)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color.bentoInk)
                                .lineLimit(1)
                            Text(launch.sessionName)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Color.bentoInkDim)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)

                        Text(launch.date, style: .relative)
                            .font(.caption)
                            .foregroundStyle(Color.bentoInkMute)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            BentoFormHeader("Recent")
        }
        .bentoSectionStyle()
    }

    /// The creation verbs — same set as the Mac launcher, one concept one
    /// name. Agent leads: that's the hero flow on a phone. Each opens the
    /// create sheet with that intent; the sheet picks the host (and is
    /// where a new host gets added — that entry lives there, not here).
    @ViewBuilder
    private var verbsSection: some View {
        Section {
            Button {
                createRequest = CreateSheetRequest(initialIntent: .agent)
            } label: {
                Label("New Agent Session…", systemImage: "wand.and.stars")
            }
            Button {
                createRequest = CreateSheetRequest(initialIntent: .empty)
            } label: {
                Label("New Empty Session", systemImage: "plus.rectangle.on.rectangle")
            }
            Button {
                createRequest = CreateSheetRequest(initialIntent: .plainShell)
            } label: {
                Label("New Terminal without tmux", systemImage: "terminal")
            }
        } header: {
            BentoFormHeader("New")
        }
        .bentoSectionStyle()
    }

    @ViewBuilder
    private var hostsSection: some View {
        Section {
            if filteredHosts.isEmpty && !hostStore.hosts.isEmpty {
                Text("No hosts match \u{201C}\(searchText)\u{201D}")
                    .font(.subheadline)
                    .foregroundStyle(Color.bentoInkDim)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ForEach(filteredHosts) { host in
                    Button {
                        createRequest = CreateSheetRequest(initialHost: host)
                    } label: {
                        HostRow(
                            host: host,
                            isConnected: sessionManager.activeSessions.contains(where: { $0.key.hostID == host.id })
                        )
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button {
                            editingHost = host
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(Color.bentoSalmon)
                    }
                    .contextMenu {
                        Button {
                            editingHost = host
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            hostStore.delete(host)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        hostStore.delete(filteredHosts[index])
                    }
                }
            }
        } header: {
            BentoFormHeader("SSH Hosts")
        }
        .bentoSectionStyle()
    }

    // MARK: - Actions

    private func openRecent(_ launch: RecentLaunchStore.Launch) {
        guard let host = hostStore.hosts.first(where: { $0.id == launch.hostID }) else { return }
        sessionManager.open(
            session: SessionKey(hostID: host.id, tmuxSessionName: launch.sessionName),
            host: host
        )
    }
}

// MARK: - Wordmark

struct BentoWordmark: View {
    var body: some View {
        HStack(spacing: 8) {
            BentoMark(size: 22)
            Text("BentoTerm")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.bentoInk)
        }
    }
}

// MARK: - Rows

/// Host row in the SSH Hosts section. Designed to live in a native Form
/// row (no own card chrome — the Section provides the surface).
struct HostRow: View {
    let host: Host
    var isConnected: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isConnected ? Color.bentoEmerald.opacity(0.16) : Color.bentoSurfaceHi)
                Image(systemName: "server.rack")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isConnected ? Color.bentoEmerald : Color.bentoInkDim)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.bentoInk)
                    .lineLimit(1)
                Text("\(host.username)@\(host.hostname):\(host.port)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.bentoInkDim)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isConnected {
                StatusPill(label: "Connected", color: .bentoEmerald)
            } else if let lastConnected = host.lastConnected {
                Text(lastConnected, style: .relative)
                    .font(.caption)
                    .foregroundStyle(Color.bentoInkMute)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Active tmux session row.
struct ActiveSessionRow: View {
    let entry: SessionManager.SessionEntry
    @EnvironmentObject private var sessionManager: SessionManager
    @ObservedObject private var viewModel: TerminalViewModel
    @State private var showDisconnect = false

    init(entry: SessionManager.SessionEntry) {
        self.entry = entry
        self.viewModel = entry.viewModel
    }

    private var awaitingPanes: Int {
        viewModel.paneViewModels.reduce(0) { acc, p in
            if case .awaitingInput = p.paneState { return acc + 1 }
            return acc
        }
    }

    private var paneCount: Int { viewModel.paneViewModels.count }

    private var sessionLabel: String {
        entry.key.tmuxSessionName.isEmpty ? "Shell" : entry.key.tmuxSessionName
    }

    private var statusColor: Color {
        switch viewModel.phase {
        case .tmuxReady, .shellReady:                       return .bentoEmerald
        case .sshConnecting, .choosingSession, .starting:   return .bentoSalmon
        case .suspended:                                    return .bentoInkDim
        case .ended:                                        return .bentoRed
        }
    }

    private var isLive: Bool {
        switch viewModel.phase {
        case .tmuxReady, .shellReady: return true
        default: return false
        }
    }

    private var subtitle: String {
        if paneCount > 0 {
            return "\(sessionLabel) · \(paneCount) pane\(paneCount == 1 ? "" : "s")"
        }
        return sessionLabel
    }

    var body: some View {
        Button {
            sessionManager.open(session: entry.key, host: entry.host)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.16))
                        .frame(width: 22, height: 22)
                    if isLive {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                    } else {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(statusColor)
                            .scaleEffect(0.8)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.host.displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.bentoInk)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.bentoInkDim)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if awaitingPanes > 0 {
                    StatusPill(label: "\(awaitingPanes) waiting", color: .bentoSalmon)
                }
            }
            .padding(.vertical, 4)
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
}

// MARK: - Status pill

struct StatusPill: View {
    let label: String
    let color: Color
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}

// MARK: - Toast

struct BentoToast: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color.bentoSalmon)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Color.bentoInk)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule().fill(Color.bentoSurface)
        )
        .overlay(
            Capsule().strokeBorder(Color.bentoBorder, lineWidth: 1)
        )
    }
}
