import BentoTmuxKit
import BentoFoundationKit
import BentoSessionKit
import BentoUISharedKit
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import Combine

// MARK: - TerminalWindowManager: view-model bindings

extension TerminalWindowManager {
    /// Active tab → toolbar. The centre strip IS the window list now, so it has
    /// to rebuild whenever the session's windows or its current window change —
    /// a window opened from a tmux command line shows up here too.
    func rebindActiveToolbar(_ tab: SessionTab) {
        activeCancellables.removeAll()
        tab.viewModel.$windows
            .combineLatest(tab.viewModel.$activeWindowID)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak tab] _, _ in
                guard let self, let tab, tab === self.activeTab else { return }
                self.rebuildTabBar()
            }
            .store(in: &activeCancellables)
        // Mode drives the toolbar's Tiled|List switch and the sidebar (List
        // only). A single-pane session has no switch (`SessionChrome`), so it
        // also follows
        // the session's pane and window counts. The values are taken from the
        // publishers rather than re-read: `@Published` emits BEFORE the
        // property is assigned.
        tab.viewModel.$sessionMode
            .combineLatest(tab.viewModel.$sessionPanes.map(\.count),
                           tab.viewModel.$windows.map(\.count))
            .map { mode, panes, windows -> TmuxSessionMode? in
                SessionChrome.showsModeSwitch(paneCount: panes, windowCount: windows) ? mode : nil
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak tab] mode in
                guard let self, let tab, tab === self.activeTab else { return }
                self.toolbar.setSessionMode(mode)
                self.updateSidebar()
                BentoTerminalWindow.refreshNewItemTitle()
            }
            .store(in: &activeCancellables)
        // The take-over banner. Its own subscription rather than a ride on the
        // pane/window churn: it changes rarely (and only after the view model
        // has let one answer settle), and it must still land on a window that is
        // otherwise doing nothing — the canvas can be taken away from a session
        // nobody is touching.
        tab.viewModel.$sessionSizeMismatch
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak tab] mismatch in
                guard let self, let tab, tab === self.activeTab else { return }
                self.toolbar.sizeMismatch = mismatch
            }
            .store(in: &activeCancellables)
        // The dock's directory tree follows the FOCUSED pane: switching window
        // (⌘1..9) or selecting another tiled pane changes activePaneID, so
        // re-root the tree on it (fires immediately for the newly-active tab
        // too — its initial value seeds the first load).
        //
        // …and it follows `cd` inside that pane: tmux pushes each pane's
        // directory (`paneWorkingDirectories`, a `refresh-client -B`
        // subscription — nothing else would tell us, a process changing
        // directory raises no event). Keyed on the (pane, directory) PAIR so a
        // pane switch is one reload, not one per publisher. On a tmux too old
        // to push, the directory stays nil and this is the pane switch alone.
        tab.viewModel.$activePaneID
            .combineLatest(tab.viewModel.$paneWorkingDirectories)
            .map { pane, dirs in PaneDirectoryKey(pane: pane, directory: pane.flatMap { dirs[$0] }) }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak tab] _ in
                guard let self, let tab, tab === self.activeTab else { return }
                self.previewDock.refreshTree()
            }
            .store(in: &activeCancellables)
        // The toolbar's centre title: what runs in the focused pane and where.
        // Same directory source as the tree above (tmux pushes it on cd); the
        // command comes off the list-panes poll. A pane the subscription has
        // not reported yet is asked once — otherwise a fresh window, or any
        // window on a tmux too old to push, would show no path at all.
        tab.viewModel.$activePaneID
            .combineLatest(tab.viewModel.$paneWorkingDirectories,
                           tab.viewModel.$sessionPanes)
            .map { pane, dirs, panes in
                PaneLocationKey(
                    pane: pane,
                    directory: pane.flatMap { dirs[$0] },
                    command: pane.flatMap { id in panes.first { $0.id == id }?.currentCommand })
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak tab] key in
                guard let self, let tab, tab === self.activeTab else { return }
                self.applyLocationTitle(key, tab: tab)
            }
            .store(in: &activeCancellables)
    }

    private func applyLocationTitle(_ key: PaneLocationKey, tab: SessionTab) {
        var directory = key.directory
        if directory == nil, let pane = key.pane {
            if let q = queriedDirectory, q.pane == pane {
                directory = q.path
            } else if let paneVM = tab.viewModel.paneViewModels.first(where: { $0.paneID == pane }) {
                Task { [weak self, weak tab] in
                    guard let path = await paneVM.currentWorkingDirectory(),
                          let self, let tab, tab === self.activeTab,
                          tab.viewModel.activePaneID == pane else { return }
                    self.queriedDirectory = (pane, path)
                    self.applyLocationTitle(key, tab: tab)
                }
            }
        }
        let text = PaneLocationTitle.text(
            command: key.command, directory: directory,
            sshHost: tab.id.server.sshHost,
            home: NSHomeDirectory())
        toolbar.setLocation(text ?? displayTitle(for: tab))
    }

    /// Each tab's pane status + live session name drive its tab in the strip.
    func subscribe(_ tab: SessionTab) {
        var bag = Set<AnyCancellable>()
        tab.viewModel.$panesWorking
            .combineLatest(tab.viewModel.$panesAwaiting,
                           tab.viewModel.$panesDoneUnseen,
                           tab.viewModel.$activeTmuxSessionName)
            .receive(on: RunLoop.main)
            .sink { [weak self, weak tab] _, _, _, name in
                guard let self else { return }
                if let tab, let name { self.migrateSessionKey(of: tab, to: name) }
                self.rebuildTabBar()
            }
            .store(in: &bag)
        // Liveness, from this window's own control channel (see
        // `sessionListChanged`). The generation counter — not the array — is
        // what is observed, so only a genuinely fresh answer from the server
        // counts as a poll.
        tab.viewModel.$sessionListGeneration
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak tab] generation in
                guard let self, let tab else { return }
                self.sessionListChanged(
                    generation: generation, names: tab.viewModel.availableTmuxSessions)
            }
            .store(in: &bag)
        subscribeFailure(tab, into: &bag)
        // `ssh` asking for something. Until this existed, the question went into
        // the control-mode stream where nothing rendered it and nothing could
        // answer it, so a password-authenticated host simply timed out after
        // twelve seconds — and blamed tmux, which was innocent.
        tab.viewModel.$authPrompt
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak tab] prompt in
                guard let prompt, let self, let tab else { return }
                self.presentAuthPrompt(tab: tab, prompt: prompt)
            }
            .store(in: &bag)
        tabCancellables[ObjectIdentifier(tab)] = bag
    }

    /// A session that could not be brought up at all — the one subscription a
    /// plain window has too.
    ///
    /// `showError` has existed on the view model for as long as iOS has had
    /// an alert bound to it; on macOS nothing was ever bound, so the flag
    /// was raised into a void. The visible result was a window that simply
    /// sat there — most reliably when the ssh host had no tmux, where the
    /// remote's own `tmux: command not found` was already in hand and still
    /// nobody was told. Reported as "the app crashed", because a window that
    /// does nothing forever is indistinguishable from one.
    func subscribeFailure(_ tab: SessionTab, into bag: inout Set<AnyCancellable>) {
        tab.viewModel.$showError
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak tab] show in
                guard show, let self, let tab else { return }
                self.presentSessionFailure(tab: tab)
            }
            .store(in: &bag)
    }

    /// Ask for the password / passphrase / code that `ssh` is waiting on, and
    /// type it into the connection.
    ///
    /// The prompt is shown verbatim: which of several 2FA methods a host is
    /// asking for is exactly the thing a paraphrase would lose.
    private func presentAuthPrompt(tab: SessionTab, prompt: SSHAuthPrompt) {
        guard let window, authPromptAlert == nil else { return }

        let alert = NSAlert()
        alert.messageText = "\(tab.viewModel.host.name) is asking for \(prompt.kind.noun)"
        alert.informativeText = tab.viewModel.authPromptRejected
            ? "That didn’t work. \(prompt.text)"
            : prompt.text
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        let remember = NSButton(checkboxWithTitle: "Remember in Keychain", target: nil, action: nil)
        remember.state = .on
        let accessory = NSStackView(views: prompt.isStorable ? [field, remember] : [field])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 8
        accessory.frame = NSRect(x: 0, y: 0, width: 260, height: prompt.isStorable ? 52 : 22)
        alert.accessoryView = accessory
        // Without this the sheet opens with the buttons focused and the first
        // thing typed goes nowhere.
        alert.window.initialFirstResponder = field

        authPromptAlert = alert
        alert.beginSheetModal(for: window) { [weak self, weak tab] response in
            guard let self else { return }
            self.authPromptAlert = nil
            guard let tab else { return }
            if response == .alertFirstButtonReturn {
                tab.viewModel.submitAuthPrompt(field.stringValue,
                                               remember: prompt.isStorable && remember.state == .on)
            } else {
                // Cancelling an auth prompt cancels the connection: there is no
                // session behind this window to fall back to.
                tab.viewModel.cancelAuthPrompt()
                self.window?.close()
            }
        }
    }

    /// Show why a session never came up, and close the window with it — there
    /// is nothing behind this window to go back to.
    private func presentSessionFailure(tab: SessionTab) {
        guard let window, !failureAlertShown else { return }
        failureAlertShown = true
        if tab.viewModel.tmuxIsMissing {
            presentMissingTmux(tab: tab, in: window)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Couldn’t open “\(tab.id.displayName)”"
        // The view model puts the remote's own stderr in here when it has it
        // (see `failWithRemoteDiagnosis`) — that text is the whole point of the
        // alert, so it is shown verbatim rather than summarised away.
        alert.informativeText = tab.viewModel.errorMessage
            ?? "The session could not be started."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { [weak self] _ in
            self?.window?.close()
        }
    }

    /// The host has no tmux: say so, give the install commands as selectable
    /// text (one per line — which one applies is the user's to know, so
    /// nothing copies both at once), and offer the way in that doesn't need
    /// it: a plain shell on the same host.
    private func presentMissingTmux(tab: SessionTab, in window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = MissingTmuxCopy.title
        alert.informativeText = MissingTmuxCopy.installPrompt
        alert.alertStyle = .warning
        let commands = NSTextField(wrappingLabelWithString:
            MissingTmuxCopy.installCommands.joined(separator: "\n"))
        commands.isSelectable = true
        commands.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        commands.frame = NSRect(x: 0, y: 0, width: 260, height: 40)
        alert.accessoryView = commands
        alert.addButton(withTitle: MissingTmuxCopy.connectPlain)
        alert.addButton(withTitle: "Cancel")
        let sshHost = tab.id.server.sshHost
        alert.beginSheetModal(for: window) { [weak self] response in
            // Close this window first: the plain shell opens as a window of
            // its own, and a dead session window has nothing left to show.
            self?.window?.close()
            guard response == .alertFirstButtonReturn else { return }
            if let sshHost {
                BentoTerminalWindow.newSSHWindow(host: sshHost)
            } else {
                BentoTerminalWindow.newWindowNoTmux()
            }
        }
    }

    /// A tmux rename — ours or another client's (`%session-renamed`) — changes
    /// the session's identity, and `sessionKey` IS that identity everywhere:
    /// the strip order, the active selection, persistence, and the kill CLI
    /// target. The key must follow, or the old name haunts the strip forever
    /// (the loaded tab keeps it "present" past every prune) while the new name
    /// shows up as a phantom dormant session — and Kill Session silently kills
    /// a name that no longer exists.
    private func migrateSessionKey(of tab: SessionTab, to name: String) {
        let old = tab.id
        guard !name.isEmpty, name != old.name else { return }
        // The SERVER doesn't change under a rename — only the name on it. A
        // remote `bento` renamed to `work` is still on that host, and carrying
        // the server across is what keeps it from colliding with a local `work`.
        let new = TmuxSessionID(server: old.server, name: name)
        // Killing a session does NOT detach its clients — tmux parks them on
        // another session. So "my session is now called X" has two meanings: a
        // rename (X is mine), or my session died and I've been re-homed onto
        // someone else's. If a window already shows X, this is the second case
        // and there is nothing here to keep: two windows on one session is a
        // duplicate, and the poll would never close it because X is alive.
        if let other = BentoTerminalWindow.manager(for: new.key), other !== self {
            window.close()
            return
        }
        tab.id = new
        // Drop the old name from a not-yet-refreshed poll snapshot so the next
        // one doesn't read this window's session as gone.
        localServerSessions.removeAll { $0.rawValue == old.name }
        absentPolls = 0
        // A switch (or rename) in the window you are using: that is now the
        // session in use. One in a background window changes nothing about
        // what you were looking at.
        if window.isKeyWindow || window.isMainWindow {
            BentoTerminalWindow.recordSessionInUse(tab.id)
        }
        // The pane host keys the sidebar by session; a switched session gets a
        // fresh one bound to the same view model.
        updateSidebar()
        MacAwaitingNotifier.shared.clear(sessionKey: old.key)
    }
}

/// What the dock's directory tree is rooted on: the focused pane and the
/// directory tmux last pushed for it (nil until pushed, or on tmux < 3.2).
private struct PaneDirectoryKey: Equatable {
    let pane: TmuxPaneID?
    let directory: String?
}

private struct PaneLocationKey: Equatable {
    let pane: TmuxPaneID?
    let directory: String?
    let command: String?
}

/// The toolbar's centre title: `<program> · <path>`, or just `<path>` while the
/// pane sits at a bare shell prompt (the shell's name says nothing). A remote
/// session leads with its host — the same path on two machines is two places.
enum PaneLocationTitle {
    static func text(command: String?, directory: String?,
                     sshHost: String?, home: String) -> String? {
        let program = command.flatMap { cmd -> String? in
            let trimmed = cmd.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty || PaneStatusOption.isInteractiveShell(trimmed) ? nil : trimmed
        }
        var place: String?
        if let directory, !directory.isEmpty {
            // `~` only for this Mac: a remote home is a different directory, and
            // its path is not ours to guess.
            place = sshHost == nil ? abbreviate(directory, home: home) : directory
        }
        if let sshHost {
            place = place.map { "\(sshHost): \($0)" } ?? sshHost
        }
        switch (program, place) {
        case let (p?, l?): return "\(p) · \(l)"
        case let (p?, nil): return p
        case let (nil, l?): return l
        default: return nil
        }
    }

    static func abbreviate(_ path: String, home: String) -> String {
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
#endif
