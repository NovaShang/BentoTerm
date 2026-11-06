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

    let floatingToolbar = FloatingQuickKeysToolbar()
    /// Collapsed quick-keys bar (a perfect-circle chevron). Persisted per
    /// device, same convention as `fullscreenMode`. Pure bar-internal state —
    /// it never touches the reserved band or the grid, so it has no layout
    /// didSet hook.
    static let quickKeysCollapsedKey = "quickKeysBarCollapsed"
    var quickKeysCollapsed = false
    let findBar = PaneFindBar()
    /// The pane the find bar is searching. Held so the bar keeps talking to the
    /// same surface even if the active pane changes underneath it.
    weak var findTargetVC: TerminalContainerVC?
    /// Height the find bar hides, folded into `bottomOcclusion` so the content
    /// pans up and a match on the last rows isn't left behind the bar.
    var findReserve: CGFloat = 0
    var keyboardInsetBottom: CGFloat = 0

    /// Height of the inline compose bar (ComposeBar), which rides the keyboard's
    /// top edge; 0 when it's not showing. Published by the bar itself (measured),
    /// observed below. Extends the bottom occlusion so composing pans the cursor
    /// line clear of keyboard + bar — the bar exists to type while WATCHING the
    /// terminal.
    var composeReserve: CGFloat = 0
    var composeBarSubs: Set<AnyCancellable> = []

    /// The slice of the page hidden behind bottom chrome — the keyboard plus,
    /// while composing, the inline compose bar on top of it (keyboard down →
    /// the bar rests on the bottom safe inset instead). `pageRect` runs to the
    /// very bottom edge (no reserved bottom inset), so this is the full covered
    /// height. Bottom chrome shrinks the VIEWPORT, never the page (PRD
    /// §2.2/§2.6), so this drives content panning only, never tmux.
    var bottomOcclusion: CGFloat {
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
    var windowSizeIsForeign: Bool {
        sizingMode != .tracking
    }

    /// Holds the pane VCs. When the page (tmux size) is larger than the viewport
    /// (PRD §2.2, Pinned), this view is bigger than the screen and two-finger pan
    /// translates it. When page ≤ viewport it sits top-left, no scroll.
    let contentView = UIView()
    /// Pan offset of the content view (≤ 0 on each axis), in points.
    var contentOffset: CGPoint = .zero

    /// Transparent overlay over the panes that claims touches only on a divider
    /// between adjacent panes, to drag-resize them (tmux resize-pane). Mirrors
    /// the macOS `DividerOverlay`. Lives inside `contentView` so it pans with the
    /// page; kept on top of the pane views after each tile layout.
    let dividerOverlay = TileDividerOverlay()

    /// Font cell size (re-learned whenever a surface reports a new one), the
    /// last cols×rows pushed to tmux, and the push debounce.
    private lazy var sizer = TiledClientSizer { [weak self] grid in
        self?.viewModel?.resizeTmuxClient(cols: grid.cols, rows: grid.rows)
    }

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
            self?.viewModel?.resizeBoundary(paneID, vertical: vertical, deltaCells: deltaCells)
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
    static let cursorKeyboardMargin: CGFloat = 10

    @objc private func activePaneAppearanceChanged() {
        DispatchQueue.main.async { [weak self] in self?.syncBackgroundToActivePane() }
    }

    func syncBackgroundToActivePane() {
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
    var focusedOrActiveVC: TerminalContainerVC? {
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
        guard let viewModel,
              let target = focusedOrActiveVC,
              let provider = target.pathPreviewContext else { return }
        // The pane the sheet browses — nil for a plain (non-tmux) shell.
        let paneID = paneControllers.first(where: { $0.value === target })?.key
        let browser = PaneFileTreeBrowser(viewModel: viewModel, paneID: paneID,
                                          contextProvider: provider) { [weak self, weak target] path, _ in
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

    /// The focused pane's file context for SwiftUI chrome that needs to browse
    /// (the new-window / split sheet's directory picker). Same provider the
    /// preview uses, so the picker can never read a different disk. nil when
    /// there is nothing to browse (no pane, or no reachable source) — callers
    /// fall back to a typed path.
    func focusedPathPreviewContext() -> PathPreviewContext? {
        focusedOrActiveVC?.pathPreviewContext?()
    }

    // MARK: - Non-tmux single pane

    func setupSinglePane() {
        guard let viewModel else { return }
        let vc = makeContainerVC()
        vc.bindToTerminalVM(viewModel)
        vc.pathPreviewContext = { [weak self, weak vc] in
            self?.makePathPreviewContext(paneVM: nil, vc: vc)
        }
        vc.linkOriginProvider = { [weak self] in self?.makeLinkOrigin(paneID: nil) }
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
        vc.linkOriginProvider = { [weak self, weak paneVM] in
            self?.makeLinkOrigin(paneID: paneVM.map { "\($0.pane.id)" })
        }
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
        vc.onSplitPathCommandRequested = { [weak self] in
            self?.viewModel?.selectPane(paneID)
            self?.bridge?.showsSplitPathCommand = true
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
    /// 1×1 with no remembered mode, or a mixed external structure) asks where
    /// to land, then re-runs with the explicit choice.
    private func movePane(_ paneID: TmuxPaneID, toSessionNamed name: String) {
        Task { [weak self] in
            guard let vm = self?.viewModel else { return }
            await vm.movePane(paneID, toSession: name) { [weak self] session in
                await self?.askMoveLanding(session: session)
            }
        }
    }

    private func askMoveLanding(session: String) async -> MoveLanding? {
        let copy = SessionPromptCopy.landing(session)
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: copy.title, message: copy.message,
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: copy.joinCurrentWindow, style: .default) { _ in
                continuation.resume(returning: .joinCurrentWindow)
            })
            alert.addAction(UIAlertAction(title: copy.newWindow, style: .default) { _ in
                continuation.resume(returning: .newWindow)
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                continuation.resume(returning: nil)
            })
            present(alert, animated: true)
        }
    }

    /// Every pane on iOS lives on the other end of an ssh connection, so a
    /// `localhost` URL printed in one points at that machine — never at this
    /// phone. The host id is what the forwarder keys its tunnels on, so it has
    /// to be the same id `SSHService` registered under.
    private func makeLinkOrigin(paneID: String?) -> LinkOrigin? {
        guard let viewModel else { return nil }
        return LinkOrigin(
            paneID: paneID,
            host: LinkHost(remoteID: viewModel.host.id.uuidString,
                           label: viewModel.host.displayName))
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
        if sizer.learn(cellWidthPx: size.cellWidthPx, cellHeightPx: size.cellHeightPx) {
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
    func deviceFitGrid(reserveTitleRow: Bool) -> (cols: Int, rows: Int)? {
        guard let cellPx = sizer.cellPx else { return nil }
        let rect = pageRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        return PaneTiling.clientGrid(viewport: rect.size, cellPixels: cellPx,
                                     scale: displayScale, reserveTitleRow: reserveTitleRow)
    }

    func pushClientSize(cols: Int, rows: Int) {
        dlog("[pushClientSize] \(cols)x\(rows)")
        // No policy gate here: the view model gates the WIRE (a foreign `manual`
        // owner silences the `refresh-client`) and records the measurement
        // either way. Dropping it here instead left the engine believing this
        // device still fit whatever it measured before the other device took
        // the size — a stale grid to resize the session to on take-over.
        sizer.request(.init(cols: cols, rows: rows))
    }

    // MARK: - Layout

    /// Whether we're showing a single full pane (zoomed focus or non-tmux).
    var isFocusLayout: Bool {
        singlePaneVC != nil || viewModel?.zoomedPaneID != nil
            || (viewModel?.paneViewModels.count ?? 0) <= 1
    }

    var effectiveFocusID: TmuxPaneID? {
        if let z = viewModel?.zoomedPaneID { return z }
        if (viewModel?.paneViewModels.count ?? 0) == 1 { return viewModel?.paneViewModels.first?.paneID }
        return viewModel?.activePaneID
    }

    /// Page rect = the area the tmux page maps to. KEYBOARD-INDEPENDENT (PRD
    /// §2.6): the keyboard never resizes tmux.
    var pageRect: CGRect {
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
    var pointsPerCell: CGSize? { sizer.pointsPerCell(scale: displayScale) }

    // MARK: - Drag a pane's title bar onto another pane (swap / dock)

    /// The translucent landing preview shown while a title-bar drag hovers a
    /// target pane; created on the first hover of a drag, torn down when the
    /// drag ends. Mirrors the macOS host's PaneDropZoneOverlay.
    var dropOverlay: PaneDropZoneOverlayView?

    // MARK: - Page sizing & content offset

    /// Base visibility: a pane exists to receive keys. The toolbar additionally
    /// hides while the keyboard is up — the docked accessory key bar covers keys
    /// then, and the toolbar's reserved band sits behind the keyboard anyway.
    var hasVisiblePane: Bool { singlePaneVC != nil || !paneControllers.isEmpty }

    /// Reserve the quick-keys band in the page? Non-fullscreen with a pane.
    /// KEYBOARD-INDEPENDENT on purpose (PRD §2.6): show/hide of the keyboard,
    /// compose bar, or find bar never resizes tmux, so the band stays reserved
    /// while they cover it (it's behind them anyway). Collapse is a bar-internal
    /// state — it shrinks the bar, never the band.
    var quickKeysBandActive: Bool {
        !isFullscreen && hasVisiblePane
    }
}

/// The Files sheet's tree, re-rooted when its pane `cd`s while the sheet is
/// open. A directory change raises no event a client can see; tmux pushes it
/// (`paneWorkingDirectories`, a `refresh-client -B` subscription), and that
/// value is the tree's reload key. On tmux < 3.2 nothing is pushed, the key
/// stays nil, and the sheet keeps the root it opened with — as before.
private struct PaneFileTreeBrowser: View {
    @ObservedObject var viewModel: TerminalViewModel
    let paneID: TmuxPaneID?
    let contextProvider: () -> PathPreviewContext?
    let onOpenFile: (String, PathPreviewContext) -> Void

    var body: some View {
        FileTreeBrowserView(
            reloadKey: paneID.flatMap { viewModel.paneWorkingDirectories[$0] },
            contextProvider: contextProvider,
            onOpenFile: onOpenFile)
    }
}
