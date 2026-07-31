import SwiftUI
import BentoTerminalCore

struct HostListView: View {
    @EnvironmentObject private var hostStore: HostStore
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var relayStore: RelayDaemonStore
    @State private var showAddHost = false
    @State private var showRelayPair = false
    @State private var relayPairPrefill: PendingRelayPair?
    @State private var showOnboarding = false
    @State private var showSettings = false
    @State private var editingHost: Host?
    @State private var searchText = ""

    private var filteredHosts: [Host] {
        if searchText.isEmpty { return hostStore.hosts }
        return hostStore.hosts.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText) ||
            $0.hostname.localizedCaseInsensitiveContains(searchText) ||
            $0.username.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var isCompletelyEmpty: Bool {
        hostStore.hosts.isEmpty && relayStore.daemons.isEmpty
    }

    var body: some View {
        Group {
            if isCompletelyEmpty {
                WelcomeFlowView(
                    onScanPair: { showRelayPair = true },
                    onAddSSH:   { showAddHost = true }
                )
            } else {
                populatedForm
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
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showRelayPair = true
                    } label: {
                        Label("Pair Mac via relay…", systemImage: "macbook.and.iphone")
                    }
                    Button {
                        showAddHost = true
                    } label: {
                        Label("Add SSH host…", systemImage: "server.rack")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.bentoEmerald)
                }
                .accessibilityIdentifier("plus")
            }
        }
        .sheet(isPresented: $showAddHost) {
            NavigationStack {
                HostEditView(mode: .add) { host in
                    hostStore.add(host)
                }
            }
        }
        .sheet(isPresented: $showRelayPair) {
            RelayPairView(prefill: relayPairPrefill)
        }
        .onChange(of: relayStore.pendingPair) { _, new in
            guard let new else { return }
            relayPairPrefill = new
            showRelayPair = true
            relayStore.pendingPair = nil
        }
        .onAppear {
            if let pending = relayStore.pendingPair {
                relayPairPrefill = pending
                showRelayPair = true
                relayStore.pendingPair = nil
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
    }

    @ViewBuilder
    private var populatedForm: some View {
        Form {
            if !sessionManager.activeSessions.isEmpty {
                Section {
                    ForEach(sessionManager.activeSessions) { entry in
                        ActiveSessionRow(entry: entry)
                            .environmentObject(sessionManager)
                    }
                } header: {
                    BentoFormHeader("Active")
                }
                .bentoSectionStyle()
            }

            if !relayStore.daemons.isEmpty {
                Section {
                    ForEach(relayStore.daemons) { daemon in
                        NavigationLink(value: HostNavigation.sessions(Host.fromRelayDaemon(daemon))) {
                            RelayDaemonRow(daemon: daemon)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                relayStore.delete(daemon)
                            } label: {
                                Label("Unpair", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    BentoFormHeader("My Computers")
                }
                .bentoSectionStyle()
            }

            if filteredHosts.isEmpty && !hostStore.hosts.isEmpty {
                Section {
                    Text("No hosts match \u{201C}\(searchText)\u{201D}")
                        .font(.subheadline)
                        .foregroundStyle(Color.bentoInkDim)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                }
                .bentoSectionStyle()
            } else if !filteredHosts.isEmpty {
                Section {
                    ForEach(filteredHosts) { host in
                        NavigationLink(value: HostNavigation.sessions(host)) {
                            HostRow(
                                host: host,
                                isConnected: sessionManager.activeSessions.contains(where: { $0.key.hostID == host.id })
                            )
                        }
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
                } header: {
                    BentoFormHeader("SSH Hosts")
                }
                .bentoSectionStyle()
            }
        }
        .bentoForm()
        .searchable(text: $searchText, prompt: "Search hosts")
    }
}

enum HostNavigation: Hashable {
    case sessions(Host)
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

/// Relay/Mac row in the My Computers section.
struct RelayDaemonRow: View {
    let daemon: RelayDaemon

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.bentoVeg.opacity(0.16))
                Image(systemName: "macbook")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.bentoVeg)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(daemon.displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.bentoInk)
                    .lineLimit(1)
                Text("Paired \(daemon.pairedAt, style: .relative) ago")
                    .font(.caption)
                    .foregroundStyle(Color.bentoInkDim)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
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
            sessionManager.navigationPath = [.sessions(entry.host)]
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
