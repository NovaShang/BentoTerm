import UIKit
import SwiftUI
import Combine
import BentoAgentKit
import BentoSessionKit
import BentoTmuxKit
import BentoFilePreviewKit
import BentoFoundationKit
import BentoGhosttyKit
import BentoUISharedKit

/// Hosts a single libghostty terminal surface for one pane.
/// Owns its narrow title bar (above the terminal) and the gesture wiring for
/// voice press, pane selection tap, and double-tap-to-keyboard.
///
/// The terminal engine is reached only through `BentoTerminalCore.TerminalSurface`
/// — this VC is the single adapter between Bento's pane/session orchestration and
/// the concrete renderer.
final class TerminalContainerVC: UIViewController {
    private(set) var surface: GhosttyTerminalSurface!
    /// The quick-keys bar controller — its row floats in the host's shared
    /// keyboard-bar overlay (internal so the host can bind the active pane's
    /// row).
    let accessoryView = KeyboardAccessoryView()
    let titleBar = PaneTitleBar()

    /// Translucent color wash over the terminal surface that signals pane state
    /// (working / awaiting), so state reads at a glance — not just from the
    /// title-bar dot. Idle = clear. Hit-test transparent so taps, selection, and
    /// the voice long-press all reach the surface underneath.
    let stateTint = UIView()

    /// The engine's ACTUALLY rendered background (initial theme resolution,
    /// config reload, or a runtime OSC 11) — the only honest source for chrome
    /// that must fuse with the terminal. Mirrors the macOS window host. `nil`
    /// until the first report, and cleared on theme/appearance change so a stale
    /// value can't outlive a config reload (surfaces re-report once they render).
    var reportedBgColor: UIColor?

    private var cancellables = Set<AnyCancellable>()

    var paneVM: PaneViewModel?
    var terminalVM: TerminalViewModel?

    /// Voice gesture pipeline. Parent VC injects the controller; we just
    /// forward `handleLongPress` states.
    weak var voiceController: VoiceInputController?

    // MARK: - Callbacks (set by parent)

    /// User tapped the pane — request that this pane become active. Parent VC
    /// translates this into `viewModel.selectPane(...)`.
    var onSelectPaneTapped: (() -> Void)?

    /// User asked to split this pane (horizontally or vertically).
    var onSplitRequested: ((_ horizontal: Bool) -> Void)?
    /// User asked to split this pane, choosing the folder and command first.
    var onSplitPathCommandRequested: (() -> Void)?

    /// Whether the pane menu should offer Split entries — checked when the
    /// menu opens. Split only exists in Tiled mode (in List a split would
    /// build a third shape); nil = show (non-tmux panes never show the menu).
    var showsSplitActions: (() -> Bool)?

    /// User asked to close this pane.
    var onCloseRequested: (() -> Void)?

    /// The pane is in tmux copy-mode and the user scrolled it. Rows, positive =
    /// toward older output; parent forwards to `viewModel.scrollCopyMode`.
    /// Bento does not implement copy-mode — this is only so a pane that entered
    /// it from outside still answers the finger.
    var onCopyModeScroll: ((Int) -> Void)?

    /// User asked to leave tmux copy-mode.
    var onExitCopyMode: (() -> Void)?

    /// User asked to search this pane's scrollback. The find bar itself lives on
    /// the parent (it has to be positioned against the keyboard, which is a
    /// container-level concern), so this only reports the intent. A non-nil
    /// argument is a prefill from the engine's own search keybind.
    var onFindRequested: ((String?) -> Void)?

    /// User asked to toggle zoom (maximize / restore) on this pane.
    var onToggleZoom: (() -> Void)?

    /// Whether this pane is currently zoomed — the pane menu's Zoom /
    /// Unzoom entry reads it at open time (deferred element), so the host
    /// wires it once per active-pane change.
    var isZoomed: (() -> Bool)?

    /// Move-to-session targets: OTHER sessions on the server, read from the
    /// parent's cached list. Must be synchronous — an async fetch resolving
    /// after the submenu opened rebuilds the menu and collapses it back to
    /// the top level (observed live). The parent kicks a refresh alongside,
    /// so the cache is fresh by the next open.
    var moveTargets: (() -> [String])?

    /// User asked to move this pane out to the named session (created there
    /// if it doesn't exist yet). Moving the session's last pane makes the
    /// client follow it, so this is always available.
    var onMoveToSession: ((_ session: String) -> Void)?

    /// User is dragging this pane's title bar (tiled mode) onto another pane.
    /// Parent VC resolves the target + drop zone and swaps (center) or docks
    /// (edge). Mirrors the macOS host's title-bar drag-to-dock.
    var onTitleDrag: ((_ phase: PaneDrag.Phase) -> Void)?

    /// The surface reported its current size (cols × rows + cell px) after
    /// layout. Parent VC uses this to drive tmux client resize (refresh-client
    /// -C) and to learn the font cell size for tiling. Authoritative — any
    /// homemade cell-size math will drift from the engine's internal measurement
    /// and cause TUI wrap mismatches.
    var onSizeChanged: ((_ size: TerminalSurfaceSize) -> Void)?

    /// Path preview: how to reach this pane's files, built at tap time by the
    /// parent (it owns the session VM / transport, which can reconnect and
    /// swap under us). nil = feature unavailable for this pane.
    var pathPreviewContext: (() -> PathPreviewContext?)?
    /// Which machine this pane means by `localhost`. Set by the wrapper before
    /// the surface exists, so it is read through rather than copied.
    var linkOriginProvider: (@MainActor () -> LinkOrigin?)?

    /// Tiled mode: the container owns sizing (it computes one tmux client size
    /// for the whole viewport and sizes each surface to its exact tmux cell
    /// geometry). When true this VC does NOT push its own size to tmux. Also
    /// gates the focus border — one pane on screen has nothing to disambiguate.
    var tiled = false

    /// In tiled mode, the exact surface size (points) = tmux cols×rows × cell,
    /// set by the container so ghostty's grid matches the tmux pane grid. nil =
    /// fill the available area (focus / single-pane).
    var fixedTerminalCellSize: CGSize? {
        didSet { view.setNeedsLayout() }
    }

    /// Title-strip height for focus / single-pane mode (a comfortable touch
    /// target). In tiled mode the host overrides `titleBarHeight` to one cell.
    static let defaultTitleBarHeight: CGFloat = 32

    /// Title-strip height (points). The host sets this per layout: one character
    /// cell in tiled mode — so the strip occupies tmux's divider row between
    /// stacked panes, exactly as the macOS host does (the gap↔title-bar-height
    /// constraint that keeps irregular splits aligned) — and `defaultTitleBarHeight`
    /// in focus / single-pane mode.
    var titleBarHeight: CGFloat = TerminalContainerVC.defaultTitleBarHeight {
        didSet { if oldValue != titleBarHeight { view.setNeedsLayout() } }
    }

    /// Horizontal inset (points) of the surface inside the container. In tiled
    /// mode the host grows each container half a cell into the divider column on
    /// each side so side-by-side panes meet on the divider centerline; the
    /// surface keeps its exact cell size, inset by this much. 0 = flush.
    var surfaceInsetX: CGFloat = 0 {
        didSet { if oldValue != surfaceInsetX { view.setNeedsLayout() } }
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = STTheme.term
        // Tiled mode sizes the surface one cell larger than the pane (see the
        // container) so ghostty doesn't drop a column; clip the overflow.
        view.clipsToBounds = true
        setupSurface()
        setupTitleBar()
        attachGestures()
        applyTheme()
        observeAppearanceChanges()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        // NOTE: surface teardown is NOT done here — deinit is unreliable (and
        // can't touch MainActor state). Callers invoke teardown() explicitly
        // before the view leaves the hierarchy.
    }

    /// Stop rendering and free this pane's ghostty surface on the main thread,
    /// BEFORE the view/layer is torn down. Must be called explicitly when the
    /// pane is closed or the screen is dismissed — relying on deinit is unsafe
    /// (the display link keeps drawing into a half-freed Metal layer → crash).
    func teardown() {
        stopMomentum()
        hideTapChip()
        surface?.teardown()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The ThemeStore singleton seeds systemIsDark from UITraitCollection.current
        // at init — which is .unspecified that early, so it defaults to dark. Re-seed
        // from THIS view's real in-window trait so "Follow System" resolves correctly
        // even when the app launched already in its final appearance (no trait
        // "change" ever fires to correct it). See TerminalThemeStore.detectSystemIsDark.
        ThemeStore.shared.updateSystemIsDark(traitCollection.userInterfaceStyle == .dark)
        applyTheme()
    }

    /// The OS (or our forced override) flipped light/dark. UIColor-backed views
    /// recolor themselves, but the terminal surface and the CGColor-based pane
    /// chrome don't — re-resolve the theme slot and repaint them by hand.
    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        guard traitCollection.userInterfaceStyle != previous?.userInterfaceStyle else { return }
        ThemeStore.shared.updateSystemIsDark(traitCollection.userInterfaceStyle == .dark)
        reportedBgColor = nil   // appearance flip → surfaces re-report the new slot
        applyTheme()
        titleBar.recolor()
        applyPaneBorder(active: paneIsActive)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let tbh = titleBarHeight
        titleBar.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: tbh)
        if let fixed = fixedTerminalCellSize {
            // Cell-exact (tiled): inset by surfaceInsetX (half a divider cell) and
            // placed under the title bar; may overflow the tile by one cell on
            // purpose (clipped) so ghostty's grid >= tmux.
            surface.frame = CGRect(x: surfaceInsetX, y: tbh, width: fixed.width, height: fixed.height)
        } else {
            surface.frame = CGRect(x: 0, y: tbh, width: view.bounds.width,
                                   height: max(0, view.bounds.height - tbh))
        }
        dlog("[paneLayout] tbh=\(tbh) view=\(view.bounds) surface=\(surface.frame)")
        stateTint.frame = surface.frame
        layoutRendererHealthBanner()
    }

    // MARK: - Renderer health

    /// Shown when libghostty reports its Metal renderer stopped. Without it the
    /// pane simply goes black and stays black — indistinguishable from a program
    /// that printed nothing.
    private var rendererHealthBanner: UILabel?

    private func setRendererHealthy(_ healthy: Bool) {
        if healthy {
            rendererHealthBanner?.removeFromSuperview()
            rendererHealthBanner = nil
            return
        }
        guard rendererHealthBanner == nil else { return }
        let label = UILabel()
        label.text = "Renderer stopped — this pane won't update"
        label.font = .systemFont(ofSize: 11)
        label.textAlignment = .center
        label.textColor = .white
        // Brand salmon (docs/bento-icon.svg): a warning that is deliberately NOT
        // one of the pane state colors, because this is not a pane state.
        label.backgroundColor = UIColor(red: 0xE8 / 255.0, green: 0x9B / 255.0,
                                        blue: 0x7C / 255.0, alpha: 1)
        view.addSubview(label)
        rendererHealthBanner = label
        layoutRendererHealthBanner()
    }

    private func layoutRendererHealthBanner() {
        guard let banner = rendererHealthBanner else { return }
        banner.frame = CGRect(x: 0, y: titleBarHeight, width: view.bounds.width, height: 20)
    }

    // MARK: - Setup

    private func setupTitleBar() {
        let tbh = titleBarHeight
        titleBar.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: tbh)
        titleBar.autoresizingMask = [.flexibleWidth, .flexibleBottomMargin]
        // The title bar is now just [● state-dot] [title]. Zoom + the pane menu
        // live on the floating toolbar (the strip is one cell tall in tiled
        // mode — too short to host touch targets). See `paneMenu` / onToggleZoom.
        view.addSubview(titleBar)

        // Drag the title bar onto another pane to swap with it or dock beside
        // it (tiled mode), exactly like the macOS host's drop zones. The
        // parent resolves the target + zone under the finger.
        let titleDrag = UIPanGestureRecognizer(target: self, action: #selector(handleTitleDrag(_:)))
        titleBar.addGestureRecognizer(titleDrag)
    }

    @objc private func handleTitleDrag(_ g: UIPanGestureRecognizer) {
        // Window coordinates so the parent can hit-test across every pane.
        let win = g.location(in: nil)
        switch g.state {
        case .began:   onTitleDrag?(.began)
        case .changed: onTitleDrag?(.moved(win))
        case .ended:   onTitleDrag?(.ended(win))
        default:       onTitleDrag?(.cancelled)
        }
    }

    /// The pane's action menu (Split [Tiled only] / Profile / Close). Built once
    /// and cached — every dynamic entry sits inside a
    /// `UIDeferredMenuElement.uncached` block, so it re-resolves each time the
    /// menu opens and always reflects current state. Hosted by the floating
    /// toolbar.
    private(set) lazy var paneMenu: UIMenu = makePaneMenu()

    private func setupSurface() {
        let tbh = titleBarHeight
        surface = GhosttyTerminalSurface(theme: currentTerminalTheme())
        surface.frame = CGRect(x: 0, y: tbh, width: view.bounds.width,
                               height: max(0, view.bounds.height - tbh))
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // Bytes the engine wants to send to the host (keystrokes, query
        // responses). Apply the soft-Ctrl modifier here, mirroring the old
        // SwiftTerm `send` path.
        surface.onInput = { [weak self] data in
            self?.handleSurfaceInput(data)
        }
        surface.linkOriginProvider = { [weak self] in self?.linkOriginProvider?() }
        surface.onSizeChanged = { [weak self] size in
            guard let self else { return }
            // Tiled mode: the container owns the tmux client size; a pane never
            // pushes its own (its surface is deliberately sized to a fixed cell
            // geometry). Still forward the metrics so the container can learn
            // the cell pixel size.
            if !self.tiled, self.paneVM == nil {
                self.terminalVM?.resizeTerminal(cols: size.columns, rows: size.rows)
            }
            self.onSizeChanged?(size)
        }
        surface.onCopyModeScroll = { [weak self] rows in
            self?.onCopyModeScroll?(rows)
        }
        surface.onRendererHealthChanged = { [weak self] healthy in
            self?.setRendererHealthy(healthy)
        }
        // The ENGINE asking for a find UI (its own search keybind fired — a
        // hardware ⌘F on iPad). The needle is a prefill, usually the selection.
        surface.onSearchStartRequested = { [weak self] needle in
            self?.onFindRequested?(needle)
        }

        // The quick-keys bar is no longer an inputAccessoryView (2026-08-02):
        // it floats as a shared overlay above the keyboard, like the compose
        // bar — see TerminalWrapperView's FloatingKeyboardBar. The surface
        // stays the plain first responder, so the keyboard is bare and ~40pt
        // shorter, and mode switches are pure overlay swaps.
        accessoryView.onKeyTap = { [weak self] key in
            self?.handleAccessoryKey(key)
        }
        // Dismiss-keyboard button on the accessory bar (double-tap no longer
        // dismisses — it selects text in keyboard mode).
        accessoryView.onDismissKeyboard = { [weak self] in
            self?.surface.resignFirstResponder()
        }
        // One-tap back from raw keyboard to the compose box; makes compose the
        // remembered mode so the next double-tap resumes it. NO explicit
        // resignFirstResponder: openManagedCompose focuses the compose TextField,
        // which takes the first responder over from the surface — the keyboard
        // stays up through the switch (an explicit resign first would collapse
        // it and re-show it).
        accessoryView.onSwitchToCompose = { [weak self] in
            guard let self else { return }
            Self.prefersRawKeyboard = false
            self.openManagedCompose()
        }

        // Native edit menu (Copy / Select All) for text selection.
        surface.addInteraction(editMenuInteraction)

        view.addSubview(surface)

        // State wash above the surface (below the title bar, added next in
        // setupTitleBar). Passes all touches through to the terminal.
        stateTint.isUserInteractionEnabled = false
        stateTint.backgroundColor = .clear
        stateTint.frame = surface.frame
        view.addSubview(stateTint)
    }

    /// Apply the soft-Ctrl modifier and route to the transport. The engine has
    /// already encoded the keystroke; we only fold in Bento's on-screen Ctrl key.
    private func handleSurfaceInput(_ data: Data) {
        var bytes = [UInt8](data)
        if accessoryView.isCtrlActive, bytes.count == 1 {
            let byte = bytes[0]
            if byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z") {
                bytes = [byte - UInt8(ascii: "a") + 1]
            } else if byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") {
                bytes = [byte - UInt8(ascii: "A") + 1]
            }
            accessoryView.deactivateCtrl()
        }
        sendData(Data(bytes))
    }

    var lastScrollPoint: CGPoint = .zero

    // MARK: Scroll momentum (inertial fling)

    /// Display link that keeps the scroll going after the finger lifts. The
    /// surface is a bare Metal view, so UIKit gives us no physics — we decay
    /// the pan's release velocity at UIScrollView's .normal rate and feed each
    /// frame's delta through the same surface.scroll path the finger used.
    /// Deliberately NOT gated on scrollback state: when a TUI owns scrolling
    /// (alt-screen arrow-key translation) the app receives the same decaying
    /// event stream a trackpad fling would produce.
    var momentumLink: CADisplayLink?
    /// Remaining fling velocity in points/second (+ = finger moving down,
    /// i.e. revealing older scrollback — same sign as the pan deltas).
    var momentumVelocity: CGFloat = 0
    /// Where the finger lifted. ghostty applies scroll at the tracked mouse
    /// position, so every momentum delta re-anchors there.
    var momentumAnchor: CGPoint = .zero
    /// Points traveled during the glide, for the settle log (feel tuning).
    var momentumTravel: CGFloat = 0

    /// Per-millisecond velocity multiplier for the glide. UIScrollView's
    /// .normal (0.998) matches system scroll views. Overridable via the
    /// `fling_decel_per_ms` default for no-rebuild feel tuning — and for UI
    /// tests: a slower decay (e.g. 0.9995 ≈ 4× glide) is the only way to
    /// outlast Maestro's ~3s inter-step latency and land a press mid-glide.
    static let decelRate: CGFloat = {
        let v = UserDefaults.standard.double(forKey: "fling_decel_per_ms")
        return (v > 0.9 && v < 1.0) ? v : UIScrollView.DecelerationRate.normal.rawValue
    }()

    /// True while a long-press text selection drag is in progress (suppresses
    /// scroll). Only happens in keyboard mode.
    var isSelecting = false

    /// Keyboard-up mode: when the surface is first responder we behave like a
    /// normal iOS text view — double-tap/long-press select text instead of
    /// summoning the keyboard / recording voice. Keyboard is dismissed via the
    /// accessory bar button, not by double-tap.
    var keyboardMode: Bool { surface.isFirstResponder }

    /// The remembered input mode: double-tap resumes whichever the user last used
    /// (compose box vs raw keyboard). Persisted so it survives relaunches.
    static var prefersRawKeyboard: Bool {
        get { UserDefaults.standard.bool(forKey: "input_prefers_raw_keyboard") }
        set { UserDefaults.standard.set(newValue, forKey: "input_prefers_raw_keyboard") }
    }

    // MARK: - Tap chips (tap a file path or a URL → chip → open)

    var tapChip: TapConfirmChip?
    var tapChipHighlight: PathHighlightUIView?
    var tapChipDismissWork: DispatchWorkItem?
    /// Serial number so a slow stat can't surface a chip for a superseded tap.
    var pathTapSeq = 0

    /// Ports already offered in this pane. A dev server reprints its banner on
    /// every restart, and an agent restarts it all day — offering the same port
    /// each time would be a popup that never stops.
    var devServerOffers = DevServerOffers()


    // MARK: - Text selection edit menu

    private lazy var editMenuInteraction = UIEditMenuInteraction(delegate: self)

    func presentEditMenu(at point: CGPoint) {
        let cfg = UIEditMenuConfiguration(identifier: nil, sourcePoint: point)
        editMenuInteraction.presentEditMenu(with: cfg)
    }

    // MARK: - Selection handles (PRD §3.8)

    var startHandle: SelectionHandle?
    var endHandle: SelectionHandle?
    /// Cached selection extent in `view` coordinates: start = top-left corner,
    /// end = bottom-right corner. Used to re-anchor while dragging a handle.
    var selStartCorner: CGPoint?
    var selEndCorner: CGPoint?

    // MARK: - Title & State

    func updateTitle(_ title: String) {
        titleBar.titleLabel.text = title
    }

    func updatePaneState(_ state: PaneState, doneUnseen: Bool, active: Bool) {
        titleBar.paneState = state
        titleBar.agentFinishedUnseen = doneUnseen
        titleBar.isActivePane = active
        applyPaneBorder(active: active)

        // The pane surround (and, via syncBackgroundToActivePane, the reserved
        // band below the toolbar) FUSES the terminal bg with the pane's running
        // state; the surface keeps the plain terminal bg, its per-state signal
        // staying the translucent stateTint wash on top.
        applyBackgrounds(animated: true)
    }

    /// Last-applied active state, so theme/layout changes can re-derive the
    /// right border without re-plumbing focus.
    private(set) var paneIsActive = false

    func applyPaneBorder(active: Bool) {
        paneIsActive = active
        // Borders only show in tiled mode; a focused / single pane fills the
        // screen and needs no frame.
        guard tiled else {
            view.layer.borderWidth = 0   // one pane on screen → no focus frame
            return
        }
        // Focus cue — mirrors the macOS host: the app accent (tint) on the pane
        // you're using, a near-invisible hairline on the rest. Pane state stays on
        // the title band + wash, so the focus ring never competes with green/amber.
        // (Drop targets are previewed by the parent's PaneDropZoneOverlayView,
        // not the border.)
        view.layer.borderWidth = active ? 2.0 : 0.5
        view.layer.borderColor = (active ? view.tintColor : PaneChromeColors.idleBorder()).cgColor
    }

    // MARK: - Binding

    func bindToPaneVM(_ vm: PaneViewModel) {
        self.paneVM = vm
        vm.onDataReceived = { [weak self] data in
            // Watch for `Local: http://localhost:5173/`. The byte prefilter runs
            // HERE, before the main hop — the output path is not allowed to
            // cost anything, and almost no chunk contains "://".
            if DevServerDetector.mightAnnounce(data) {
                Task { @MainActor [weak self] in self?.noticeDevServer(in: data) }
            }
            // Deferred so a bind that runs before the surface exists still lands
            // once it's ready. feedProgressively slices a large replay blob so the
            // main thread isn't frozen by one synchronous ghostty parse (BUG-011).
            DispatchQueue.main.async {
                self?.feedProgressively(data)
            }
        }

        cancellables.removeAll()

        // Push the pane's mouse-reporting mode into the surface so touch-scroll
        // forwards to an alt-screen TUI instead of paging local scrollback. The
        // flag comes from tmux's mouse_any/sgr, refreshed on the state poll
        // (control mode never streams the program's mouse-enable). Fires now with
        // the current value and on every change. Mirrors the macOS host.
        vm.$pane
            .map { GhosttyTerminalSurface.MouseReporting(any: $0.mouseAny, sgr: $0.mouseSGR) }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] mr in self?.surface?.mouseReporting = mr }
            .store(in: &cancellables)

        // tmux copy-mode (`pane_in_mode`). Control mode gives no other signal:
        // tmux draws the mode's UI as ordinary pane content, so without this the
        // pane just stops responding to scroll with no explanation.
        vm.$pane
            .map(\.inMode)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] inMode in
                self?.surface?.tmuxInMode = inMode
                self?.titleBar.modeBadge = inMode ? .copyMode : .none
            }
            .store(in: &cancellables)

        // The pane's label, re-derived on every tmux report — a rename
        // (`select-pane -T`) and a change of foreground command both land here.
        // Reading it once at bind time is what left the strip showing whatever
        // was running when the surface was created (macOS re-derives its titles
        // on every layout pass, so the two disagreed).
        vm.$pane
            .map { PaneChrome.title(for: $0) }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] title in self?.updateTitle(title) }
            .store(in: &cancellables)
    }

    // MARK: - Progressive feed (BUG-011)

    /// Slices of a large replay blob still waiting to be fed, drained one per
    /// runloop turn. Also holds live output that arrives mid-drain, so nothing
    /// paints ahead of the older history.
    private var replayQueue: [Data] = []
    private var isDrainingReplay = false
    /// Slice size for the incremental replay. Small enough that one ghostty
    /// parse fits comfortably in a frame; the pane history cap is ~512 KB, so a
    /// full replay is at most ~16 slices.
    private static let replayChunkSize = 32 * 1024

    /// Feed terminal bytes to the surface without freezing the main thread on a
    /// big blob. Live output is small and fed immediately (unchanged fast path);
    /// a history replay — up to ~512 KB pushed in one call when a surface re-binds
    /// on session re-entry — is sliced and drained one piece per runloop turn so
    /// touch handling and other live sessions interleave. Fixes the "blank, then
    /// slow refresh, whole UI frozen" re-entry hang (BUG-011).
    private func feedProgressively(_ data: Data) {
        // Once a replay is draining, everything queues so order is preserved —
        // a small live chunk must not paint before the older history finishes.
        if isDrainingReplay {
            enqueueSliced(data)
            return
        }
        guard data.count > Self.replayChunkSize else {
            surface?.feed(data)
            return
        }
        enqueueSliced(data)
        dlog("[BUG-011] progressive replay \(data.count)B in \(replayQueue.count) slices")
        isDrainingReplay = true
        drainReplayQueue()
    }

    private func enqueueSliced(_ data: Data) {
        guard data.count > Self.replayChunkSize else { replayQueue.append(data); return }
        var i = data.startIndex
        while i < data.endIndex {
            let j = data.index(i, offsetBy: Self.replayChunkSize, limitedBy: data.endIndex) ?? data.endIndex
            replayQueue.append(data.subdata(in: i..<j))
            i = j
        }
    }

    private func drainReplayQueue() {
        guard !replayQueue.isEmpty else { isDrainingReplay = false; return }
        surface?.feed(replayQueue.removeFirst())
        DispatchQueue.main.async { [weak self] in self?.drainReplayQueue() }
    }

    func bindToTerminalVM(_ vm: TerminalViewModel) {
        self.terminalVM = vm
        vm.onRawDataReceived = { [weak self] data in
            DispatchQueue.main.async {
                self?.surface.feed(data)
            }
        }
    }

    /// The terminal cursor (insertion point) rect in `target`'s coordinate space,
    /// from the surface's ghostty IME point. nil if unavailable. Used to keep the
    /// real cursor above the keyboard (it isn't always at the pane bottom).
    func cursorRect(in target: UIView) -> CGRect? {
        guard let surface, let r = surface.cursorRect() else { return nil }
        return surface.convert(r, to: target)
    }

    // MARK: - Input

    private func sendData(_ data: Data) {
        if let paneVM { paneVM.sendInput(data) }
        else { terminalVM?.sendData(data) }
    }

    private func sendString(_ string: String) {
        if let paneVM { paneVM.sendString(string) }
        else { terminalVM?.sendString(string) }
    }

    /// Route both the inputAccessoryView and the floating quick-keys toolbar
    /// through the same key handler. The Ctrl state is owned by the accessory
    /// view; the floating toolbar mirrors that state visually via its own
    /// `isCtrlActive` property.
    func handleAccessoryKey(_ key: AccessoryKey) {
        switch key {
        case .escape: sendString("\u{1B}")
        case .tab: sendString("\t")
        case .ctrl: accessoryView.toggleCtrl()
        case .enter: sendString("\r")
        case .up: sendString("\u{1B}[A")
        case .down: sendString("\u{1B}[B")
        case .right: sendString("\u{1B}[C")
        case .left: sendString("\u{1B}[D")
        case .pipe: sendString("|")
        case .slash: sendString("/")
        case .tilde: sendString("~")
        case .dash: sendString("-")
        case .paste: surface.pasteFromClipboard()
        }
    }
}
