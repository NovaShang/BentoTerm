import SwiftUI
import BentoTmuxKit
import Combine
import BentoVoiceKit
import BentoAgentKit
import BentoSessionKit
import BentoFilePreviewKit
import BentoFoundationKit
import BentoGhosttyKit
import BentoUISharedKit

/// Bridges the UIKit terminal views into SwiftUI navigation.
/// The session has already been picked (and the SSH is up) before this view
/// is pushed; the view model comes in, the voice controller is owned here —
/// voice input exists only inside a terminal, so the controller lives and
/// dies with this screen.
struct TerminalWrapperView: View {
    @ObservedObject var viewModel: TerminalViewModel
    @StateObject private var voiceController: VoiceInputController

    init(viewModel: TerminalViewModel) {
        self.viewModel = viewModel
        _voiceController = StateObject(wrappedValue: VoiceInputController())
    }

    /// Route results into this session's VM — the same wiring the macOS host
    /// uses (GhosttyTiledPaneHost wires `viewModel.handleVoiceResult`).
    ///
    /// Wired on appear, NOT in `init`: a `@StateObject`'s wrappedValue is not
    /// final until the view is mounted — an instance captured in init can be
    /// discarded and replaced, leaving `onResult` set on a dead instance while
    /// ComposeBar talks to the live one (compose send then silently dropped).
    private func wireVoiceController() {
        voiceController.onResult = { [weak viewModel] result in
            viewModel?.handleVoiceResult(result)
        }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var showSettings = false
    /// In-session immersive fullscreen (hides the nav bar; its buttons float
    /// as glass discs). Pure UI state — deliberately not in the VM (which
    /// macOS shares) and not a size-class change (which would remount the
    /// terminal, see `chrome`).
    @State private var isFullscreen = false
    @State private var showOnboarding: Bool = GestureOnboardingOverlay.shouldShow
    @State private var sizingResolved = false
    @State private var showMixedFlattenAlert = false
    /// One-shot notices driven by TipCenter (design doc §6): a transient toast
    /// plus the anchored teaching cards. Nil / false when nothing to say.
    @State private var tipToast: String?
    @State private var showStateLegend = false
    @State private var showParallelTip = false
    @State private var showVoiceAdvancedTip = false
    @State private var showQwenSuggestion = false
    @State private var parallelTipTask: Task<Void, Never>?
    @ObservedObject private var tips = TipCenter.shared
    @State private var showSplitSheet = false
    @State private var pendingCloseWindow: TmuxWindowID?
    /// Kill Session is destructive AND irreversible (every window/pane dies), so
    /// it goes through a confirmation before it runs.
    @State private var pendingKillSession = false
    /// A take-over waiting on confirmation — set only when a NAMED device is
    /// being dispossessed (see `SessionSizeMismatch.needsConfirmation`).
    @State private var pendingSizeTakeover: SessionSizeMismatch?
    /// iPad only: which split-view columns are up. Driven by the mode, never by
    /// the user (see `syncSidebarVisibility`).
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .detailOnly
    /// Reaches the live pane container (see PaneContainerBridge).
    @StateObject private var paneBridge = PaneContainerBridge()
    /// Keyboard top edge in global (screen) coordinates; nil while hidden.
    /// Tracked ONCE here and shared by both floating keyboard bars (compose +
    /// quick-keys) so they move with the same animated value.
    @State private var keyboardTopGlobal: CGFloat?

    /// The quick-keys bar floats whenever the raw keyboard is up and nothing
    /// else owns the bottom strip (compose bar, find bar).
    private var showRawKeyboardBar: Bool {
        keyboardTopGlobal != nil && !voiceController.showPreview && !paneBridge.findBarActive
    }

    private var host: Host { viewModel.host }

    // MARK: - Fullscreen

    /// The fullscreen choice is remembered per DEVICE (not per host/session),
    /// so a phone that works in fullscreen comes back fullscreen and an iPad's
    /// manual toggle survives re-entry too. Keyed globally, mirroring how the
    /// choice is a personal UI preference, not a property of any session.
    private var fullscreenPreferenceKey: String { "fullscreenMode" }

    private func toggleFullscreen() {
        isFullscreen.toggle()
        UserDefaults.standard.set(isFullscreen, forKey: fullscreenPreferenceKey)
    }

    /// First mount: the saved choice wins on iPhone and iPad alike. A fresh
    /// mount doesn't fire the size-class onChange, so a phone that mounts in
    /// landscape still gets the auto-enter default on first run (no choice yet).
    private func restoreFullscreenPreference() {
        if let saved = UserDefaults.standard.object(forKey: fullscreenPreferenceKey) as? Bool {
            isFullscreen = saved
        } else if !isRegularWidth, verticalSizeClass == .compact {
            isFullscreen = true
        }
    }

    /// iPhone landscape auto-enters fullscreen. A saved choice always wins —
    /// rotation never overrides it — and once fullscreen, rotating to portrait
    /// never auto-exits: leaving fullscreen is a manual choice.
    private func syncFullscreenToOrientation() {
        guard !isRegularWidth else { return }   // iPad is manual-only
        guard UserDefaults.standard.object(forKey: fullscreenPreferenceKey) == nil else { return }
        if verticalSizeClass == .compact { isFullscreen = true }
    }

    /// The pane background as a SwiftUI color — the full-screen backdrop of
    /// the terminal screen (status-bar / nav-bar strips, home-indicator strip)
    /// and the window tab bar. Reads the terminal's LIVE reported background
    /// (via the bridge) so the strips fuse with whatever the terminal actually
    /// renders; falls back to the theme bg until the first report / after a
    /// theme change.
    private var paneBgColor: Color {
        // The terminal's live reported background (via the bridge), FUSED with
        // the foreground pane's running state — the full-screen backdrop, so
        // the now-transparent nav bar and window tab bar let it flow through
        // the top/bottom strips and match the reserved band below the toolbar.
        // Falls back to the theme bg until the first report / after a theme
        // change.
        let bg = paneBridge.terminalBgColor ?? ThemeStore.shared.current.bgColor
        if let signal = foregroundPaneSignal {
            return Color(uiColor: STTheme.fusedBackground(bg: bg, state: signal.state,
                                                          doneUnseen: signal.doneUnseen))
        }
        return Color(uiColor: bg)
    }

    /// The pane the backdrop speaks for (zoomed/focused, else active) and its
    /// state — same resolution as `PaneContainerVC.effectiveFocusID`. Re-read
    /// on every body render, which `stateVersion` (bumped each state poll)
    /// drives, so the backdrop tracks state changes.
    private var foregroundPaneSignal: (state: PaneState, doneUnseen: Bool)? {
        let id = viewModel.zoomedPaneID
            ?? (viewModel.paneViewModels.count == 1 ? viewModel.paneViewModels.first?.paneID : nil)
            ?? viewModel.activePaneID
        guard let id, let pvm = viewModel.paneViewModels.first(where: { $0.paneID == id }) else { return nil }
        return (pvm.paneState, pvm.agentFinishedUnseen)
    }

    /// Persistence key for the sizing choice (per host + tmux session).
    private var sessionKey: String {
        "\(host.id.uuidString).\(viewModel.activeTmuxSessionName ?? "default")"
    }

    /// iPad (regular width) shows List mode as a leading window sidebar; the
    /// phone (compact width) uses the bottom window tab bar instead.
    private var isRegularWidth: Bool { horizontalSizeClass == .regular }

    /// Bottom window tab bar: List mode's switcher on compact-width devices.
    /// Pure navigation chrome — the terminal above keeps showing the CURRENT
    /// window; tapping a tab is select-window only (zero zoom, zero resize).
    private var showsWindowTabs: Bool {
        viewModel.isTmuxReady && viewModel.sessionMode == .list && !isRegularWidth
    }

    /// A plain shell — no tmux, so nothing phrased in tmux vocabulary belongs
    /// on screen. Distinct from `!isTmuxReady`, which is also true of a tmux
    /// session that is merely still connecting.
    private var isPlain: Bool { viewModel.isPlainSession }

    /// The file browser needs a live SSH connection and a working directory —
    /// not tmux. It was gated on `isTmuxReady` and so vanished on plain
    /// sessions, which is exactly where a phone has no other way to reach a
    /// remote file.
    private var showsFileBrowser: Bool {
        viewModel.isTmuxReady || viewModel.phase == .shellReady
    }

    var body: some View {
        terminalChrome
            .sheet(isPresented: $showSettings) { SettingsView() }
            .alert("Connection Error", isPresented: $viewModel.showError) {
                Button("Retry") { viewModel.retry() }
                Button("Dismiss", role: .cancel) { dismiss() }
            } message: {
                Text(viewModel.errorMessage ?? "Unknown error")
            }
            .sheet(isPresented: $showSplitSheet) {
                NewWindowSheet(title: "Split — Path & Command") { path, command in
                    Task { await viewModel.splitPane(horizontal: true, seed: .custom(path: path, command: command)) }
                }
            }
            .alert(closeWindowAlertTitle, isPresented: Binding(
                get: { pendingCloseWindow != nil },
                set: { if !$0 { pendingCloseWindow = nil } }
            )) {
                Button("Close Window", role: .destructive) {
                    if let id = pendingCloseWindow { viewModel.closeWindow(id) }
                    pendingCloseWindow = nil
                }
                Button("Cancel", role: .cancel) { pendingCloseWindow = nil }
            } message: {
                Text("The processes running in it will be terminated.")
            }
            .alert(pendingSizeTakeover?.confirmTitle ?? "", isPresented: Binding(
                get: { pendingSizeTakeover != nil },
                set: { if !$0 { pendingSizeTakeover = nil } }
            )) {
                Button(pendingSizeTakeover?.actionTitle ?? "Take Over") {
                    pendingSizeTakeover = nil
                    viewModel.claimSessionSize()
                }
                Button("Cancel", role: .cancel) { pendingSizeTakeover = nil }
            } message: {
                Text(pendingSizeTakeover?.confirmMessage ?? "")
            }
            .alert("Kill this session?", isPresented: $pendingKillSession) {
                Button("Kill Session", role: .destructive) {
                    // Leave the screen now; the kill awaits tmux's reply before it
                    // tears the connection down (see `killSession`), and holding
                    // the alert open for that round trip would look like a hang.
                    Task { await viewModel.killSession() }
                    dismiss()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Every window and pane in this session is closed and its processes are terminated. This can't be undone.")
            }
            .onChange(of: viewModel.isTmuxReady) { _, ready in
                if ready {
                    resolveSizing()
                    // Populate the session switcher (PRD §3.6) once attached.
                    Task { await viewModel.refreshTmuxSessions() }
                }
            }
            .onAppear { if viewModel.isTmuxReady { resolveSizing() } }
            // ---- One-shot teaching moments (design doc §6). Each fires at the
            // user's FIRST encounter with the concept, once per install. ----
            .onChange(of: viewModel.agentsWaiting) { _, waiting in
                // The first amber pane is the first time the app "needs" the user:
                // the moment the color legend lands (§6.2).
                if waiting > 0, tips.shouldShow(.stateLegend) {
                    withAnimation { showStateLegend = true }
                }
            }
            .onChange(of: viewModel.agentsWorking) { _, working in
                handleWorkingChange(working)
            }
            .onChange(of: viewModel.isReconnecting) { was, now in
                // First successful reconnect → the persistence concept (§6.5).
                if was, !now, viewModel.isTmuxReady, tips.consume(.persistence) {
                    showTipToast("Your agents kept working while you were away — the tmux session runs on the host, not here. It stays alive until you close it.")
                }
            }
            .onChange(of: showsWindowTabs) { _, shown in
                if shown, tips.consume(.windowTabsIntro) {
                    showTipToast("Each tab is a tmux window holding one pane — switch with the tabs below. Each tab's dot is that window's status.")
                }
            }
            .onChange(of: viewModel.windows.count) { _, _ in maybeShowSidebarIntro() }
            .onChange(of: viewModel.sessionMode) { _, _ in maybeShowSidebarIntro() }
            .onChange(of: voiceController.voiceSendTotal) { _, n in
                handleVoiceSendMilestone(n)
            }
            .alert("Better Chinese recognition?", isPresented: $showQwenSuggestion) {
                Button("Switch") {
                    UserDefaults.standard.set("qwen", forKey: "speech_engine")
                }
                Button("Keep current", role: .cancel) {}
            } message: {
                Text("You seem to speak Chinese — the Qwen engine is much more accurate for 中文 and mixed 中英. Free, no setup, switch back anytime in Settings.")
            }
    }

    /// The terminal plus its floating chrome, kept separate from the modal /
    /// teaching chain so the compiler can type-check each half on its own.
    private var terminalChrome: some View {
        chrome
            .ignoresSafeArea(.keyboard)
            .onAppear {
                wireVoiceController()
                restoreFullscreenPreference()
            }
            // iPhone landscape → auto-fullscreen (unless a choice is saved);
            // no size-class change ever auto-exits fullscreen.
            .onChange(of: verticalSizeClass) { _, _ in syncFullscreenToOrientation() }
            .overlay(alignment: .top) { reconnectingBanner }
            .overlay { voiceOverlay }
            // The managed input surface: an inline bar riding the keyboard's top
            // edge (NOT a modal — the terminal stays visible and pans clear, so
            // you compose while watching output). Both keyboard bars float
            // through FloatingKeyboardBar, sharing the keyboard top tracked
            // above — switching modes is a pure overlay swap, the keyboard
            // never collapses. The hit target is just the bar, the rest of the
            // overlay passes touches through to the panes.
            .overlay(alignment: .bottom) {
                if showRawKeyboardBar,
                   let row = paneBridge.container?.focusedOrActiveVC?.accessoryView.makeRow() {
                    FloatingKeyboardBar(keyboardTopGlobal: keyboardTopGlobal,
                                        onHeightChanged: { _ in }) {
                        row
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if voiceController.showPreview {
                    ComposeBar(controller: voiceController, keyboardTopGlobal: keyboardTopGlobal)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: voiceController.showPreview)
            .animation(.easeInOut(duration: 0.2), value: showRawKeyboardBar)
            .onReceive(NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                guard let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                else { return }
                let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey]
                    as? Double ?? 0.25
                // Off-screen frame (hide / undock) → treat as no keyboard.
                let top: CGFloat? = end.minY >= UIScreen.main.bounds.maxY ? nil : end.minY
                withAnimation(.easeOut(duration: max(duration, 0.1))) {
                    keyboardTopGlobal = top
                }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillHideNotification)) { _ in
                withAnimation(.easeOut(duration: 0.25)) {
                    keyboardTopGlobal = nil
                }
            }
            .overlay { onboardingOverlay }
            .overlay(alignment: .top) { tipToastView }
            .overlay { stateLegendOverlay }
            .overlay(alignment: .top) { parallelTipCard }
            .overlay(alignment: .bottom) { voiceAdvancedTipCard }
    }

    /// Everything sizing-related now comes from the server (the view model
    /// adopts `window-size` + `@bento_size_owner` on attach), so first connect
    /// has nothing to resolve and — critically — nothing to WRITE. Writing a
    /// local default here is what let this device silently overrule a policy
    /// another device had chosen for the shared session.
    private func resolveSizing() {
        guard !sizingResolved, viewModel.isTmuxReady else { return }
        sizingResolved = true
        applyPhoneFocusDefault()
    }

    private func setSizing(_ mode: TerminalSizingMode) {
        // The view model owns the write: it puts `window-size` on the server and
        // records/clears ownership. Nothing is stored here — a per-device copy
        // of a shared decision is exactly the bug this replaced.
        viewModel.setSizingMode(mode)
    }

    /// Phones open a multi-pane tiling in Focus by default — an act-and-inform
    /// default instead of the old "Open in Focus Mode?" prompt. The transform
    /// is lossless and one toggle away from reversal, which is what makes the
    /// silent default safe. Complex external layouts (setMode returns false
    /// without force) are left untouched — never auto-flatten.
    private func applyPhoneFocusDefault() {
        guard UIDevice.current.userInterfaceIdiom == .phone,
              viewModel.isTmuxReady,
              viewModel.sessionStructure == .tiled,
              viewModel.paneViewModels.count > 1,
              !UserDefaults.standard.bool(forKey: "listModePrompt.\(sessionKey)")
        else { return }
        UserDefaults.standard.set(true, forKey: "listModePrompt.\(sessionKey)")
        Task {
            let ok = await viewModel.setMode(.list)
            if ok, tips.consume(.focusAutoSwitch) {
                showTipToast("Opened in Focus: each pane was moved into its own tmux window (break-pane), so one fills the screen. Parallel ⇄ Focus up top moves them back — nothing is closed.")
            }
        }
    }

    /// Show a transient, non-blocking teaching toast (auto-hides).
    private func showTipToast(_ text: String) {
        withAnimation { tipToast = text }
        Task {
            try? await Task.sleep(for: .seconds(5))
            withAnimation { if tipToast == text { tipToast = nil } }
        }
    }

    /// §6.1 — the parallel curriculum, driven by the working-agent count.
    private func handleWorkingChange(_ working: Int) {
        // Both boxes busy at once → the payoff line.
        if working >= 2, tips.consume(.parallelBothWorking) {
            showTipToast("This is Parallel — every pane in one tmux window, all working at once. Whoever needs you changes color.")
        }
        // The first solo agent has been working 10s (the user is idle,
        // watching) → suggest opening a second one.
        guard tips.shouldShow(.parallelSecondAgent) else { return }
        parallelTipTask?.cancel()
        guard working >= 1, viewModel.paneViewModels.count == 1, viewModel.windows.count <= 1 else { return }
        parallelTipTask = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled,
                  viewModel.agentsWorking >= 1,
                  tips.consume(.parallelSecondAgent) else { return }
            withAnimation { showParallelTip = true }
        }
    }

    /// §6.1 — iPad/Mac sidebar introduction, first time it appears with real
    /// content (≥ 2 windows in List mode on a regular-width screen).
    private func maybeShowSidebarIntro() {
        guard viewModel.windows.count >= 2,
              viewModel.sessionMode == .list,
              isRegularWidth,
              tips.consume(.sidebarIntro) else { return }
        showTipToast("One tmux window per row — tap to switch. The number is the window index you'd use with select-window; the icon shows who's working and who needs you.")
    }

    /// §6.4 + Qwen suggestion — voice-send milestones. The advanced gestures
    /// wait for the 3rd send (muscle memory first); the Chinese-engine
    /// suggestion lands right after the 1st send, while the experience of
    /// (possibly mediocre) recognition is fresh.
    private func handleVoiceSendMilestone(_ n: Int) {
        guard n > 0 else { return }
        if n >= 1,
           Locale.preferredLanguages.first?.hasPrefix("zh") == true,
           (UserDefaults.standard.string(forKey: "speech_engine") ?? "apple") == "apple",
           tips.consume(.qwenSuggestion) {
            showQwenSuggestion = true
        }
        if n >= 3, tips.shouldShow(.voiceAdvanced) {
            tips.markShown(.voiceAdvanced)
            withAnimation { showVoiceAdvancedTip = true }
        }
    }

    /// The session's chrome.
    ///
    /// iPad (regular width) uses the platform's split view, which is what makes
    /// the sidebar a full-height floating panel and gives EACH COLUMN its own
    /// toolbar — so the back button lands in the content region beside the
    /// sidebar rather than in a banner stretched over both (Files, Notes and
    /// Mail all read this way). The pushed navigation bar is hidden here for
    /// exactly that reason: one full-width bar above two columns reads as a lid
    /// over the UI, and it pushed the sidebar down out of the top.
    ///
    /// The phone has no sidebar, so it keeps the plain pushed bar. The branch is
    /// on SIZE CLASS, not on mode — it never flips under a live session, so the
    /// terminal is never remounted (and no PTY resized) by it.
    @ViewBuilder
    private var chrome: some View {
        if isRegularWidth {
            NavigationSplitView(columnVisibility: $sidebarVisibility) {
                WindowSidebar(viewModel: viewModel)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
                    // The sidebar is mode-driven, never user-toggled (the same
                    // rule the macOS window follows), so there's nothing for a
                    // toggle button to mean.
                    .toolbar(removing: .sidebarToggle)
            } detail: {
                terminalDetail
            }
            .navigationSplitViewStyle(.balanced)
            .toolbar(.hidden, for: .navigationBar)
            .onAppear { syncSidebarVisibility() }
            .onChange(of: showsWindowSidebar) { _, _ in syncSidebarVisibility() }
        } else {
            terminalDetail
        }
    }

    /// The terminal plus (on the phone) the window tab bar — the split view's
    /// detail column, and the whole screen on a phone. Owns the session toolbar.
    private var terminalDetail: some View {
        ZStack {
            // Full-screen pane backdrop. A plain Color with .ignoresSafeArea()
            // genuinely fills the status-bar / nav-bar strips above and the
            // home-indicator strip below — unlike `.background(ignoresSafeArea
            // Edges:)` on an in-safe-area view (extends by its zero insets,
            // i.e. nowhere) or a UIKit subview stretched past its parent's
            // bounds (SwiftUI clips it). The grid keeps its exact geometry:
            // tmux never resizes for this.
            paneBgColor.ignoresSafeArea()
            VStack(spacing: 0) {
                terminalSurface
                if showsWindowTabs {
                    WindowTabBar(viewModel: viewModel)
                }
            }
            // Landscape (compact vertical size class): the terminal — and in
            // List mode the window tab bar under it — runs to the very bottom
            // edge (PRD §2.2). Portrait: the bottom safe area stays reserved
            // for the grid, and the tab bar keeps resting above it. The
            // keyboard is ignored on `body` either way: it slides OVER the bar
            // (hiding it) and never resizes the page (PRD §2.6).
            .ignoresSafeArea(.container, edges: verticalSizeClass == .compact
                ? .bottom
                : (showsWindowTabs ? [] : .bottom))
        }
        // Fullscreen: drop the nav bar (its buttons float as glass discs).
        // Hiding the bar shrinks safeAreaInsets.top to the status bar, so the
        // grid reclaims the bar's 44pt by itself — pageRect needs no change.
        .modifier(FullscreenNavBar(isFullscreen: isFullscreen))
        // Standard system navigation bar (Liquid Glass on iOS 26, no override):
        // back + session-switcher on the left, the mode switch centered, the ⋯
        // menu on the right. HostSessionsView stops hiding the nav bar for this.
        .navigationBarTitleDisplayMode(.inline)
        // Transparent nav bar: the terminal background flows through so the top
        // fuses with the terminal instead of wearing the opaque app-shell color.
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: backTapped) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                }
                .accessibilityLabel("Sessions")
            }
            if isRegularWidth {
                ToolbarItem(placement: .topBarLeading) {
                    sessionTitle
                }
                // The centre already belongs to Parallel|Focus here, and the bar
                // is wide enough to carry the banner beside the session name.
                ToolbarItem(placement: .topBarLeading) {
                    if let mismatch = viewModel.sessionSizeMismatch {
                        sizeMismatchBanner(mismatch)
                    }
                }
                ToolbarItem(placement: .principal) {
                    if viewModel.isTmuxReady { modeToggle }
                }
            } else {
                // A phone's bar has one usable slot. While the canvas is
                // someone else's, that slot goes to the reason — the session
                // name is one tap away in the switcher and does not change.
                ToolbarItem(placement: .principal) {
                    if let mismatch = viewModel.sessionSizeMismatch {
                        sizeMismatchBanner(mismatch)
                    } else {
                        sessionTitle
                    }
                }
            }
            if showsFileBrowser {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { paneBridge.container?.presentFileBrowser() } label: {
                        Image(systemName: "folder")
                    }
                    .accessibilityLabel("Files")
                }
            }
            // iPad only: the fullscreen toggle lives in the bar next to the
            // overflow menu (iPhone folds it into the ⋯ menu instead).
            if isRegularWidth {
                ToolbarItem(placement: .topBarTrailing) {
                    fullscreenToggleButton
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                sessionMenu
            }
        }
        // Fullscreen floating chrome (glass discs over the pane background):
        // back top-left; Files + ⋯ top-right. One overlay to keep this modifier
        // chain type-checkable.
        .overlay { if isFullscreen { fullscreenOverlay } }
    }

    /// Fullscreen floating chrome as one overlay: top row (back left, Files +
    /// ⋯ right) above a spacer. The session name used to rest in the bottom
    /// strip — removed; the terminal owns the whole floor.
    private var fullscreenOverlay: some View {
        VStack {
            HStack {
                fullscreenBackButton
                Spacer()
                // Fullscreen has no bar to sit in, so the banner joins the
                // floating chrome row — the strip the discs already occupy —
                // rather than opening a new one over the terminal.
                if let mismatch = viewModel.sessionSizeMismatch {
                    sizeMismatchBanner(mismatch)
                    Spacer()
                }
                fullscreenTrailingButtons
            }
            .padding(.top, 8)
            Spacer()
        }
    }

    /// The sidebar is MODE-driven, never user-toggled (same rule as the macOS
    /// window): it exists exactly when List mode has a wide enough screen.
    private var showsWindowSidebar: Bool {
        viewModel.isTmuxReady && viewModel.sessionMode == .list && isRegularWidth
    }

    private func syncSidebarVisibility() {
        let want: NavigationSplitViewVisibility = showsWindowSidebar ? .all : .detailOnly
        guard sidebarVisibility != want else { return }
        withAnimation { sidebarVisibility = want }
    }

    private var terminalSurface: some View {
        SinglePaneSurface(
            viewModel: viewModel,
            voiceController: voiceController,
            sizingMode: viewModel.sizingMode,
            sizingOwnerIsMe: viewModel.sizingOwnerIsMe,
            isFullscreen: isFullscreen,
            bridge: paneBridge
        )
    }

    // MARK: - Overlays

    /// Top pill shown while an auto-reconnect loop is in flight, so the session
    /// never looks silently frozen after a drop / lock-screen suspend.
    @ViewBuilder
    private var reconnectingBanner: some View {
        if viewModel.isReconnecting {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(Color.bentoEmerald)
                Text("Reconnecting…")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.bentoInkDim)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.bentoSurface))
            .overlay(Capsule().strokeBorder(Color.bentoBorder, lineWidth: 1))
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.2), value: viewModel.isReconnecting)
        }
    }

    /// "This canvas isn't yours" — shown when the grid the session is drawn at
    /// stops matching what this device fits, in every sizing policy (the
    /// default `latest` has no owner to name and is exactly where the surprise
    /// comes from). Tapping makes this device the one that sets the size.
    ///
    /// It lives in the NAVIGATION BAR, not above the terminal, and that is
    /// load-bearing twice over. A strip in the layout would steal rows from a
    /// canvas that is already too big for the phone — the case this banner
    /// exists to explain. And shrinking the viewport changes the very grid the
    /// banner compares: under `smallest` a banner that pushed the device grid
    /// down could drag the window down with it, clear its own condition, and
    /// blink forever. Chrome that was already there perturbs nothing.
    @ViewBuilder
    private func sizeMismatchBanner(_ mismatch: SessionSizeMismatch) -> some View {
        Button {
            if mismatch.needsConfirmation {
                pendingSizeTakeover = mismatch
            } else {
                viewModel.claimSessionSize()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: TerminalSizingMode.thisDevice.symbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.stInkDim)
                VStack(alignment: .leading, spacing: 0) {
                    Text(mismatch.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.stInk)
                    Text("\(mismatch.actionTitle) · \(mismatch.compactDetail)")
                        .font(.caption2)
                        .foregroundStyle(Color.stInkDim)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.bentoSurface))
            .overlay(Capsule().strokeBorder(Color.bentoBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(mismatch.summary) \(mismatch.actionTitle).")
    }

    @ViewBuilder
    private var voiceOverlay: some View {
        if voiceController.showOverlay {
            GeometryReader { geo in
                let anchor = compassAnchor(in: geo)
                VoiceCompassView(controller: voiceController)
                .position(anchor)
            }
            .ignoresSafeArea()
            .transition(.scale.combined(with: .opacity))
        }
    }

    /// Keep the compass on screen when the press starts near an edge. It is
    /// centered on the touch point, so a press near the top clipped the transcript
    /// bubble, near the bottom clipped the cancel target (and it collided with the
    /// floating quick-keys toolbar), and near a side clipped the side targets.
    ///
    /// Clamp the ANCHOR rather than the view: the compass keeps its fixed internal
    /// layout (the four targets stay reachable at known offsets) and just stops
    /// short of the edges. Only what the content actually needs is reserved —
    /// clamping by the full half-height would yank the overlay to mid-screen and
    /// away from the finger.
    private func compassAnchor(in geo: GeometryProxy) -> CGPoint {
        typealias M = VoiceCompassView.Metrics
        let bounds = geo.frame(in: .local)
        let safe = geo.safeAreaInsets
        let margin: CGFloat = 8
        // The toolbar sits at the bottom, so the down target has to clear it too.
        let bottomReserve = safe.bottom + FloatingQuickKeysToolbar.reservedBand + margin

        let minX = bounds.minX + M.halfWidth + margin
        let maxX = bounds.maxX - M.halfWidth - margin
        let minY = bounds.minY + safe.top + M.reachUp + margin
        let maxY = bounds.maxY - bottomReserve - M.reachDown

        let p = voiceController.fingerScreenPosition
        // A screen too small for the ideal margins: center on that axis instead of
        // letting an inverted range flip the clamp.
        return CGPoint(x: minX <= maxX ? min(max(p.x, minX), maxX) : bounds.midX,
                       y: minY <= maxY ? min(max(p.y, minY), maxY) : bounds.midY)
    }

    @ViewBuilder
    private var onboardingOverlay: some View {
        if showOnboarding, case .connected = viewModel.connectionState {
            GestureOnboardingOverlay {
                GestureOnboardingOverlay.markDismissed()
                withAnimation { showOnboarding = false }
            }
            .transition(.opacity)
        }
    }

    // MARK: - Teaching overlays (TipCenter)

    /// Transient top toast for fire-and-forget lessons (Focus default,
    /// persistence, window tabs, sidebar, "this is parallel").
    @ViewBuilder
    private var tipToastView: some View {
        if let text = tipToast {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.bentoEmerald)
                    .padding(.top, 1)
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.bentoInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 420)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.bentoSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.bentoBorder, lineWidth: 1)
            )
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .onTapGesture { withAnimation { tipToast = nil } }
        }
    }

    /// The 4-color state legend — the product's mental-model key, presented
    /// the first time any pane turns amber (§6.2). Non-modal: terminal stays
    /// interactive around it.
    @ViewBuilder
    private var stateLegendOverlay: some View {
        if showStateLegend {
            StateLegendCard {
                tips.markShown(.stateLegend)
                withAnimation { showStateLegend = false }
            }
            .padding(.horizontal, 24)
            .transition(.scale(scale: 0.92).combined(with: .opacity))
        }
    }

    /// "Open a second agent" nudge, anchored under the top bar near the menus
    /// that can actually do it (§6.1).
    @ViewBuilder
    private var parallelTipCard: some View {
        if showParallelTip {
            VStack(alignment: .leading, spacing: 8) {
                Text("It's working — you don't have to wait.")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.bentoInk)
                Text(viewModel.sessionMode == .list
                     ? "Open a second agent: tap + in the window list — that's a new tmux window."
                     : "Open a second agent: ⋯ menu → Split Right (-h).")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.bentoInkDim)
                Button("Got it") { withAnimation { showParallelTip = false } }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.bentoEmerald)
            }
            .padding(14)
            .frame(maxWidth: 320)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.bentoSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.bentoBorder, lineWidth: 1)
            )
            .padding(.top, 52)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// Advanced voice gestures, taught after the 3rd successful send (§6.4).
    @ViewBuilder
    private var voiceAdvancedTipCard: some View {
        if showVoiceAdvancedTip {
            VStack(alignment: .leading, spacing: 8) {
                Text("Voice, level 2")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.bentoInk)
                Label {
                    Text("Slide **right** while holding: review & edit the text before it sends.")
                        .font(.system(size: 13)).foregroundStyle(Color.bentoInkDim)
                } icon: {
                    Image(systemName: "arrow.right").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.bentoEmerald)
                }
                Label {
                    Text("Slide **left**: turn plain words into a shell command.")
                        .font(.system(size: 13)).foregroundStyle(Color.bentoInkDim)
                } icon: {
                    Image(systemName: "arrow.left").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.bentoEmerald)
                }
                Button("Got it") { withAnimation { showVoiceAdvancedTip = false } }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.bentoEmerald)
            }
            .padding(14)
            .frame(maxWidth: 360)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.bentoSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.bentoBorder, lineWidth: 1)
            )
            .padding(.bottom, 90)
            .padding(.horizontal, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Top Bar

    /// Session name (primary) + host (subtitle). PRD §3.6: tapping the name is a
    /// quick session switcher — a menu of the host's tmux sessions, switch in
    /// place. Plain (non-tappable) text before tmux is attached.
    @ViewBuilder
    private var sessionTitle: some View {
        let label = VStack(spacing: 1) {
            // A plain session has no tmux name to show, and falling back to the
            // host printed it twice — once as the title, once under it. Name the
            // kind instead, the way the session list already does.
            Text(viewModel.activeTmuxSessionName ?? (isPlain ? "Shell" : host.displayName))
                .font(.headline).lineLimit(1)
            HStack(spacing: 4) {
                connectionDot
                Text(host.displayName).lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }

        if viewModel.isTmuxReady {
            Menu {
                ForEach(viewModel.availableTmuxSessions, id: \.self) { name in
                    Button { viewModel.switchSession(name) } label: {
                        if name == viewModel.activeTmuxSessionName {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
                Divider()
                Button { Task { await viewModel.refreshTmuxSessions() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            } label: {
                label
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
        } else {
            label
        }
    }

    /// The mode switch itself (a structure transformation shared by every
    /// attached device, not a view preference). The one confirmation:
    /// flattening a mixed external structure into List.
    private func selectMode(_ newMode: TmuxSessionMode) {
        // First interaction retires the intro dot — the user has found the switch.
        if tips.shouldShow(.modeToggleIntro) {
            tips.markShown(.modeToggleIntro)
        }
        guard newMode != viewModel.sessionMode else { return }
        // Leaving a focused (zoomed) pane before transforming keeps the result
        // visible.
        if let z = viewModel.zoomedPaneID {
            viewModel.toggleZoom(z)
        }
        Task {
            let ok = await viewModel.setMode(newMode)
            if !ok { showMixedFlattenAlert = true }
        }
    }

    /// Layout switch inside the ⋯ menu — the phone's home for it. An inline
    /// picker renders as a checkmark list; Focus leads, since a phone shows one
    /// pane anyway.
    private var modeSection: some View {
        Section("Layout") {
            Picker("Layout", selection: Binding(
                get: { viewModel.sessionMode },
                set: { selectMode($0) }
            )) {
                Label("Focus", systemImage: "rectangle").tag(TmuxSessionMode.list)
                Label("Parallel", systemImage: "square.split.2x2").tag(TmuxSessionMode.tiled)
            }
            .pickerStyle(.inline)
        }
    }

    /// iPad segmented control for the layout switch.
    private var modeToggle: some View {
        Picker("Mode", selection: Binding(
            get: { viewModel.sessionMode },
            set: { selectMode($0) }
        )) {
            Text("Parallel").tag(TmuxSessionMode.tiled)
            Text("Focus").tag(TmuxSessionMode.list)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        // Intro dot (§6): "two views, switch freely, nothing is lost" — a
        // quiet affordance marker, not a popover. Cleared on first use.
        .overlay(alignment: .topTrailing) {
            if tips.shouldShow(.modeToggleIntro) {
                Circle()
                    .fill(Color.bentoEmerald)
                    .frame(width: 7, height: 7)
                    .offset(x: 3, y: -3)
            }
        }
        .alert("Switch to Focus mode?", isPresented: $showMixedFlattenAlert) {
            Button("Flatten", role: .destructive) {
                Task { await viewModel.setMode(.list, force: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This session contains a complex layout created outside BentoTerm. Switching will flatten every pane into its own window.")
        }
    }

    /// Overflow menu — a native SwiftUI `Menu`. The BUG-010 scroll-reset mis-tap
    /// came from the live Windows list making a LONG menu recompute-and-reset
    /// while open: Focus mode now drops the Windows section entirely (the bottom
    /// WindowTabBar already lists every window) and Parallel keeps it — few
    /// windows, at the very bottom — so the menu never grows long enough to
    /// scroll. Kill Session / Close Window still confirm first (alerts below,
    /// which present after the menu dismisses).
    ///
    /// Split into content + label so the fullscreen floating chrome can render
    /// the same menu behind a glass disc (a Menu's label is the only part that
    /// can carry the glass).
    private var sessionMenuContent: some View {
        Group {
            // Same order as the Mac pane menu: create, then arrange, then the
            // session-wide policy — so the two platforms can be described with
            // one sentence instead of two.
            Button(action: toggleFullscreen) {
                Label(isFullscreen ? "Exit Fullscreen" : "Fullscreen",
                      systemImage: isFullscreen ? "arrow.down.right.and.arrow.up.left"
                                                : "arrow.up.left.and.arrow.down.right")
            }
            if viewModel.isTmuxReady {
                // The phone has no room for the segmented switch in the bar,
                // so the layout choice lives here instead (see modeSection).
                // Fullscreen shows it everywhere (the iPad bar's toggle is
                // floating then, and there is no bar to host the switch).
                if !isRegularWidth || isFullscreen { modeSection }
                splitSection
                layoutSection
                sessionSizeSection
            }
            Button { showSettings = true } label: {
                Label("Settings", systemImage: "gear")
            }
            if viewModel.isTmuxReady {
                windowsSection
                Button(role: .destructive) { pendingKillSession = true } label: {
                    Label("Kill Session", systemImage: "xmark.circle")
                }
            }
        }
    }

    private var sessionMenu: some View {
        Menu { sessionMenuContent } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 20))
        }
    }

    // MARK: - Fullscreen floating chrome

    /// The nav bar's buttons rehosted as floating glass discs over the pane
    /// background while fullscreen: back top-left, Files + ⋯ top-right, and
    /// the session name in the bottom (non-safe) strip.

    /// Bar button (iPad) — also the label source for the floating discs.
    private var fullscreenToggleButton: some View {
        Button(action: toggleFullscreen) {
            Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left"
                                           : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 16, weight: .medium))
        }
        .accessibilityLabel(isFullscreen ? "Exit Fullscreen" : "Fullscreen")
    }

    private var fullscreenBackButton: some View {
        Button(action: backTapped) {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.bentoInk)
                .frame(width: 40, height: 40)
        }
        .modifier(GlassChrome(shape: .circle))
        .accessibilityLabel("Sessions")
        .padding(.leading, 12)
    }

    private var fullscreenTrailingButtons: some View {
        HStack(spacing: 10) {
            if showsFileBrowser {
                Button { paneBridge.container?.presentFileBrowser() } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.bentoInk)
                        .frame(width: 40, height: 40)
                }
                .modifier(GlassChrome(shape: .circle))
                .accessibilityLabel("Files")
            }
            Menu { sessionMenuContent } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.bentoInk)
                    .frame(width: 40, height: 40)
                    .modifier(GlassChrome(shape: .circle))
            }
        }
        .padding(.trailing, 12)
    }

    /// Split section — Tiled only (List mode never shows a split entry: inside
    /// Bento you cannot build a third shape). The two seeded entries mirror
    /// List's window creation exactly.
    @ViewBuilder
    private var splitSection: some View {
        if viewModel.sessionMode == .tiled {
            Section("Split") {
                Button(action: { viewModel.splitPane(horizontal: true) }) {
                    Label("Split Right (-h)", systemImage: "rectangle.split.2x1")
                }
                Button(action: { viewModel.splitPane(horizontal: false) }) {
                    Label("Split Down (-v)", systemImage: "rectangle.split.1x2")
                }
                Button(action: { Task { await viewModel.splitPane(horizontal: true, seed: .duplicateCurrent) } }) {
                    Label("Split — Duplicate Current", systemImage: "plus.square.on.square")
                }
                Button(action: { showSplitSheet = true }) {
                    Label("Split — Path & Command…", systemImage: "terminal")
                }
            }
        }
    }

    /// tmux's named layouts — parity with the Mac pane menu. They were always
    /// available on the server; only macOS had ever offered them.
    @ViewBuilder
    private var layoutSection: some View {
        if viewModel.sessionMode == .tiled, viewModel.paneViewModels.count > 1 {
            Section("Layout") {
                ForEach(TmuxNamedLayout.all) { layout in
                    Button {
                        guard let window = viewModel.activeWindowID else { return }
                        Task { await viewModel.applyWindowLayout(window, layout: layout.slug) }
                    } label: {
                        Label(layout.label, systemImage: layout.symbol)
                    }
                }
            }
        }
    }

    /// The sticky sizing policy (see `TerminalSizingMode`). Two states, checked
    /// — not a "fit it now" button, because tmux recomputes a window's size
    /// from its clients and a one-shot push is undone by the next client.
    @ViewBuilder
    private var sessionSizeSection: some View {
        Section {
            ForEach(TerminalSizingMode.allCases, id: \.rawValue) { mode in
                Button { setSizing(mode) } label: {
                    if mode == viewModel.sizingMode {
                        Label(iosTitle(mode), systemImage: "checkmark")
                    } else {
                        Label(iosTitle(mode), systemImage: mode.symbol)
                    }
                }
            }
        } header: {
            // Naming the owner is the whole point on a second device: without it
            // the menu shows a checked mode that this device cannot act on.
            if viewModel.sizingMode == .thisDevice, let owner = viewModel.sizingOwner,
               !viewModel.sizingOwnerIsMe {
                Text("Session Size — set by \(owner.displayName)")
            } else {
                Text("Session Size")
            }
        }
    }

    /// Same states as the Mac, said in this device's words.
    private func iosTitle(_ mode: TerminalSizingMode) -> String {
        switch mode {
        case .tracking:   return "Follow the Active Device"
        case .smallest:   return "Fit Every Device"
        case .thisDevice: return "Size to This Device"
        }
    }

    /// Window ops: switch + close. Parallel(Tiled) ONLY, and it sits at the very
    /// bottom of the menu — Focus mode omits it because its bottom WindowTabBar
    /// already lists every window, and a long live list in the menu was the
    /// BUG-010 scroll-reset mis-tap. Creation lives in List's "+" affordances;
    /// there is no bare "New Window".
    @ViewBuilder
    private var windowsSection: some View {
        if viewModel.sessionMode == .tiled, viewModel.windows.count > 1 {
            Section("Windows") {
                ForEach(viewModel.windows) { window in
                    Button { viewModel.selectWindow(window.id) } label: {
                        if window.id == viewModel.activeWindowID {
                            Label(viewModel.windowDisplayName(window.id), systemImage: "checkmark")
                        } else {
                            Text(viewModel.windowDisplayName(window.id))
                        }
                    }
                }
                Button(role: .destructive) {
                    pendingCloseWindow = viewModel.activeWindowID
                } label: {
                    Label("Close Window", systemImage: "xmark.rectangle")
                }
            }
        }
    }

    private var closeWindowAlertTitle: String {
        let name = pendingCloseWindow.map { viewModel.windowDisplayName($0) } ?? ""
        return "Close “\(name)”?"
    }

    @ViewBuilder
    private var connectionDot: some View {
        switch viewModel.connectionState {
        case .connected: Circle().fill(.green).frame(width: 5, height: 5)
        case .connecting: ProgressView().scaleEffect(0.5)
        case .failed: Circle().fill(.red).frame(width: 5, height: 5)
        case .disconnected: Circle().fill(.secondary).frame(width: 5, height: 5)
        }
    }

    private func backTapped() {
        // If a pane is focused (zoomed), back exits focus first instead of
        // leaving the session — matches the drill-down mental model.
        if let z = viewModel.zoomedPaneID {
            viewModel.toggleZoom(z)
        } else {
            dismiss()
        }
    }
}

// MARK: - Single-pane / tiled surface bridge

/// SwiftUI bridge for the UIKit container that hosts the live terminal panes
/// (tiled, or one focused) plus the floating quick-keys toolbar.
/// Lets the SwiftUI chrome reach the live pane container. Only the container
/// knows which pane is focused and how to resolve its file context, so the
/// Files button has to ask it rather than rebuild that itself.
@MainActor final class PaneContainerBridge: NSObject, ObservableObject {
    weak var container: PaneContainerVC?

    /// The terminal's live reported background, so the SwiftUI backdrop
    /// (status-bar / nav-bar / home-indicator strips) fuses with the terminal
    /// instead of a static legacy hex. `nil` until the first surface report and
    /// after a theme change (surfaces re-report once the config reloads), at
    /// which point `paneBgColor` falls back to the theme bg.
    @Published var terminalBgColor: UIColor?

    /// The find bar is up (its field holds the keyboard) — the floating
    /// quick-keys bar must hide so the two don't both sit on the keyboard top.
    @Published var findBarActive = false

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(surfaceBackgroundChanged),
            name: .ghosttySurfaceBackgroundChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged),
            name: .terminalThemeChanged, object: nil)
    }

    @objc private func surfaceBackgroundChanged(_ note: Notification) {
        guard let surface = note.object as? GhosttyTerminalSurface,
              container?.owns(surface: surface) == true,
              let color = surface.reportedBackgroundColor else { return }
        terminalBgColor = color
    }

    @objc private func themeChanged() {
        terminalBgColor = nil   // surfaces re-report after the config reload
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}

struct SinglePaneSurface: UIViewControllerRepresentable {
    @ObservedObject var viewModel: TerminalViewModel
    /// Deliberately NOT @ObservedObject: only read in makeUIViewController.
    /// Observing it re-ran updateUIViewController (→ refreshPanes → a full
    /// layout pass) on every keystroke/touch the controller published.
    let voiceController: VoiceInputController
    var sizingMode: TerminalSizingMode
    /// Under `.thisDevice` only the owner may push a size, and only the owner's
    /// viewport matches the window — everyone else letterboxes.
    var sizingOwnerIsMe: Bool
    /// Fullscreen lets the grid reclaim the hidden nav bar's strip (pageRect
    /// reaches up into it). Not @ObservedObject-observed state: it only
    /// re-lays out the container, which updateUIViewController drives anyway.
    var isFullscreen: Bool
    /// Handed back to the SwiftUI chrome so the Files button can reach the
    /// focused pane's file context.
    let bridge: PaneContainerBridge

    func makeUIViewController(context: Context) -> PaneContainerVC {
        let vc = PaneContainerVC()
        bridge.container = vc
        vc.bridge = bridge
        vc.viewModel = viewModel
        vc.voiceController = voiceController
        vc.sizingMode = sizingMode
        vc.sizingOwnerIsMe = sizingOwnerIsMe
        vc.isFullscreen = isFullscreen

        if viewModel.isTmuxReady {
            vc.setupTmuxPanes()
        } else {
            vc.setupSinglePane()
            Task { @MainActor in
                if case .disconnected = viewModel.connectionState {
                    await viewModel.connect()
                }
            }
        }
        return vc
    }

    static func dismantleUIViewController(_ vc: PaneContainerVC, coordinator: ()) {
        // SwiftUI removed this representable (screen dismissed) — free the
        // ghostty surfaces NOW, before UIKit tears down the layer hierarchy.
        vc.teardownAll()
    }

    func updateUIViewController(_ vc: PaneContainerVC, context: Context) {
        bridge.container = vc
        vc.sizingMode = sizingMode
        vc.sizingOwnerIsMe = sizingOwnerIsMe
        vc.isFullscreen = isFullscreen
        if viewModel.isTmuxReady {
            if vc.singlePaneVC != nil {
                vc.setupTmuxPanes()
            } else {
                vc.refreshPanes()
            }
        }
    }
}

// MARK: - Pane Container

/// Hosts the live terminal panes. Two layouts (PRD §2.4):
///   - **Tiles**: every tmux pane shown at once, positioned 1:1 by its tmux cell
///     geometry. The container owns the tmux client size (one push for the whole
///     viewport) and sizes each surface to its exact pane cell grid so TUIs don't
///     tear. Tap = select-pane; ⛶ = zoom.
///   - **Focus**: a single pane (tmux `window_zoomed_flag`) fills the viewport.
///     Its surface drives the tmux client size (device-fit).
/// Non-tmux sessions are a single pane (focus layout).
final class PaneContainerVC: UIViewController {
    /// Back-reference so the find bar's visibility can publish to the SwiftUI
    /// chrome (the floating quick-keys bar hides while find owns the keyboard).
    weak var bridge: PaneContainerBridge?
    var viewModel: TerminalViewModel? {
        didSet { wireGeometryHook() }
    }
    var voiceController: VoiceInputController? {
        didSet { observeComposeBar() }
    }

    /// Re-tile SYNCHRONOUSLY when `%layout-change` applies new pane geometry, so
    /// tiled surfaces resize to the new tmux size BEFORE the program's repaint
    /// output is fed to ghostty (same fix as the macOS host). In Tiles mode each
    /// surface is sized from tmux cell geometry; without this the relayout only
    /// happened on the debounced `refreshPanes` (~300ms later), so a TUI repainted
    /// at the new width into a still-old-size grid and stayed garbled until the
    /// next resize. `layoutIfNeeded` forces `layoutPanes()` now, on this same
    /// main-actor notification turn. (Focus mode is device-fit, so this is a
    /// harmless no-op there.)
    private func wireGeometryHook() {
        viewModel?.onGeometryApplied = { [weak self] in
            guard let self, self.isViewLoaded else { return }
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
        }
    }
    /// Tmux-mode pane controllers, one per pane.
    private(set) var paneControllers: [TmuxPaneID: TerminalContainerVC] = [:]
    /// Non-tmux single pane controller, bound directly to TerminalViewModel.
    private(set) var singlePaneVC: TerminalContainerVC?

    /// Does this container host the given surface? The SwiftUI bridge scopes
    /// background reports to THIS screen's panes (a tmux session's panes share
    /// one bg, but a second window's session should not recolor this one).
    func owns(surface: GhosttyTerminalSurface) -> Bool {
        if let s = singlePaneVC?.surface, s === surface { return true }
        return paneControllers.values.contains { $0.surface === surface }
    }

    private let floatingToolbar = FloatingQuickKeysToolbar()
    /// Collapsed quick-keys bar (a perfect-circle chevron). Persisted per
    /// device, same convention as `fullscreenMode`. Pure bar-internal state —
    /// it never touches the reserved band or the grid, so it has no layout
    /// didSet hook.
    private static let quickKeysCollapsedKey = "quickKeysBarCollapsed"
    private var quickKeysCollapsed = false
    private let findBar = PaneFindBar()
    /// The pane the find bar is searching. Held so the bar keeps talking to the
    /// same surface even if the active pane changes underneath it.
    private weak var findTargetVC: TerminalContainerVC?
    /// Height the find bar hides, folded into `bottomOcclusion` so the content
    /// pans up and a match on the last rows isn't left behind the bar.
    private var findReserve: CGFloat = 0
    private var keyboardInsetBottom: CGFloat = 0

    /// Height of the inline compose bar (ComposeBar), which rides the keyboard's
    /// top edge; 0 when it's not showing. Published by the bar itself (measured),
    /// observed below. Extends the bottom occlusion so composing pans the cursor
    /// line clear of keyboard + bar — the bar exists to type while WATCHING the
    /// terminal.
    private var composeReserve: CGFloat = 0
    private var composeBarSubs: Set<AnyCancellable> = []

    /// The slice of the page hidden behind bottom chrome — the keyboard plus,
    /// while composing, the inline compose bar on top of it (keyboard down →
    /// the bar rests on the bottom safe inset instead). `pageRect` runs to the
    /// very bottom edge (no reserved bottom inset), so this is the full covered
    /// height. Bottom chrome shrinks the VIEWPORT, never the page (PRD
    /// §2.2/§2.6), so this drives content panning only, never tmux.
    private var bottomOcclusion: CGFloat {
        // The find bar occupies the same strip as the compose bar and is never
        // up at the same time, so they share one reserve.
        let reserve = max(composeReserve, findReserve)
        guard reserve > 0 else {
            // Raw keyboard mode: the quick-keys bar floats on the bare
            // keyboard's top edge (no system accessory anymore). Its height is
            // FIXED by design, so the occlusion uses the constant directly —
            // a measured report would land a frame later than the pan (the
            // overlay renders after the keyboard animation starts) and the
            // caret would sit under the bar.
            return max(0, keyboardInsetBottom)
                + (keyboardInsetBottom > 0 ? AccessoryKeyRow.barHeight : 0)
        }
        return max(keyboardInsetBottom, view.safeAreaInsets.bottom) + reserve
    }

    var sizingMode: TerminalSizingMode = .tracking {
        didSet { if oldValue != sizingMode { view.setNeedsLayout() } }
    }
    /// Fullscreen shrinks the page's top inset to the status bar (the grid
    /// reclaims the hidden nav bar's strip). Set by the SwiftUI wrapper.
    var isFullscreen = false {
        didSet { if oldValue != isFullscreen { view.setNeedsLayout() } }
    }
    var sizingOwnerIsMe = false {
        didSet { if oldValue != sizingOwnerIsMe { view.setNeedsLayout() } }
    }

    /// Is the window's size decided somewhere other than this viewport? Then
    /// the page is the window's natural cell size and we letterbox/pan, rather
    /// than stretching the surface to a grid tmux will not honour.
    private var windowSizeIsForeign: Bool {
        sizingMode != .tracking
    }

    /// Holds the pane VCs. When the page (tmux size) is larger than the viewport
    /// (PRD §2.2, Pinned), this view is bigger than the screen and two-finger pan
    /// translates it. When page ≤ viewport it sits top-left, no scroll.
    private let contentView = UIView()
    /// Pan offset of the content view (≤ 0 on each axis), in points.
    private var contentOffset: CGPoint = .zero

    /// Transparent overlay over the panes that claims touches only on a divider
    /// between adjacent panes, to drag-resize them (tmux resize-pane). Mirrors
    /// the macOS `DividerOverlay`. Lives inside `contentView` so it pans with the
    /// page; kept on top of the pane views after each tile layout.
    private let dividerOverlay = TileDividerOverlay()

    /// Font cell size in device pixels, learned from the first surface that
    /// reports it; constant for the font.
    private var cellPx: CGSize?
    /// Last cols×rows pushed to tmux (dedupe).
    private var lastClient: (cols: Int, rows: Int)?
    private var clientResizeWork: DispatchWorkItem?

    // MARK: - Lifecycle

    /// The terminal runs to the bottom edge (see `pageRect`), so let the home
    /// indicator auto-dim — the UIKit way, which (unlike SwiftUI's
    /// `.persistentSystemOverlays(.hidden)`) doesn't interfere with the software
    /// keyboard's input handling.
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = STTheme.term
        contentView.clipsToBounds = false
        view.addSubview(contentView)
        contentView.addSubview(dividerOverlay)
        dividerOverlay.onResize = { [weak self] paneID, vertical, deltaCells in
            self?.resizeBoundary(paneID: paneID, vertical: vertical, deltaCells: deltaCells)
        }
        setupFloatingToolbar()
        setupFindBar()
        setupKeyboardObservers()
        setupPanGesture()
        NotificationCenter.default.addObserver(
            self, selector: #selector(activePaneAppearanceChanged),
            name: .terminalThemeChanged, object: nil)
    }

    /// Two-finger pan navigates the page when it's larger than the viewport
    /// (PRD §3.1, low priority — never steals the single-finger scrollback or
    /// long-press voice gestures).
    private func setupPanGesture() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePagePan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        view.addGestureRecognizer(pan)
    }

    private var panStartOffset: CGPoint = .zero

    @objc private func handlePagePan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            panStartOffset = contentOffset
        case .changed:
            let t = g.translation(in: view)
            contentOffset = CGPoint(x: panStartOffset.x + t.x, y: panStartOffset.y + t.y)
            applyContentFrame()
        default:
            applyContentFrame()
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Tear down every pane's ghostty surface on the main thread before this
    /// container/view is released (e.g. the screen is dismissed). Called from
    /// SinglePaneSurface.dismantleUIViewController so it happens BEFORE the
    /// layer hierarchy is torn down — otherwise the display link draws into a
    /// half-freed Metal layer and crashes.
    func teardownAll() {
        singlePaneVC?.teardown()
        for vc in paneControllers.values { vc.teardown() }
    }

    /// Breathing room between the cursor and the keyboard's top edge.
    private static let cursorKeyboardMargin: CGFloat = 10

    @objc private func activePaneAppearanceChanged() {
        DispatchQueue.main.async { [weak self] in self?.syncBackgroundToActivePane() }
    }

    private func syncBackgroundToActivePane() {
        let bg = focusedOrActiveVC?.view.backgroundColor ?? STTheme.term
        guard view.backgroundColor != bg else { return }
        UIView.animate(withDuration: 0.26) { self.view.backgroundColor = bg }
    }

    // MARK: - Focus / active resolution

    /// The pane currently zoomed (focused), if any and present.
    private var focusedPaneVC: TerminalContainerVC? {
        guard let id = viewModel?.zoomedPaneID else { return nil }
        return paneControllers[id]
    }

    /// The VC the floating toolbar / keyboard target: focused pane, else active.
    fileprivate var focusedOrActiveVC: TerminalContainerVC? {
        if let s = singlePaneVC { return s }
        if let f = focusedPaneVC { return f }
        if let id = viewModel?.activePaneID, let vc = paneControllers[id] { return vc }
        return paneControllers.values.first
    }

    // MARK: - File browser

    /// Browse the focused pane's working directory as a tree, and preview what
    /// you tap. Presented from here rather than from the SwiftUI chrome because
    /// the file context belongs to a pane's container — reusing the provider
    /// tap-a-path already uses means the browser can never read a different
    /// disk than the preview would.
    func presentFileBrowser() {
        guard let target = focusedOrActiveVC,
              let provider = target.pathPreviewContext else { return }
        let browser = FileTreeBrowserView(contextProvider: provider) { [weak self, weak target] path, _ in
            // One sheet at a time: let the browser go, then preview.
            self?.dismiss(animated: true) {
                target?.presentPathPreviewSheet(path: path, line: nil)
            }
        }
        let host = UIHostingController(rootView: NavigationStack {
            browser
                .navigationTitle("Files")
                .navigationBarTitleDisplayMode(.inline)
        })
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.prefersEdgeAttachedInCompactHeight = true
        }
        present(host, animated: true)
    }

    // MARK: - Non-tmux single pane

    func setupSinglePane() {
        guard let viewModel else { return }
        let vc = makeContainerVC()
        vc.bindToTerminalVM(viewModel)
        vc.pathPreviewContext = { [weak self, weak vc] in
            self?.makePathPreviewContext(paneVM: nil, vc: vc)
        }
        vc.titleBar.isActivePane = true
        vc.onFindRequested = { [weak self] prefill in self?.showFindBar(prefill: prefill) }
        addChild(vc)
        contentView.addSubview(vc.view)
        vc.didMove(toParent: self)
        singlePaneVC = vc
        updateFloatingToolbarVisibility()
        view.setNeedsLayout()
        syncBackgroundToActivePane()
    }

    // MARK: - Tmux panes

    func setupTmuxPanes() {
        guard let viewModel else { return }
        if let single = singlePaneVC {
            single.teardown()
            single.willMove(toParent: nil)
            single.view.removeFromSuperview()
            single.removeFromParent()
            singlePaneVC = nil
        }
        for paneVM in viewModel.paneViewModels {
            if paneControllers[paneVM.paneID] == nil { addPaneController(for: paneVM) }
        }
        updateFloatingToolbarVisibility()
        view.setNeedsLayout()
    }

    func refreshPanes() {
        guard let viewModel else { return }
        let currentIDs = Set(paneControllers.keys)
        let newIDs = Set(viewModel.paneViewModels.map(\.paneID))
        for id in currentIDs.subtracting(newIDs) {
            if let vc = paneControllers.removeValue(forKey: id) {
                vc.teardown()
                vc.willMove(toParent: nil)
                vc.view.removeFromSuperview()
                vc.removeFromParent()
            }
        }
        for paneVM in viewModel.paneViewModels where !currentIDs.contains(paneVM.paneID) {
            addPaneController(for: paneVM)
        }
        updateFloatingToolbarVisibility()
        view.setNeedsLayout()
    }

    private func addPaneController(for paneVM: PaneViewModel) {
        let paneID = paneVM.paneID
        let vc = makeContainerVC()
        vc.bindToPaneVM(paneVM)
        vc.pathPreviewContext = { [weak self, weak vc, weak paneVM] in
            self?.makePathPreviewContext(paneVM: paneVM, vc: vc)
        }
        vc.onSelectPaneTapped = { [weak self] in
            self?.viewModel?.selectPane(paneID)
            self?.view.setNeedsLayout()
        }
        vc.onSplitRequested = { [weak self] horizontal in
            self?.viewModel?.selectPane(paneID)
            self?.viewModel?.splitPane(horizontal: horizontal)
        }
        vc.onCloseRequested = { [weak self] in self?.viewModel?.closePane(paneID) }
        vc.onToggleZoom = { [weak self] in self?.viewModel?.toggleZoom(paneID) }
        // tmux copy-mode entered from outside Bento — we don't implement the
        // mode, we just keep the pane from looking frozen while it's on.
        vc.onCopyModeScroll = { [weak self] rows in
            self?.viewModel?.scrollCopyMode(paneID, rows: rows)
        }
        vc.onExitCopyMode = { [weak self] in self?.viewModel?.exitCopyMode(paneID) }
        vc.onFindRequested = { [weak self] prefill in
            self?.viewModel?.selectPane(paneID)
            self?.showFindBar(prefill: prefill)
        }
        // Split entries only exist in Tiled mode — in List a split would build
        // a third shape, so the pane menu hides them (checked at menu-open).
        vc.showsSplitActions = { [weak self] in self?.viewModel?.sessionMode == .tiled }
        vc.onSetProfile = { [weak self] id in self?.viewModel?.setPaneProfile(id, for: paneID) }
        vc.currentProfileID = { [weak self] in self?.viewModel?.paneProfile(for: paneID) }
        vc.moveTargets = { [weak self] in
            guard let vm = self?.viewModel else { return [] }
            Task { await vm.refreshTmuxSessions() }   // warm for the next open
            return vm.availableTmuxSessions.filter { $0 != vm.activeTmuxSessionName }
        }
        vc.onMoveToSession = { [weak self] name in
            self?.movePane(paneID, toSessionNamed: name)
        }
        vc.onSizeChanged = { [weak self] size in
            self?.handlePaneSize(size, paneID: paneID)
        }
        vc.onTitleDrag = { [weak self] phase in
            self?.handleTitleSwap(source: paneID, phase: phase)
        }
        addChild(vc)
        contentView.addSubview(vc.view)
        vc.didMove(toParent: self)
        paneControllers[paneID] = vc
    }

    private func makeContainerVC() -> TerminalContainerVC {
        let vc = TerminalContainerVC()
        vc.voiceController = voiceController
        return vc
    }

    /// Pane menu → Move to Session: run the move; an unsettled target (fresh
    /// 1×1 with no remembered mode, or a mixed external structure) bounces
    /// back as a landing prompt, then re-runs with the explicit choice.
    private func movePane(_ paneID: TmuxPaneID, toSessionNamed name: String,
                          landing: MoveLanding = .auto) {
        Task { [weak self] in
            guard let self, let vm = self.viewModel else { return }
            if await vm.movePane(paneID, toSession: name, landing: landing)
                == .needsLandingChoice {
                self.promptMoveLanding(session: name) { [weak self] choice in
                    self?.movePane(paneID, toSessionNamed: name, landing: choice)
                }
            }
        }
    }

    private func promptMoveLanding(session: String,
                                   _ proceed: @escaping (MoveLanding) -> Void) {
        let alert = UIAlertController(
            title: "Move to “\(session)”",
            message: "That session isn't settled into Parallel or Focus yet. Where should this land?",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Into Current Window (Parallel)", style: .default) { _ in
            proceed(.joinCurrentWindow)
        })
        alert.addAction(UIAlertAction(title: "As New Window (Focus)", style: .default) { _ in
            proceed(.newWindow)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    /// Path preview: build the fetch context at tap time — the transport can
    /// reconnect and swap its underlying client, so nothing is cached here.
    /// cwd = the pane's live tmux path, falling back to the surface's OSC 7
    /// report (non-tmux sessions).
    private func makePathPreviewContext(paneVM: PaneViewModel?,
                                        vc: TerminalContainerVC?) -> PathPreviewContext? {
        guard let viewModel,
              let ssh = viewModel.activeTransport as? SSHService,
              let source = ssh.filePreviewSource() else { return nil }
        return PathPreviewContext(
            source: source,
            cwd: { [weak paneVM, weak vc] in
                if let path = await paneVM?.currentWorkingDirectory() { return path }
                return vc?.surface?.reportedPwd
            },
            hostLabel: viewModel.host.displayName,
            isLocal: false)
    }

    /// Learn the cell pixel size from any surface; drive the tmux client size
    /// from the focused/single pane (which fills the page). Tiled panes are
    /// fixed-size and never push.
    private func handlePaneSize(_ size: TerminalSurfaceSize, paneID: TmuxPaneID) {
        if cellPx == nil, size.cellWidthPx > 0, size.cellHeightPx > 0 {
            cellPx = CGSize(width: size.cellWidthPx, height: size.cellHeightPx)
            view.setNeedsLayout()
        }
        // In focus mode, the visible pane fills the page → its reported size is
        // the device-fit client size. Push it (deduped).
        guard isFocusLayout, paneID == effectiveFocusID else { return }
        // …unless the page is the WINDOW's size rather than this viewport's
        // (`windowSizeIsForeign`): the surface is then sized to the grid another
        // device chose, and reporting that back declares "this device fits
        // exactly what you already picked". That is how `smallest` could never
        // shrink anything from a phone, and it would make the take-over banner
        // blind — the two grids it compares would be the same number by
        // construction. Measure the viewport instead.
        if windowSizeIsForeign, let fit = deviceFitGrid(reserveTitleRow: false) {
            pushClientSize(cols: fit.cols, rows: fit.rows)
        } else {
            pushClientSize(cols: size.columns, rows: size.rows)
        }
    }

    /// What this device's viewport fits, in tmux cells, independent of what the
    /// surfaces are currently sized to. `reserveTitleRow` accounts for the one
    /// cell of height the top pane's title bar takes in Tiles (Focus hides it).
    private func deviceFitGrid(reserveTitleRow: Bool) -> (cols: Int, rows: Int)? {
        guard let cellPx, cellPx.width > 0, cellPx.height > 0 else { return nil }
        let rect = pageRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        let scale = displayScale
        let cols = max(Int((rect.width * scale) / cellPx.width), 2)
        let rows = max(Int((rect.height * scale) / cellPx.height) - (reserveTitleRow ? 1 : 0), 1)
        return (cols, rows)
    }

    private func pushClientSize(cols: Int, rows: Int) {
        dlog("[pushClientSize] \(cols)x\(rows)")
        guard cols > 0, rows > 0 else { return }
        // No policy gate here: the view model gates the WIRE (a foreign `manual`
        // owner silences the `refresh-client`) and records the measurement
        // either way. Dropping it here instead left the engine believing this
        // device still fit whatever it measured before the other device took
        // the size — a stale grid to resize the session to on take-over.
        guard lastClient?.cols != cols || lastClient?.rows != rows else { return }
        lastClient = (cols, rows)
        clientResizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.viewModel?.resizeTmuxClient(cols: cols, rows: rows)
        }
        clientResizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    // MARK: - Layout

    /// Whether we're showing a single full pane (zoomed focus or non-tmux).
    private var isFocusLayout: Bool {
        singlePaneVC != nil || viewModel?.zoomedPaneID != nil
            || (viewModel?.paneViewModels.count ?? 0) <= 1
    }

    private var effectiveFocusID: TmuxPaneID? {
        if let z = viewModel?.zoomedPaneID { return z }
        if (viewModel?.paneViewModels.count ?? 0) == 1 { return viewModel?.paneViewModels.first?.paneID }
        return viewModel?.activePaneID
    }

    /// Page rect = the area the tmux page maps to. KEYBOARD-INDEPENDENT (PRD
    /// §2.6): the keyboard never resizes tmux.
    private var pageRect: CGRect {
        // Respect the LEFT/RIGHT safe-area insets: in landscape on a notched
        // device they're non-zero, and without subtracting them ghostty counts
        // columns under the notch/home-indicator that aren't usable (the PTY
        // ends up a few columns too wide and TUIs wrap/misalign).
        //
        // Bottom reserve is ORIENTATION-DEPENDENT (2026-08-02 user decision):
        // in landscape the grid reclaims the home-indicator strip and runs to
        // the very bottom edge (the indicator auto-dims over the last row via
        // prefersHomeIndicatorAutoHidden). In portrait the bottom safe area
        // stays reserved so the last row never sits under the indicator.
        // Keyboard-INDEPENDENT (PRD §2.6) — a constant layout, not tied to the
        // keyboard.
        //
        // Non-fullscreen with a pane, the quick-keys bar owns a dedicated band
        // on top of the above: `reservedBand` is cut out of the page so the
        // grid never sits under the bar (2026-08-02 user decision — in
        // fullscreen the bar floats OVER the content instead and the band is
        // not reserved). The band is keyboard- and collapse-independent for
        // the same §2.6 reason: it only changes with manual layout actions
        // (fullscreen toggle, orientation), never with overlays.
        //
        // Fullscreen: the nav bar is hidden but SwiftUI keeps THIS view's frame
        // (and thus its insets) where it was — the grid would never grow. Reach
        // up into the old nav-bar strip ourselves: page.y = statusBarTop −
        // viewTopInWindow, i.e. negative (the content view is allowed to stick
        // out above this view's bounds; only the status strip above it stays
        // untouchable, which is fine — it's system chrome).
        let insets = view.safeAreaInsets
        let top: CGFloat
        if isFullscreen, let window = view.window {
            let viewTopInWindow = view.convert(.zero, to: window).y
            let statusBarHeight = window.windowScene?.statusBarManager?.statusBarFrame.height ?? 0
            top = statusBarHeight - viewTopInWindow
        } else {
            top = insets.top
        }
        // Landscape = compact vertical size class (the phone rotated): reclaim
        // the strip. Portrait: keep the bottom safe area reserved. Either way,
        // add the quick-keys band when it owns a dedicated strip.
        let bottomReserve: CGFloat =
            (view.traitCollection.verticalSizeClass == .compact ? 0 : insets.bottom)
            + (quickKeysBandActive ? FloatingQuickKeysToolbar.reservedBand : 0)
        let result = CGRect(x: insets.left, y: top,
                            width: max(0, view.bounds.width - insets.left - insets.right),
                            height: max(0, view.bounds.height - top - bottomReserve))
        let winTop = view.window.map { view.convert(.zero, to: $0).y } ?? -1
        dlog("[pageRect] frame=\(view.frame) winTop=\(winTop) full=\(isFullscreen) bounds=\(view.bounds) insets=\(insets) top=\(top) page=\(result)")
        // Hand the measurement to whoever has to ESTIMATE it later: a session
        // connecting before its container exists has nothing else to go on, and
        // guessing from the screen counts the iPad sidebar as terminal.
        SessionManager.shared.recordTerminalPageSize(result.size)
        return result
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPanes()
        positionFloatingToolbar()
        positionFindBar()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        view.setNeedsLayout()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in self.view.setNeedsLayout() })
    }

    private var displayScale: CGFloat { view.window?.screen.scale ?? UIScreen.main.scale }

    /// Points per tmux cell, or nil until learned. ghostty reports the cell size
    /// in device pixels, so divide by the screen scale to get points.
    private var pointsPerCell: CGSize? {
        cellPx.map { CGSize(width: $0.width / displayScale, height: $0.height / displayScale) }
    }

    // MARK: - Drag a pane's title bar onto another pane (swap / dock)

    /// The translucent landing preview shown while a title-bar drag hovers a
    /// target pane; created on the first hover of a drag, torn down when the
    /// drag ends. Mirrors the macOS host's PaneDropZoneOverlay.
    private var dropOverlay: PaneDropZoneOverlayView?

    // MARK: - Page sizing & content offset

    /// Base visibility: a pane exists to receive keys. The toolbar additionally
    /// hides while the keyboard is up — the docked accessory key bar covers keys
    /// then, and the toolbar's reserved band sits behind the keyboard anyway.
    private var hasVisiblePane: Bool { singlePaneVC != nil || !paneControllers.isEmpty }

    /// Reserve the quick-keys band in the page? Non-fullscreen with a pane.
    /// KEYBOARD-INDEPENDENT on purpose (PRD §2.6): show/hide of the keyboard,
    /// compose bar, or find bar never resizes tmux, so the band stays reserved
    /// while they cover it (it's behind them anyway). Collapse is a bar-internal
    /// state — it shrinks the bar, never the band.
    private var quickKeysBandActive: Bool {
        !isFullscreen && hasVisiblePane
    }
}

// MARK: - Keyboard & compose occlusion

extension PaneContainerVC {
    private func setupKeyboardObservers() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillShow(_:)),
            name: UIResponder.keyboardWillShowNotification, object: nil)
        // Third-party IMEs resize AFTER showing (candidate strips appear and
        // collapse while typing) and report it only through willChangeFrame.
        // Without this the avoidance pans from a stale height: the compose bar
        // covered the cursor while candidates were up, and left a dead gap
        // above itself once they collapsed. Same handler — an off-screen end
        // frame computes to inset 0, so hide also passes through safely.
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillShow(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    @objc private func keyboardWillShow(_ note: Notification) {
        guard let frameValue = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        else { return }
        let inView = view.convert(frameValue, from: nil)
        keyboardInsetBottom = max(0, view.bounds.maxY - inView.minY)
        dlog("[keyboard] show inset=\(keyboardInsetBottom)")
        updateFloatingToolbarVisibility()
        animateForKeyboard(note)
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        dlog("[keyboard] hide")
        keyboardInsetBottom = 0
        updateFloatingToolbarVisibility()
        animateForKeyboard(note)
    }

    private func animateForKeyboard(_ note: Notification) {
        let info = note.userInfo
        let duration = (info?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curveRaw = (info?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt) ?? 0
        let opts = UIView.AnimationOptions(rawValue: curveRaw << 16)
        // Keyboard changes the VIEWPORT only — it never changes the page (tmux
        // size) or the tmux client size (both come from the keyboard-independent
        // page rect, so the keyboard never resizes tmux). We respond by panning
        // the content up so the active pane's input stays above the keyboard,
        // re-clamping the offset, and repositioning the floating toolbar. On
        // hide, keyboardOverlap is 0 so the re-clamp pulls the page back.
        UIView.animate(withDuration: duration, delay: 0, options: opts) {
            self.revealActivePaneAboveKeyboard()
            self.applyContentFrame()
            self.view.layoutIfNeeded()
        }
    }

    /// Pan the content up just enough to lift the active pane's INSERTION POINT
    /// (the real terminal cursor) above the bottom occlusion (keyboard, plus the
    /// compose bar while composing). The cursor isn't always at the pane bottom
    /// — TUIs (vim, forms, less) put it anywhere — so anchoring on the pane
    /// bottom hid the caret. Falls back to the pane bottom when the cursor rect
    /// isn't readable. No-op when nothing is hidden.
    private func revealActivePaneAboveKeyboard() {
        guard bottomOcclusion > 0, let vc = focusedOrActiveVC else { return }
        let keyboardTopInView = view.bounds.height - bottomOcclusion
        let anchorBottomInView: CGFloat
        if let caret = vc.cursorRect(in: view) {
            anchorBottomInView = caret.maxY + Self.cursorKeyboardMargin
        } else {
            anchorBottomInView = contentView.frame.minY + vc.view.frame.maxY
        }
        let overflow = anchorBottomInView - keyboardTopInView
        guard overflow > 0 else { return }
        contentOffset.y -= overflow
    }

    /// Track the compose bar's visibility + measured height so the content can
    /// pan clear of it (same animated path as the keyboard).
    private func observeComposeBar() {
        composeBarSubs.removeAll()
        guard let controller = voiceController else { return }
        controller.$showPreview
            .combineLatest(controller.$composeBarHeight)
            .map { shown, height in shown ? height : 0 }
            .removeDuplicates()
            .sink { [weak self] reserve in self?.composeReserveChanged(reserve) }
            .store(in: &composeBarSubs)
    }

    private func composeReserveChanged(_ reserve: CGFloat) {
        guard composeReserve != reserve else { return }
        composeReserve = reserve
        guard isViewLoaded else { return }
        updateFloatingToolbarVisibility()
        UIView.animate(withDuration: 0.25) {
            self.revealActivePaneAboveKeyboard()
            self.applyContentFrame()
            self.view.layoutIfNeeded()
        }
    }
}

// MARK: - Layout & page sizing

extension PaneContainerVC {
    private func layoutPanes() {
        // No draggable dividers unless we lay out cell-exact tiles below.
        dividerOverlay.dividers = []
        if let single = singlePaneVC {
            let page = pageSizeForFocus(cols: nil)
            setContentFrame(page)
            single.tiled = false
            single.fixedTerminalCellSize = nil
            // Focus immersion: the pane fills the screen, so the title strip
            // (icon + label) is pure chrome over the user's terminal — drop it
            // entirely (zero height), and the surface grows into its space
            // (tmux gets one or two extra rows — that's the point).
            single.titleBar.isHidden = true
            single.titleBarHeight = 0
            single.surfaceInsetX = 0
            single.view.frame = CGRect(origin: .zero, size: page)
            return
        }
        guard let viewModel, !paneControllers.isEmpty else { return }

        if isFocusLayout, let focusID = effectiveFocusID {
            layoutFocus(focusID)
        } else {
            layoutTiles(viewModel.paneViewModels)
        }
        syncBackgroundToActivePane()
    }

    /// Single pane fills the page; the rest are hidden. In Tracking the page is
    /// the viewport (device-fit, drives tmux); in Pinned the page is the pane's
    /// natural cell size (may exceed the viewport → two-finger pan).
    private func layoutFocus(_ focusID: TmuxPaneID) {
        let pane = viewModel?.paneViewModels.first(where: { $0.paneID == focusID })?.pane
        let page = pageSizeForFocus(cols: pane.map { ($0.width, $0.height) })
        setContentFrame(page)
        for (id, vc) in paneControllers {
            let isFocus = (id == focusID)
            vc.view.isHidden = !isFocus
            if isFocus {
                vc.tiled = false
                vc.fixedTerminalCellSize = nil
                // Same immersion as the single-pane case: no title strip in
                // focus — zero height, and the surface grows into the space.
                vc.titleBar.isHidden = true
                vc.titleBarHeight = 0
                vc.surfaceInsetX = 0
                vc.view.frame = CGRect(origin: .zero, size: page)
                vc.titleBar.isActivePane = true
                if let pvm = viewModel?.paneViewModels.first(where: { $0.paneID == focusID }) {
                    vc.updatePaneState(pvm.paneState, doneUnseen: pvm.agentFinishedUnseen,
                                       active: true)
                }
            }
        }
    }

    /// The per-pane assignments shared by layoutTiles' bootstrap and cell-exact
    /// branches; the branch-specific geometry comes in as parameters.
    private func applyTileAssignments(_ vc: TerminalContainerVC, pvm: PaneViewModel,
                                      activeID: TmuxPaneID?, titleBarHeight: CGFloat,
                                      surfaceInsetX: CGFloat, fixedCellSize: CGSize?,
                                      frame: CGRect) {
        vc.view.isHidden = false
        vc.tiled = true
        // Tiled layout always restores the strip the focus layout hid.
        vc.titleBar.isHidden = false
        vc.titleBarHeight = titleBarHeight
        vc.surfaceInsetX = surfaceInsetX
        vc.fixedTerminalCellSize = fixedCellSize
        vc.view.frame = frame
        vc.updatePaneState(pvm.paneState, doneUnseen: pvm.agentFinishedUnseen,
                           active: pvm.paneID == activeID)
    }

    /// Tile all panes by tmux cell geometry inside the content view. In Tracking
    /// the page == viewport (proportional fit, container pushes one client size);
    /// in Pinned the page is the window's natural cell size (pannable, no push).
    private func layoutTiles(_ panes: [PaneViewModel]) {
        let (totalCols, totalRows) = PaneTiling.gridSize(panes: panes.map(\.pane))
        let activeID = viewModel?.activePaneID

        guard let ppc = pointsPerCell else {
            // Cell size not learned yet: proportional bootstrap so the surfaces
            // lay out and report their metrics (which teaches cellPx). The next
            // layout pass re-runs cell-exact once a surface has reported.
            let page = pageRect.size
            setContentFrame(page)
            let tiles = PaneTiling.proportionalTiles(
                panes: panes.map(\.pane), page: page,
                titleBarHeight: TerminalContainerVC.defaultTitleBarHeight)
            for tile in tiles {
                guard let vc = paneControllers[tile.id],
                      let pvm = panes.first(where: { $0.paneID == tile.id }) else { continue }
                applyTileAssignments(vc, pvm: pvm, activeID: activeID,
                                     titleBarHeight: tile.titleBarHeight,
                                     surfaceInsetX: tile.surfaceInsetX,
                                     fixedCellSize: nil,
                                     frame: tile.frame)
            }
            return
        }

        // Cell-exact: map tmux cell geometry 1:1 to points, exactly as the macOS
        // host does. Each pane = a title bar (one cell tall, occupying tmux's
        // divider row) + a surface of exactly its cols×rows. The title bar height
        // equals one cell so stacked panes reuse divider rows and irregular
        // splits stay aligned (only the top bar adds height). Side-by-side panes
        // share the divider column: the container grows half a cell into it on
        // each side so neighbours meet, while surfaceInsetX keeps the surface at
        // its true cell size and position (ghostty's grid still == tmux's).
        let page = pageSizeForTiles(totalCols: totalCols, totalRows: totalRows)
        setContentFrame(page)

        for tile in PaneTiling.cellExactTiles(panes: panes.map(\.pane), pointsPerCell: ppc) {
            guard let vc = paneControllers[tile.id],
                  let pvm = panes.first(where: { $0.paneID == tile.id }) else { continue }
            let p = pvm.pane
            // The surface is one cell larger than the pane so ghostty's grid >=
            // tmux (point rounding never drops a column/row); overflow is clipped.
            applyTileAssignments(vc, pvm: pvm, activeID: activeID,
                                 titleBarHeight: tile.titleBarHeight,
                                 surfaceInsetX: tile.surfaceInsetX,
                                 fixedCellSize: CGSize(width: CGFloat(p.width + 1) * ppc.width,
                                                       height: CGFloat(p.height + 1) * ppc.height),
                                 frame: tile.frame)
        }
        recomputeTilesClientSize()
        // Refresh the drag-to-resize divider hot zones for the new geometry.
        dividerOverlay.frame = CGRect(origin: .zero, size: page)
        dividerOverlay.pointsPerCell = CGPoint(x: ppc.width, y: ppc.height)
        dividerOverlay.dividers = computeTileDividers(page: page, ppc: ppc)
        contentView.bringSubviewToFront(dividerOverlay)
    }

    /// Page size for a focused/single pane. We drive the size → viewport;
    /// someone else does → the pane's natural cell size (+ title bar), which may
    /// exceed the viewport.
    private func pageSizeForFocus(cols: (Int, Int)?) -> CGSize {
        let rect = pageRect
        guard windowSizeIsForeign, let ppc = pointsPerCell, let (c, r) = cols else {
            return rect.size
        }
        // No title strip in focus anymore — the page is exactly the grid.
        return CGSize(width: CGFloat(c) * ppc.width,
                      height: CGFloat(r) * ppc.height)
    }

    /// Page size for Tiles. We drive the size → viewport; someone else does →
    /// the window's natural size.
    /// Cell-exact: width maps cells 1:1; height is the grid plus exactly ONE
    /// title bar (one cell) — stacked panes' title bars reuse tmux's divider
    /// rows, so only the top bar adds height (see `layoutTiles`).
    private func pageSizeForTiles(totalCols: CGFloat, totalRows: CGFloat) -> CGSize {
        let rect = pageRect
        guard windowSizeIsForeign, let ppc = pointsPerCell else { return rect.size }
        return CGSize(width: totalCols * ppc.width,
                      height: (totalRows + 1) * ppc.height)
    }

    /// Place the content view at the clamped pan offset. Page ≤ viewport → pinned
    /// top-left, no scroll (PRD §2.2); page > viewport → pannable.
    private func setContentFrame(_ page: CGSize) {
        let rect = pageRect
        // Bottom chrome (keyboard + compose bar) shrinks the usable viewport
        // height (not the page). Clamp against that reduced height so the
        // content can pan up far enough to lift the active pane's input above
        // it; with nothing covering, bottomOcclusion is 0 and this is the plain
        // page-rect clamp.
        let usableH = rect.height - bottomOcclusion
        let minX = min(0, rect.width - page.width)
        let minY = min(0, usableH - page.height)
        let clampedX = max(minX, min(0, contentOffset.x))
        let clampedY = max(minY, min(0, contentOffset.y))
        contentOffset = CGPoint(x: clampedX, y: clampedY)
        contentView.frame = CGRect(x: rect.minX + clampedX, y: rect.minY + clampedY,
                                   width: page.width, height: page.height)
        dlog("[contentFrame] page=\(page) offset=\(contentOffset) frame=\(contentView.frame) occ=\(bottomOcclusion)")
    }

    private func applyContentFrame() {
        // Re-clamp using the current content size after a pan.
        setContentFrame(contentView.bounds.size)
        positionFloatingToolbar()
        positionFindBar()
    }

    /// One tmux client size for the whole viewport (Tiles). Cell-exact tiling
    /// reserves exactly ONE cell of height for the top title bar (stacked panes
    /// reuse divider rows), so the usable terminal grid is the viewport minus a
    /// single cell row. Always measured, even when the policy forbids declaring
    /// it — see `pushClientSize`.
    private func recomputeTilesClientSize() {
        guard let fit = deviceFitGrid(reserveTitleRow: true) else { return }
        pushClientSize(cols: fit.cols, rows: fit.rows)
    }
}

// MARK: - Divider resize

extension PaneContainerVC {
    /// Resize the boundary owned by `paneID` by a signed cell delta (tmux
    /// `resize-pane`).
    private func resizeBoundary(paneID: TmuxPaneID, vertical: Bool, deltaCells: Int) {
        guard let dir = PaneTiling.resizeDirection(vertical: vertical, deltaCells: deltaCells)
        else { return }
        viewModel?.resizePaneBy(paneID, direction: dir, amount: abs(deltaCells))
    }

    /// The pane containers currently on screen — the input to divider and drop
    /// hit-testing (both shared with the macOS host).
    var paneFrames: [PaneFrame] {
        paneControllers.compactMap { id, vc in
            vc.view.isHidden ? nil : PaneFrame(id: id, frame: vc.view.frame)
        }
    }

    /// Divider hot zones for the current tiling — the same computation the macOS
    /// host runs, with touch-sized grab areas instead of pointer-sized ones.
    private func computeTileDividers(page: CGSize, ppc: CGSize) -> [PaneDivider] {
        PaneTiling.dividers(frames: paneFrames, bounds: page,
                            pointsPerCell: CGPoint(x: ppc.width, y: ppc.height),
                            hotZone: TileDividerOverlay.hotZone)
    }
}

// MARK: - Title-drag swap / dock
//
// VS Code-style drop zones, exactly like the macOS host: hovering a target
// pane previews the landing — its middle 50%×50% highlights the WHOLE pane
// (drop = swap the two panes), the four edge bands highlight that HALF
// (drop = re-split the target along that axis and dock the dragged pane on
// that side).

extension PaneContainerVC {
    /// Where a drop at a window-coordinate point would land, excluding the
    /// dragged pane. Pane frames live in `contentView`, so convert in first.
    private func landing(atWindowPoint p: CGPoint, excluding source: TmuxPaneID) -> PaneDrag.Landing? {
        PaneDrag.landing(at: contentView.convert(p, from: nil),
                         in: paneFrames, excluding: source)
    }

    private func handleTitleSwap(source paneID: TmuxPaneID, phase: TitleDragPhase) {
        // Rearranging only makes sense between visible tiles. In focus /
        // single-pane layout there's nothing to land on, so ignore the drag.
        guard !isFocusLayout else { return }
        switch phase {
        case .began:
            paneControllers[paneID]?.view.alpha = 0.6
        case .moved(let p):
            updateDropOverlay(landing(atWindowPoint: p, excluding: paneID))
        case .ended(let p):
            let drop = landing(atWindowPoint: p, excluding: paneID)
            endTitleDrag(paneID)
            guard let drop else { return }
            switch PaneDrag.action(source: paneID, landing: drop) {
            case let .dock(source, target, horizontal, before):
                viewModel?.movePane(source, splitting: target,
                                    horizontal: horizontal, before: before)
            case let .swap(source, target):
                viewModel?.swapPanes(source, with: target)
            }
        case .cancelled:
            endTitleDrag(paneID)
        }
    }

    private func endTitleDrag(_ paneID: TmuxPaneID) {
        paneControllers[paneID]?.view.alpha = 1.0
        dropOverlay?.removeFromSuperview()
        dropOverlay = nil
    }

    /// Show/move/hide the landing preview. The frame animates between zones
    /// and across panes while visible; appearing (or reappearing after a gap)
    /// snaps into place so the preview never slides in from a stale spot.
    private func updateDropOverlay(_ drop: PaneDrag.Landing?) {
        guard let drop else {
            dropOverlay?.isHidden = true
            return
        }
        let overlay: PaneDropZoneOverlayView
        let appearing: Bool
        if let existing = dropOverlay {
            overlay = existing
            appearing = overlay.isHidden
        } else {
            overlay = PaneDropZoneOverlayView()
            contentView.addSubview(overlay)   // above every pane view
            dropOverlay = overlay
            appearing = true
        }
        overlay.isHidden = false
        overlay.zone = drop.zone
        if appearing {
            overlay.frame = drop.highlightRect
        } else {
            UIView.animate(withDuration: 0.12) { overlay.frame = drop.highlightRect }
        }
    }
}

/// The translucent landing preview shown while a pane drag hovers a target:
/// the whole pane for a center/swap drop (with a ⇄ badge — the one zone whose
/// meaning isn't its own shape), the docked half for an edge drop. Colored by
/// the inherited tint (the app accent, same as the focused-pane border).
/// Non-interactive; the title-bar pan owns the touch anyway.
final class PaneDropZoneOverlayView: UIView {
    private let icon = UIImageView(image: UIImage(
        systemName: "rectangle.2.swap",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .medium)))

    var zone: PaneDropZone = .center {
        didSet { icon.isHidden = (zone != .center) }
    }

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        layer.borderWidth = 2
        layer.cornerRadius = 6
        addSubview(icon)
        applyTint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The real tint arrives when the view joins the hierarchy.
    override func tintColorDidChange() {
        super.tintColorDidChange()
        applyTint()
    }

    private func applyTint() {
        backgroundColor = tintColor.withAlphaComponent(0.22)
        layer.borderColor = tintColor.cgColor
        icon.tintColor = tintColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        icon.sizeToFit()
        icon.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}

// MARK: - Floating toolbar

extension PaneContainerVC {
    private func setupFloatingToolbar() {
        // Restore the per-device collapse choice BEFORE the first layout pass,
        // so the bar's first frame is already the circle or the full strip.
        quickKeysCollapsed = UserDefaults.standard.bool(forKey: Self.quickKeysCollapsedKey)
        floatingToolbar.isCollapsed = quickKeysCollapsed

        floatingToolbar.onKeyTap = { [weak self] key in
            self?.focusedOrActiveVC?.handleAccessoryKey(key)
        }
        floatingToolbar.onCollapseToggle = { [weak self] collapsed in
            guard let self else { return }
            self.quickKeysCollapsed = collapsed
            UserDefaults.standard.set(collapsed, forKey: Self.quickKeysCollapsedKey)
            // Only the bar's width changed — the band and grid are untouched,
            // so this is a re-position, not a layout pass.
            self.positionFloatingToolbar()
        }
        floatingToolbar.isHidden = true
        view.addSubview(floatingToolbar)
    }

    private func updateFloatingToolbarVisibility() {
        // Hidden while the keyboard is up (the docked accessory row covers keys)
        // and while the compose bar or the find bar is up (they own the bottom
        // strip).
        floatingToolbar.isHidden = !hasVisiblePane || keyboardInsetBottom > 0
            || composeReserve > 0 || findReserve > 0
    }

    /// Position the floating toolbar just below the active pane. The pane frames
    /// live in the (possibly panned) content view, so offset into view
    /// coordinates.
    private func positionFloatingToolbar() {
        guard !floatingToolbar.isHidden else { return }
        let activeVC = focusedOrActiveVC
        refreshFloatingToolbarActions(for: activeVC)
        let paneFrame = activeVC?.view.frame ?? .zero
        let origin = contentView.frame.origin
        let anchor = CGRect(x: paneFrame.minX + origin.x, y: paneFrame.minY + origin.y,
                            width: paneFrame.width, height: paneFrame.height)
        // Two homes, chosen by `quickKeysBandActive`:
        //   - Docked: the reserved band between the page bottom and the bottom
        //     safe inset — the bar sits in its own strip, never over the grid.
        //   - Floating: over the pane content (fullscreen, where no band is
        //     reserved), clamped just above the home-indicator strip. Hides
        //     while the keyboard is up, so no keyboard reserve is needed.
        let containerBounds: CGRect
        if quickKeysBandActive {
            containerBounds = CGRect(x: 0, y: pageRect.maxY,
                                     width: view.bounds.width,
                                     height: max(0, view.bounds.height - pageRect.maxY
                                                     - view.safeAreaInsets.bottom))
        } else {
            containerBounds = CGRect(x: 0, y: 0, width: view.bounds.width,
                                     height: max(0, view.bounds.height - view.safeAreaInsets.bottom))
        }
        floatingToolbar.updatePosition(paneFrame: anchor,
                                       containerBounds: containerBounds, animated: false)
    }

    /// Point the floating toolbar's menu at the active pane.
    ///
    /// Shown for a plain session too: the menu drops its tmux entries there and
    /// keeps Find / Paste / Change Profile, which are about the terminal and
    /// have nothing to do with tmux. Hiding the whole button (what this used to
    /// do for anything without a `paneVM`) took search and paste with it, and on
    /// a phone the bar is the only way to reach either.
    private func refreshFloatingToolbarActions(for activeVC: TerminalContainerVC?) {
        floatingToolbar.showsPaneActions = activeVC != nil
        guard let activeVC else { return }
        // The pane menu is cached on the VC (deferred elements re-resolve at
        // open time); only reassign when the active pane actually changed, so
        // per-layout-pass calls don't churn UIKit's menu plumbing.
        if floatingToolbar.menuButton.menu !== activeVC.paneMenu {
            floatingToolbar.menuButton.menu = activeVC.paneMenu
            // The menu's Maximize/Restore entry reads this live at open time
            // (deferred element), so wiring it once per pane change is enough.
            activeVC.isZoomed = { [weak self] in self?.viewModel?.zoomedPaneID != nil }
        }
    }
}

// MARK: - Find in pane

extension PaneContainerVC {
    /// Hardware-keyboard shortcuts (iPad with a keyboard, or a Mac trackpad
    /// case). Deliberately NO Escape here: Esc belongs to the terminal, and a
    /// container-level key command would swallow it for every pane. The find
    /// bar takes Esc only while its own field holds the keyboard — see
    /// `PaneFindBar.keyCommands`.
    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(title: "Find…", action: #selector(handleFindCommand),
                         input: "f", modifierFlags: .command),
            UIKeyCommand(title: "Find Next", action: #selector(handleFindNextCommand),
                         input: "g", modifierFlags: .command),
            UIKeyCommand(title: "Find Previous", action: #selector(handleFindPreviousCommand),
                         input: "g", modifierFlags: [.command, .shift]),
        ]
    }

    @objc private func handleFindCommand() {
        if findBar.isHidden { showFindBar() } else { findBar.focusField() }
    }

    @objc private func handleFindNextCommand() {
        guard !findBar.isHidden else { return }
        findTargetVC?.surface.navigateSearch(forward: true)
    }

    @objc private func handleFindPreviousCommand() {
        guard !findBar.isHidden else { return }
        findTargetVC?.surface.navigateSearch(forward: false)
    }

    private func setupFindBar() {
        findBar.isHidden = true
        // On `view`, not `contentView`: the bar is chrome anchored to the
        // keyboard, so it must not pan with the tmux page.
        view.addSubview(findBar)

        findBar.model.onQueryChanged = { [weak self] needle in
            self?.findTargetVC?.surface.runSearch(needle)
        }
        findBar.model.onNext = { [weak self] in
            self?.findTargetVC?.surface.navigateSearch(forward: true)
        }
        findBar.model.onPrevious = { [weak self] in
            self?.findTargetVC?.surface.navigateSearch(forward: false)
        }
        findBar.model.onClose = { [weak self] in self?.hideFindBar() }
    }

    /// Open the find bar on the pane the user is working in. A single-line
    /// selection prefills it, matching ⌘F-with-a-selection on the Mac.
    func showFindBar(prefill: String? = nil) {
        guard let vc = focusedOrActiveVC else { return }
        findTargetVC = vc

        // The engine reports counts per surface; route this one's to the bar.
        vc.surface.onSearchCounts = { [weak self] total, selected in
            self?.findBar.model.setCounts(total: total, selected: selected)
        }
        vc.surface.onSearchEnded = { [weak self] in self?.hideFindBar() }

        findBar.isHidden = false
        bridge?.findBarActive = true
        findReserve = PaneFindBar.barHeight + PaneFindBar.edgeGap
        updateFloatingToolbarVisibility()

        if let seed = prefill ?? vc.surface.selectionAsNeedle(), !seed.isEmpty {
            findBar.query = seed
            findBar.model.setQuery(seed)   // counts for a seed that never went through typing
            vc.surface.runSearch(seed)
        }
        positionFindBar()
        // Taking first responder here is what raises the keyboard, which is what
        // makes the bar's docked position matter — so position first.
        findBar.focusField()
        view.setNeedsLayout()
    }

    func hideFindBar() {
        guard !findBar.isHidden else { return }
        findBar.model.cancelPendingQuery()
        findBar.dismissKeyboard()
        findBar.isHidden = true
        bridge?.findBarActive = false
        findBar.query = ""
        findBar.model.setCounts(total: nil, selected: nil)
        findReserve = 0
        // Drop the search AND the per-surface reporting hooks, so a pane the bar
        // is no longer pointed at can't drive it.
        if let vc = findTargetVC {
            vc.surface.endSearch()
            vc.surface.onSearchCounts = nil
            vc.surface.onSearchEnded = nil
        }
        findTargetVC = nil
        updateFloatingToolbarVisibility()
        view.setNeedsLayout()
    }

    /// Dock the bar in the strip above the keyboard; with the keyboard down it
    /// rests on the bottom safe inset. Full width less the edge gap — a needle
    /// deserves the room, and unlike the Mac there is no pane corner to tuck
    /// into on a phone.
    func positionFindBar() {
        guard !findBar.isHidden else { return }
        // The target pane went away (window switch, pane closed, mode flip). The
        // reference is weak, so this is where a bar left pointing at nothing gets
        // closed instead of sitting there swallowing keystrokes.
        guard findTargetVC != nil else { hideFindBar(); return }
        let gap = PaneFindBar.edgeGap
        let h = PaneFindBar.barHeight
        let bottomInset = max(keyboardInsetBottom, view.safeAreaInsets.bottom)
        findBar.frame = CGRect(x: gap,
                               y: view.bounds.height - bottomInset - h - gap,
                               width: max(0, view.bounds.width - gap * 2),
                               height: h)
    }
}

// MARK: - Window Tab Bar (List mode, compact width)

/// Bottom tab strip for List mode on phones: one tab per tmux window,
/// browser-tab style, horizontally scrollable, with a trailing "+" that offers
/// the two creation seeds. Each tab shows the window's LIVE display name
/// (derived from what's running — never renamed), its aggregate agent-state
/// dot (`windowState`), and a pane-count badge when the window holds several
/// panes (external structures). Tapping a tab is select-window ONLY — zero
/// zoom, zero resize — the terminal above simply starts mirroring that window.
/// Long-press a tab → Close Window (confirmed: processes die).
///
/// State dots refresh on every state poll without an explicit `.id`: the
/// @ObservedObject view model bumps `stateVersion` (@Published) each cycle,
/// which re-runs this body and re-derives `windowState`. (`.id(stateVersion)`
/// on the scroll content would also reset the user's horizontal scroll
/// position every poll, so it's deliberately not used here.)
///
/// Drag a tab onto another to rearrange the session (`reorderWindow`): the
/// system drag interaction, so the phone's usual long-press-then-move applies
/// and holding still keeps opening the context menu instead — a hand-rolled
/// long-press gesture would have to fight that menu for the same touch.
struct WindowTabBar: View {
    @ObservedObject var viewModel: TerminalViewModel
    @State private var pendingClose: TmuxWindowID?
    @State private var showCustomSheet = false
    @State private var pendingMove: TmuxWindowID?
    @State private var moveSessionName = ""
    @State private var landingChoice: (window: TmuxWindowID, session: String)?
    /// The tab a dragged tab is currently hovering over — it lifts to show the
    /// slot the drop would take.
    @State private var dropTarget: TmuxWindowID?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(viewModel.windows) { window in
                        // Body name only — the chips are small, the "N:" index
                        // prefix adds noise here (the sidebar keeps it).
                        WindowTab(name: viewModel.windowBodyName(window.id),
                                  state: viewModel.windowState(window.id),
                                  paneCount: viewModel.panes(in: window.id).count,
                                  isActive: window.id == viewModel.activeWindowID)
                            .id(window.id)
                            .scaleEffect(dropTarget == window.id ? 1.08 : 1)
                            .animation(.easeOut(duration: 0.15), value: dropTarget)
                            .onTapGesture { viewModel.selectWindow(window.id) }
                            .draggable(window.id.description) {
                                // Drag preview: the same chip, drawn inactive so
                                // it reads as a thing in transit rather than as
                                // a second "current window".
                                WindowTab(name: viewModel.windowBodyName(window.id),
                                          state: viewModel.windowState(window.id),
                                          paneCount: viewModel.panes(in: window.id).count,
                                          isActive: false)
                            }
                            .dropDestination(for: String.self) { items, _ in
                                drop(items, onto: window.id)
                            } isTargeted: { targeted in
                                if targeted { dropTarget = window.id }
                                else if dropTarget == window.id { dropTarget = nil }
                            }
                            .contextMenu {
                                // The drag's one-step equivalent, for when the
                                // drag isn't practical (VoiceOver, one hand on
                                // a long strip).
                                Button {
                                    shift(window.id, earlier: true)
                                } label: {
                                    Label("Move Left", systemImage: "arrow.left")
                                }
                                .disabled(position(of: window.id) == 0)
                                Button {
                                    shift(window.id, earlier: false)
                                } label: {
                                    Label("Move Right", systemImage: "arrow.right")
                                }
                                .disabled(position(of: window.id) == viewModel.windows.count - 1)
                                WindowMoveToSessionMenu(viewModel: viewModel) { session in
                                    moveWindow(window.id, to: session)
                                } onNewSession: {
                                    moveSessionName = ""
                                    pendingMove = window.id
                                }
                                Button(role: .destructive) {
                                    pendingClose = window.id
                                } label: {
                                    Label("Close Window", systemImage: "xmark")
                                }
                            }
                    }
                    newWindowButton
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: viewModel.activeWindowID) { _, newID in
                // Keep the current tab in view (a switch can come from any
                // attached device, not just a tap here).
                guard let newID else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
        .background(
            // Transparent: the terminal background (paneBgColor behind) flows
            // through the bar (and under the home indicator — the backdrop
            // already fills it), so the floor fuses with the terminal instead
            // of wearing a hardcoded hex. The chips wear their own glass
            // (BarItemGlass); the bar itself stays bare.
            Color.clear
        )
        .alert(closeAlertTitle, isPresented: Binding(
            get: { pendingClose != nil },
            set: { if !$0 { pendingClose = nil } }
        )) {
            Button("Close Window", role: .destructive) {
                if let id = pendingClose { viewModel.closeWindow(id) }
                pendingClose = nil
            }
            Button("Cancel", role: .cancel) { pendingClose = nil }
        } message: {
            Text("The processes running in it will be terminated.")
        }
        .sheet(isPresented: $showCustomSheet) {
            NewWindowSheet(title: "New Window") { path, command in
                Task { await viewModel.newListWindow(.custom(path: path, command: command)) }
            }
        }
        .alert("Move to New Session", isPresented: Binding(
            get: { pendingMove != nil },
            set: { if !$0 { pendingMove = nil } }
        )) {
            TextField("Session name", text: $moveSessionName)
            Button("Move") {
                // Same landing pipeline as a menu pick: a typed name may
                // match an EXISTING session, so the prompt can still follow.
                if let id = pendingMove { moveWindow(id, to: moveSessionName) }
                pendingMove = nil
            }
            Button("Cancel", role: .cancel) { pendingMove = nil }
        } message: {
            Text("The window keeps running — it moves to the new session.")
        }
        .confirmationDialog(
            "Move to “\(landingChoice?.session ?? "")”",
            isPresented: Binding(
                get: { landingChoice != nil },
                set: { if !$0 { landingChoice = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Into Current Window (Parallel)") {
                if let c = landingChoice { moveWindow(c.window, to: c.session, landing: .joinCurrentWindow) }
                landingChoice = nil
            }
            Button("As New Window (Focus)") {
                if let c = landingChoice { moveWindow(c.window, to: c.session, landing: .newWindow) }
                landingChoice = nil
            }
            Button("Cancel", role: .cancel) { landingChoice = nil }
        } message: {
            Text("That session isn't settled into Parallel or Focus yet. Where should this land?")
        }
    }

    /// Landing a dragged tab on `target` gives it that tab's position — drop
    /// where you want it to end up.
    ///
    /// The payload is the window ID's own text (`@7`) rather than a custom
    /// transfer type, which would mean a UTType declared in the Info.plist and
    /// kept in sync for a two-character string. Foreign text dropped in from
    /// another app therefore reaches here too, and is refused by the same check
    /// that guards a stale ID: it has to name a window this session still has.
    private func drop(_ items: [String], onto target: TmuxWindowID) -> Bool {
        dropTarget = nil
        guard let dragged = items.first.flatMap({ TmuxWindowID(string: $0) }),
              dragged != target,
              viewModel.windows.contains(where: { $0.id == dragged }),
              let destination = position(of: target) else { return false }
        Task { await viewModel.reorderWindow(dragged, toIndex: destination) }
        return true
    }

    private func position(of id: TmuxWindowID) -> Int? {
        viewModel.windows.firstIndex { $0.id == id }
    }

    private func shift(_ id: TmuxWindowID, earlier: Bool) {
        Task { await viewModel.shiftWindow(id, earlier: earlier) }
    }

    /// Run the move; an unsettled target bounces back as the landing dialog.
    private func moveWindow(_ id: TmuxWindowID, to session: String,
                            landing: MoveLanding = .auto) {
        Task {
            if await viewModel.moveWindow(id, toSession: session, landing: landing)
                == .needsLandingChoice {
                landingChoice = (id, session)
            }
        }
    }

    private var closeAlertTitle: String {
        let name = pendingClose.map { viewModel.windowDisplayName($0) } ?? ""
        return "Close “\(name)”?"
    }

    /// The two creation seeds — same pair as the iPad/macOS sidebar.
    private var newWindowButton: some View {
        Menu {
            Button {
                Task { await viewModel.newListWindow(.duplicateCurrent) }
            } label: {
                Label("Duplicate Current", systemImage: "plus.square.on.square")
            }
            Button {
                showCustomSheet = true
            } label: {
                Label("Path & Command…", systemImage: "terminal")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.bentoInkDim)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .modifier(BarItemGlass(isActive: false, state: .idle))
                .contentShape(Capsule())
        }
    }
}

// MARK: - New window / split "path + command" form

/// The "specify path + command" mini-sheet, shared by List's "+" menu and
/// Tiled's "Split — Path & Command…". Empty command = plain shell; empty path
/// = inherit the current pane's directory.
struct NewWindowSheet: View {
    var title: String
    var onCreate: (String?, String?) -> Void

    @State private var path = ""
    @State private var agentPreset: AgentPreset = .none
    @State private var customCommand = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Working Directory") {
                    // The path lives on the remote host, so it stays typed —
                    // a local file picker would point at the wrong machine.
                    TextField("Empty = current directory", text: $path)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Command") {
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
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(path.isEmpty ? nil : path, resolvedCommand)
                        dismiss()
                    }
                    .disabled(!canCreate)
                }
            }
        }
        .presentationDetents([.medium])
    }

    /// nil = plain shell (no agent); otherwise the chosen agent's launch command
    /// or the user's custom command.
    private var resolvedCommand: String? {
        switch agentPreset {
        case .none:
            return nil
        case .custom:
            let trimmed = customCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        default:
            return agentPreset.command
        }
    }

    /// Custom needs a non-empty command; every other preset is always valid.
    private var canCreate: Bool {
        agentPreset != .custom
            || !customCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Liquid-glass capsule for the window tab bar's chips — each tab and the
/// "+" button. The bar itself stays transparent so the terminal flows through
/// it; only the items wear glass. iOS 26: the chip's glass is tinted by its
/// window's state (`chromeAccentHex` — working blue, awaiting amber, idle
/// plain); the active chip wears the full color, inactive chips a weakened
/// version of the same, so the bar shows every window's state at a glance
/// while the active tab stays the strongest. Earlier systems: the flat bento
/// chip with the emerald ring. The chip's content (dot, label, badge) is
/// INSIDE the glassEffect — anything layered after glass gets swallowed by
/// the material.
private struct BarItemGlass: ViewModifier {
    var isActive: Bool
    var state: PaneState = .idle

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            let glass = tint.map { Glass.regular.tint($0).interactive() }
                ?? Glass.regular.interactive()
            content.glassEffect(glass, in: .capsule)
        } else {
            content
                .background(Capsule().fill(isActive ? Color.bentoSurfaceHi : Color.bentoSurface))
                .overlay(
                    Capsule().strokeBorder(isActive ? Color.bentoEmerald : Color.bentoBorder,
                                           lineWidth: isActive ? 1.5 : 1)
                )
        }
    }

    /// State accent for the glass, from the canonical palette (working blue /
    /// awaiting amber) — full strength when active, half when not, so the
    /// state reads on every chip and the active one is the loudest. Idle has
    /// no state accent: the active chip wears the theme accent (emerald) so a
    /// resting window's selected tab still stands out; inactive idle chips
    /// wear plain glass.
    private var tint: Color? {
        if let hex = state.chromeAccentHex {
            let base = Color(PaneState.uiColor(hex: hex))
            return isActive ? base : base.opacity(0.5)
        }
        return isActive ? Color.bentoEmerald : nil
    }
}

private struct WindowTab: View {
    var name: String
    var state: PaneState
    var paneCount: Int
    var isActive: Bool

    var body: some View {
        HStack(spacing: 6) {
            // State icon — same glyph language as the sidebar rows: play =
            // working, question = awaiting, hollow ring = idle. Active: white,
            // matching the text (the tinted chip owns the color then);
            // inactive: the state color.
            Image(systemName: stateIconName)
                .font(.system(size: 12))
                .foregroundStyle(isActive ? Color.white : Color(STTheme.dotColor(for: state)))

            Text(name.isEmpty ? "window" : name)
                .font(.system(.footnote, design: .monospaced))
                // One active rule for every state: the chip is colored (state
                // tint, or the theme accent when idle) and the text is white
                // against it (same rule as the voice compass's lit discs).
                // Inactive chips sit on plain/weakened glass, dim ink reads.
                .foregroundStyle(isActive ? Color.white : Color.bentoInkDim)
                .lineLimit(1)
                .frame(maxWidth: 140)

            if paneCount > 1 {
                Text("\(paneCount)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.bentoInkDim)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.bentoShell))
                    .overlay(Capsule().strokeBorder(Color.bentoBorder, lineWidth: 1))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        // Glass chip on iOS 26, tinted by the window's state — active wears
        // the full color, inactive a weakened version of the same. Flat bento
        // chip with the emerald ring on earlier systems (deployment target 17).
        .modifier(BarItemGlass(isActive: isActive, state: state))
        .contentShape(Capsule())
    }

    private var stateIconName: String {
        switch state {
        case .working:       return "play.circle.fill"
        case .awaitingInput: return "questionmark.circle.fill"
        case .idle:          return "circle"
        }
    }
}

// MARK: - Divider overlay (drag to resize)

/// A transparent overlay over the tiled panes. It is touch-transparent except
/// within a few points of a divider between two adjacent panes, where it claims
/// the touch to drag-resize them (sends tmux `resize-pane`). Everywhere else,
/// touches fall through to the panes. iOS mirror of the macOS `DividerOverlay`.
final class TileDividerOverlay: UIView {
    /// Touch grab sizes (the pointer-driven macOS overlay uses a symmetric 10).
    /// Vertical dividers are CENTRED on the line. Horizontal dividers STRADDLE
    /// it — generous above (the upper pane's free surface) but only a little
    /// below, so the band sits on the border yet barely covers the lower pane's
    /// title bar, which is the drag-to-swap handle.
    static let hotZone = DividerHotZone(verticalThickness: 34, aboveLine: 26, belowLine: 6)

    var dividers: [PaneDivider] = [] { didSet { setNeedsDisplay() } }
    /// Points per tmux cell, set by the host so drag distance → cell delta.
    var pointsPerCell: CGPoint?
    /// (paneID, vertical, signed incremental cell delta) during a live drag.
    var onResize: ((TmuxPaneID, Bool, Int) -> Void)?

    /// The drag in progress — cell-delta math and live line position, shared
    /// with the macOS overlay.
    private var drag: DividerDrag?

    private static let accent = UIColor(red: 0.20, green: 0.80, blue: 0.55, alpha: 1.0)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func divider(at point: CGPoint) -> PaneDivider? {
        dividers.first { $0.hotRect.contains(point) }
    }

    // Transparent except over a divider hot zone, so panes get all other touches.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        divider(at: point) != nil
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            let p = g.location(in: self)
            drag = divider(at: p).map { DividerDrag(divider: $0, startPoint: p) }
            setNeedsDisplay()
        case .changed:
            guard drag != nil, let ppc = pointsPerCell else { return }
            let cells = drag!.advance(to: g.location(in: self), pointsPerCell: ppc)
            setNeedsDisplay()   // the live line follows the finger even between cells
            guard cells != 0 else { return }
            onResize?(drag!.divider.paneID, drag!.divider.vertical, cells)
        default:
            drag = nil
            setNeedsDisplay()
        }
    }

    override func draw(_ rect: CGRect) {
        for d in dividers {
            stroke(d, at: d.position, color: UIColor(white: 1, alpha: 0.30), width: 1.5)
        }
        // The line being dragged tracks the finger (tmux relayout lags), drawn in
        // the accent colour so the drag is clearly visible.
        if let drag {
            stroke(drag.divider, at: drag.livePosition, color: Self.accent, width: 2)
        }
    }

    private func stroke(_ d: PaneDivider, at pos: CGFloat, color: UIColor, width: CGFloat) {
        color.setStroke()
        let path = UIBezierPath()
        path.lineWidth = width
        if d.vertical {
            path.move(to: CGPoint(x: pos, y: d.hotRect.minY))
            path.addLine(to: CGPoint(x: pos, y: d.hotRect.maxY))
        } else {
            path.move(to: CGPoint(x: d.hotRect.minX, y: pos))
            path.addLine(to: CGPoint(x: d.hotRect.maxX, y: pos))
        }
        path.stroke()
    }
}

/// Hides the navigation bar while fullscreen; untouched otherwise. iOS 26's
/// `.automatic` visibility changes the content safe area (shrinking the
/// container view — observed on a device), so non-fullscreen must not touch
/// the bar at all. iOS 18+ API with a deployment-target-17 fallback.
private struct FullscreenNavBar: ViewModifier {
    var isFullscreen: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isFullscreen {
            if #available(iOS 18.0, *) {
                content.toolbarVisibility(.hidden, for: .navigationBar)
            } else {
                content.toolbar(.hidden, for: .navigationBar)
            }
        } else {
            content
        }
    }
}
