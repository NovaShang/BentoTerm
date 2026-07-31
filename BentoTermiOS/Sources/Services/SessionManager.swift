import Foundation
import BentoTerminalCore
import SwiftUI
import SwiftTmux
import UIKit

/// Identity of a single live session = (host, tmux session name).
/// `tmuxSessionName` is the empty string for a "no tmux" raw-shell session;
/// at most one such session per host.
struct SessionKey: Hashable {
    let hostID: UUID
    let tmuxSessionName: String
}

/// Central registry of live `TerminalViewModel` instances.
///
/// One VM owns one SSH connection. A host can have multiple concurrent VMs —
/// one per attached tmux session — and each is fully independent. Listing
/// tmux sessions on a host happens through a *separate* short-lived SSH (see
/// `listTmuxSessions(host:)`) so discovery is decoupled from any attached
/// control channel.
@MainActor
final class SessionManager: ObservableObject {
    static let shared = SessionManager()

    struct SessionEntry: Identifiable {
        var id: SessionKey { key }
        let key: SessionKey
        let host: Host
        let viewModel: TerminalViewModel
        var lastActiveAt: Date
    }

    @Published private(set) var activeSessions: [SessionEntry] = []

    /// Driven by `NavigationStack(path:)` in `BentoApp`.
    @Published var navigationPath: [HostNavigation] = []

    /// Transient toast text for the host list (e.g. "Disconnected oldest session to free a slot").
    @Published var evictionNotice: String? = nil

    let maxSessions: Int
    private let liveActivity = AggregateLiveActivityController()

    /// Non-published cache so SwiftUI `body` can resolve the VM synchronously
    /// without triggering "modifying state during view update". Registration
    /// into the published `activeSessions` is deferred to the next runloop.
    private var cache: [SessionKey: TerminalViewModel] = [:]

    init(maxSessions: Int = 5) {
        self.maxSessions = maxSessions
    }

    // MARK: - Lookup

    /// Returns the cached `TerminalViewModel` for `key` if one exists.
    /// Side-effect free.
    func existingViewModel(for key: SessionKey) -> TerminalViewModel? {
        cache[key]
    }

    /// All active sessions for a given host (used to mark "Active" rows in
    /// the picker and to handle host-level operations).
    func sessions(forHostID hostID: UUID) -> [SessionEntry] {
        activeSessions.filter { $0.key.hostID == hostID }
    }

    /// Returns the cached `TerminalViewModel` for `(host, tmuxSessionName)`,
    /// or creates and registers a new one. Bumps `lastActiveAt`. May evict
    /// the oldest entry if registering a new session would exceed
    /// `maxSessions`.
    ///
    /// Safe to call from SwiftUI `body`: mutations to `@Published
    /// activeSessions` are deferred to the next runloop.
    func viewModel(for host: Host, tmuxSessionName: String) -> TerminalViewModel {
        let key = SessionKey(hostID: host.id, tmuxSessionName: tmuxSessionName)
        if let existing = cache[key] {
            Task { @MainActor in self.touch(key: key) }
            return existing
        }

        // Inject the iOS transport (SSH/relay) + platform services. The VM
        // itself is platform-agnostic and lives in BentoTerminalCore.
        let env = TerminalEnvironment(
            idealTerminalSize: {
                let screen = UIScreen.main.bounds
                let font = STTheme.terminalFont
                let cell = NSString(string: "M").size(withAttributes: [.font: font])
                let availH = screen.height - 110
                return (max(Int(screen.width / cell.width), 40),
                        max(Int(availH / cell.height), 20))
            },
            loadKeychainPassword: { key in try? KeychainService.shared.loadPassword(for: key) },
            onAwaitingTriggered: { HapticService.shared.awaitingTriggered() },
            onSessionUpdate: { [weak self] hostID, name, awaiting, prompt in
                self?.sessionDidUpdate(hostID: hostID, tmuxSessionName: name,
                                       awaitingPanes: awaiting, latestPrompt: prompt)
            }
        )
        let vm = TerminalViewModel(host: host, transport: SSHService(), environment: env)
        cache[key] = vm

        Task { @MainActor in
            self.evictIfNeeded(toFitNew: 1)
            if !self.activeSessions.contains(where: { $0.key == key }) {
                self.activeSessions.append(
                    SessionEntry(
                        key: key,
                        host: host,
                        viewModel: vm,
                        lastActiveAt: Date()
                    )
                )
            }
        }
        return vm
    }

    func touch(key: SessionKey) {
        guard let idx = activeSessions.firstIndex(where: { $0.key == key }) else { return }
        activeSessions[idx].lastActiveAt = Date()
    }

    // MARK: - Disconnect

    func disconnect(key: SessionKey) {
        if let vm = cache[key] {
            vm.disconnect()
        }
        cache.removeValue(forKey: key)
        activeSessions.removeAll { $0.key == key }
        liveActivity.sync(sessions: activeSessions)
    }

    func disconnectAll() {
        for vm in cache.values { vm.disconnect() }
        cache.removeAll()
        activeSessions.removeAll()
        liveActivity.sync(sessions: activeSessions)
    }

    func handleHostDeleted(_ host: Host) {
        for entry in activeSessions where entry.key.hostID == host.id {
            disconnect(key: entry.key)
        }
    }

    // MARK: - Scene phase

    /// Background-grace task: keeps the process (and thus the live SSH/relay
    /// connection) running for a short window after backgrounding, so a quick
    /// app switch doesn't drop the connection and force a reconnect on return.
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    /// Whether the grace ran out and we actually suspended the sessions. If we
    /// return to foreground before this flips, the connection is still live and
    /// no reconnect is needed.
    private var didSuspendInBackground = false

    func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .background:
            beginBackgroundGrace()
            liveActivity.sync(sessions: activeSessions)
        case .active:
            let reconnect = endBackgroundGrace()
            if reconnect {
                for entry in activeSessions {
                    Task { await entry.viewModel.resumeFromBackground() }
                }
            }
            liveActivity.sync(sessions: activeSessions)
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    /// Ask iOS for extra background time and DEFER the suspend until it runs
    /// out. iOS grants ~30s; within it the run loop keeps ticking so the WS /
    /// SSH connection and its keepalive pings stay alive. If iOS grants nothing
    /// we suspend immediately (the old behavior).
    private func beginBackgroundGrace() {
        didSuspendInBackground = false
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "bento.keepalive") { [weak self] in
            // Time's up — suspend so the next foreground reconnects cleanly.
            self?.suspendNow()
        }
        if bgTask == .invalid { suspendNow() }
    }

    /// Suspend every session now (grace expired or never granted) and release
    /// the background task. Idempotent.
    private func suspendNow() {
        guard !didSuspendInBackground else { return }
        didSuspendInBackground = true
        for entry in activeSessions { entry.viewModel.suspendForBackground() }
        endBgTask()
    }

    /// Called on foreground. Returns whether the sessions were suspended while
    /// backgrounded (→ caller should reconnect). If we returned within the
    /// grace window the connection is still live, so this returns false.
    @discardableResult
    private func endBackgroundGrace() -> Bool {
        let suspended = didSuspendInBackground
        endBgTask()
        didSuspendInBackground = false
        return suspended
    }

    private func endBgTask() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }

    // MARK: - State fan-in

    /// Called by `TerminalViewModel` whenever its phase or pane states change.
    /// Identifies the entry by hostID + the VM's current tmux session name.
    func sessionDidUpdate(hostID: UUID, tmuxSessionName: String, awaitingPanes: Int, latestPrompt: String) {
        let key = SessionKey(hostID: hostID, tmuxSessionName: tmuxSessionName)
        guard activeSessions.contains(where: { $0.key == key }) else { return }
        liveActivity.sync(
            sessions: activeSessions,
            spotlightKey: key,
            spotlightPrompt: latestPrompt
        )
    }

    // MARK: - LRU eviction

    private func evictIfNeeded(toFitNew n: Int) {
        while activeSessions.count + n > maxSessions {
            guard let victim = pickEvictionVictim() else { return }
            victim.viewModel.disconnect()
            cache.removeValue(forKey: victim.key)
            activeSessions.removeAll { $0.key == victim.key }
            let label = victim.key.tmuxSessionName.isEmpty
                ? victim.host.displayName
                : "\(victim.host.displayName) · \(victim.key.tmuxSessionName)"
            evictionNotice = "Disconnected \(label) to free a session slot"
        }
    }

    /// LRU choice prefers .ended → .suspended → least-recently-used active.
    private func pickEvictionVictim() -> SessionEntry? {
        let ended = activeSessions.filter { $0.viewModel.phase == .ended }
        if let oldest = ended.min(by: { $0.lastActiveAt < $1.lastActiveAt }) { return oldest }

        let suspended = activeSessions.filter { $0.viewModel.phase == .suspended }
        if let oldest = suspended.min(by: { $0.lastActiveAt < $1.lastActiveAt }) { return oldest }

        return activeSessions.min(by: { $0.lastActiveAt < $1.lastActiveAt })
    }
}

/// Short-lived SSH that runs `tmux ls` and returns the list of session names,
/// then disconnects. Used by the session picker so discovery is isolated from
/// all attached tmux -CC channels. Each call opens a brand new SSH.
@MainActor
final class TmuxLister: ObservableObject {
    @Published private(set) var sessions: [String] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    /// Dismissing the error alert clears the error so it doesn't re-present.
    func clearError() { error = nil }

    private let host: Host
    private let sshService = SSHService()
    private var captureBuffer = Data()
    private var captureMarker: String = ""
    private var captureContinuation: CheckedContinuation<String, Never>?

    init(host: Host) {
        self.host = host
        sshService.onDataReceived = { [weak self] data in
            guard let self else { return }
            Task { @MainActor in self.routeData(data) }
        }
    }

    deinit {
        sshService.disconnect()
    }

    func refresh() async {
        isLoading = true
        error = nil
        defer {
            isLoading = false
            sshService.disconnect()
        }

        await sshService.connect(host: host)
        guard case .connected = sshService.state else {
            error = "Failed to connect"
            return
        }
        sshService.startShell(cols: 80, rows: 24)
        try? await Task.sleep(for: .milliseconds(500))

        let token = String(UUID().uuidString.prefix(8))
        let startA = "__SPK_S_\(token)_"
        let startB = "_GO__"
        let startMarker = startA + startB
        let endA = "__SPK_E_\(token)_"
        let endB = "_DONE__"
        let endMarker = endA + endB
        let cmd =
            "printf '\\n%s%s\\n' '\(startA)' '\(startB)';" +
            " tmux ls 2>/dev/null;" +
            " printf '%s%s\\n' '\(endA)' '\(endB)'\n"

        let output = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            captureBuffer = Data()
            captureMarker = endMarker
            captureContinuation = cont
            sshService.write(cmd)

            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(5000))
                await MainActor.run {
                    guard let self else { return }
                    if let pending = self.captureContinuation {
                        self.captureContinuation = nil
                        let str = String(data: self.captureBuffer, encoding: .utf8) ?? ""
                        pending.resume(returning: str)
                    }
                }
            }
        }

        sessions = TmuxParsers.parseTmuxLs(output, startMarker: startMarker, endMarker: endMarker)
    }

    private func routeData(_ data: Data) {
        guard captureContinuation != nil else { return }
        captureBuffer.append(data)
        if let str = String(data: captureBuffer, encoding: .utf8),
           str.contains(captureMarker) {
            let cont = captureContinuation
            captureContinuation = nil
            cont?.resume(returning: str)
        }
    }
}
