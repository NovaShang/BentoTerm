import UIKit
import SwiftUI
import Combine
import BentoAgentKit
import BentoSessionKit
import BentoTmuxKit
import BentoFilePreviewKit
import BentoFoundationKit
import BentoGhosttyKit

/// Phases of a pane title-bar drag (tiled mode), reported to the parent so it
/// can resolve the pane + drop zone under the finger (center = swap, edge =
/// dock). Points are in WINDOW coordinates (`gesture.location(in: nil)`) so
/// the parent can hit-test across all panes. Mirrors the macOS host's
/// `PaneDragPhase`.
enum TitleDragPhase {
    case began
    case moved(CGPoint)
    case ended(CGPoint)
    case cancelled
}

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
    private let stateTint = UIView()

    /// The engine's ACTUALLY rendered background (initial theme resolution,
    /// config reload, or a runtime OSC 11) — the only honest source for chrome
    /// that must fuse with the terminal. Mirrors the macOS window host. `nil`
    /// until the first report, and cleared on theme/appearance change so a stale
    /// value can't outlive a config reload (surfaces re-report once they render).
    private var reportedBgColor: UIColor?

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

    /// Whether this pane is currently zoomed — the pane menu's Maximize /
    /// Restore entry reads it at open time (deferred element), so the host
    /// wires it once per active-pane change.
    var isZoomed: (() -> Bool)?

    /// User picked a detection profile for this pane (nil = auto-detect).
    var onSetProfile: ((_ profileID: String?) -> Void)?

    /// Current forced profile id for this pane (nil = auto), for the menu check.
    var currentProfileID: (() -> String?)?

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
    var onTitleDrag: ((_ phase: TitleDragPhase) -> Void)?

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

    /// Tiled mode: the container owns sizing (it computes one tmux client size
    /// for the whole viewport and sizes each surface to its exact tmux cell
    /// geometry). When true this VC does NOT push its own size to tmux. Also
    /// drives the title bar's look (fused state band vs. blend into the
    /// terminal background).
    var tiled = false {
        didSet { titleBar.isTiled = tiled }
    }

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
        hidePathChip()
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
        titleBar.surfaceColor = view.backgroundColor ?? STTheme.term
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
        surface.onTitleChanged = { [weak self] title in
            self?.updateTitle(title)
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

    private var lastScrollPoint: CGPoint = .zero

    // MARK: Scroll momentum (inertial fling)

    /// Display link that keeps the scroll going after the finger lifts. The
    /// surface is a bare Metal view, so UIKit gives us no physics — we decay
    /// the pan's release velocity at UIScrollView's .normal rate and feed each
    /// frame's delta through the same surface.scroll path the finger used.
    /// Deliberately NOT gated on scrollback state: when a TUI owns scrolling
    /// (alt-screen arrow-key translation) the app receives the same decaying
    /// event stream a trackpad fling would produce.
    private var momentumLink: CADisplayLink?
    /// Remaining fling velocity in points/second (+ = finger moving down,
    /// i.e. revealing older scrollback — same sign as the pan deltas).
    private var momentumVelocity: CGFloat = 0
    /// Where the finger lifted. ghostty applies scroll at the tracked mouse
    /// position, so every momentum delta re-anchors there.
    private var momentumAnchor: CGPoint = .zero
    /// Points traveled during the glide, for the settle log (feel tuning).
    private var momentumTravel: CGFloat = 0

    /// Per-millisecond velocity multiplier for the glide. UIScrollView's
    /// .normal (0.998) matches system scroll views. Overridable via the
    /// `fling_decel_per_ms` default for no-rebuild feel tuning — and for UI
    /// tests: a slower decay (e.g. 0.9995 ≈ 4× glide) is the only way to
    /// outlast Maestro's ~3s inter-step latency and land a press mid-glide.
    private static let decelRate: CGFloat = {
        let v = UserDefaults.standard.double(forKey: "fling_decel_per_ms")
        return (v > 0.9 && v < 1.0) ? v : UIScrollView.DecelerationRate.normal.rawValue
    }()

    /// True while a long-press text selection drag is in progress (suppresses
    /// scroll). Only happens in keyboard mode.
    private var isSelecting = false

    /// Keyboard-up mode: when the surface is first responder we behave like a
    /// normal iOS text view — double-tap/long-press select text instead of
    /// summoning the keyboard / recording voice. Keyboard is dismissed via the
    /// accessory bar button, not by double-tap.
    private var keyboardMode: Bool { surface.isFirstResponder }

    /// The remembered input mode: double-tap resumes whichever the user last used
    /// (compose box vs raw keyboard). Persisted so it survives relaunches.
    static var prefersRawKeyboard: Bool {
        get { UserDefaults.standard.bool(forKey: "input_prefers_raw_keyboard") }
        set { UserDefaults.standard.set(newValue, forKey: "input_prefers_raw_keyboard") }
    }

    // MARK: - Path preview (tap a file path → chip → sheet)

    private var pathChip: PathPreviewChip?
    private var pathChipHighlight: PathHighlightUIView?
    private var pathChipDismissWork: DispatchWorkItem?
    /// Serial number so a slow stat can't surface a chip for a superseded tap.
    private var pathTapSeq = 0

    /// Detect a path under the tap. A self-contained explicit token (`/…`,
    /// `~/…`, `./…`, quoted) shows the chip immediately; everything else —
    /// bare relatives, TUI wrap-chain joins, `…`-truncated suffixes — resolves
    /// through `SmartPathResolver` (direct stat → tree search → ancestors)
    /// first, so prose can't produce phantom chips and incomplete paths still
    /// find their file.
    private func maybeShowPathChip(at point: CGPoint) {
        pathTapSeq += 1
        let seq = pathTapSeq
        hidePathChip()
        guard PathPreviewSettings.isEnabled, pathPreviewContext != nil else { return }
        let scan = surface.pathTapHits(at: point, wrapCols: paneVM?.pane.width)
        let hits = scan.hits
        guard !hits.isEmpty else { return }

        if hits[0].fastPath {
            showPathChip(hits[0], at: point)
        } else {
            Task { [weak self] in
                guard let self, let context = self.pathPreviewContext?() else { return }
                guard let res = try? await SmartPathResolver.resolveFirst(
                    paths: hits.map(\.path), rootHints: scan.rootHints, context: context),
                      self.pathTapSeq == seq else { return }
                self.showPathChip(hits[res.index], at: point, resolvedPath: res.resolvedPath)
            }
        }
    }

    private func showPathChip(_ hit: SurfacePathHitEngine.TapHit, at point: CGPoint,
                              resolvedPath: String? = nil) {
        let off = surface.frame.origin

        let highlight = pathChipHighlight ?? PathHighlightUIView(frame: .zero)
        highlight.frame = surface.frame
        highlight.rects = hit.rects
        view.addSubview(highlight)
        pathChipHighlight = highlight

        let chip = pathChip ?? PathPreviewChip(frame: .zero)
        pathChip = chip
        let name = ((resolvedPath ?? hit.path) as NSString).lastPathComponent
        chip.configure(fileName: name, maxWidth: view.bounds.width - 32)
        chip.onTap = { [weak self] in
            self?.hidePathChip()
            self?.presentPathPreviewSheet(path: resolvedPath ?? hit.path, line: hit.line)
        }
        // Above the finger, clamped inside the pane.
        var center = CGPoint(x: off.x + point.x, y: off.y + point.y - 44)
        let half = chip.bounds.width / 2
        center.x = min(max(center.x, half + 8), view.bounds.width - half - 8)
        center.y = max(center.y, chip.bounds.height / 2 + 8)
        chip.center = center
        view.addSubview(chip)

        chip.alpha = 0
        chip.transform = CGAffineTransform(scaleX: 0.9, y: 0.9).translatedBy(x: 0, y: 6)
        UIView.animate(withDuration: 0.22, delay: 0,
                       usingSpringWithDamping: 0.82, initialSpringVelocity: 0.4) {
            chip.alpha = 1
            chip.transform = .identity
        }
        HapticService.shared.sent()

        pathChipDismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hidePathChip(animated: true) }
        pathChipDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
    }

    private func hidePathChip(animated: Bool = false) {
        pathChipDismissWork?.cancel()
        pathChipDismissWork = nil
        guard let chip = pathChip else { return }
        let highlight = pathChipHighlight
        pathChip = nil
        pathChipHighlight = nil
        if animated {
            UIView.animate(withDuration: 0.18, animations: {
                chip.alpha = 0
                highlight?.alpha = 0
            }, completion: { _ in
                chip.removeFromSuperview()
                highlight?.removeFromSuperview()
            })
        } else {
            chip.removeFromSuperview()
            highlight?.removeFromSuperview()
        }
    }

    /// Also the landing for a file tapped in the browsable tree, which is why
    /// it isn't private.
    func presentPathPreviewSheet(path: String, line: Int?) {
        guard let context = pathPreviewContext?() else { return }
        let model = FilePreviewSheetModel(path: path)
        model.load(path: path, line: line, context: context)
        let host = UIHostingController(rootView: FilePreviewSheet(model: model))
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.prefersEdgeAttachedInCompactHeight = true
        }
        present(host, animated: true)
    }

    // MARK: - Text selection edit menu

    private lazy var editMenuInteraction = UIEditMenuInteraction(delegate: self)

    private func presentEditMenu(at point: CGPoint) {
        let cfg = UIEditMenuConfiguration(identifier: nil, sourcePoint: point)
        editMenuInteraction.presentEditMenu(with: cfg)
    }

    // MARK: - Selection handles (PRD §3.8)

    private var startHandle: SelectionHandle?
    private var endHandle: SelectionHandle?
    /// Cached selection extent in `view` coordinates: start = top-left corner,
    /// end = bottom-right corner. Used to re-anchor while dragging a handle.
    private var selStartCorner: CGPoint?
    private var selEndCorner: CGPoint?

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
    private var paneIsActive = false

    private func applyPaneBorder(active: Bool) {
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
        let faint = UIColor(white: STTheme.isLight ? 0 : 1, alpha: STTheme.isLight ? 0.09 : 0.06)
        view.layer.borderColor = (active ? view.tintColor : faint).cgColor
    }

    // MARK: - Binding

    func bindToPaneVM(_ vm: PaneViewModel) {
        self.paneVM = vm
        vm.onDataReceived = { [weak self] data in
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
                self?.titleBar.inCopyMode = inMode
            }
            .store(in: &cancellables)

        updateTitle(vm.pane.currentCommand ?? "shell")
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
        vm.onPredictionText = { [weak self] text in self?.surface.setPredictedText(text) }
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

// MARK: - Theme & appearance

extension TerminalContainerVC {
    private func observeAppearanceChanges() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange),
            name: .terminalThemeChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(fontDidChange),
            name: .terminalFontChanged, object: nil)
        // Self-heal for the post-unlock resume race: if this pane was rebuilt
        // while the font-size default transiently read empty (see
        // STTheme.terminalFontSize), the surface came up at the fallback size.
        // Re-applying on foreground re-reads the (now readable) value; the
        // surface only recreates when the size actually differs.
        NotificationCenter.default.addObserver(
            self, selector: #selector(fontDidChange),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        // The engine reported the background it's ACTUALLY rendering (initial
        // resolution, config reload, or a runtime OSC 11) — the only honest
        // source for chrome that must fuse with the terminal. Mirrors the macOS
        // window host's surfaceBackgroundChanged subscription.
        NotificationCenter.default.addObserver(
            self, selector: #selector(surfaceBackgroundChanged),
            name: .ghosttySurfaceBackgroundChanged, object: nil)
    }

    @objc private func themeDidChange() {
        reportedBgColor = nil   // surfaces re-report after the config reload
        applyTheme(); titleBar.recolor(); applyPaneBorder(active: paneIsActive)
    }
    @objc private func fontDidChange() { applyTheme() }

    /// Build the engine-agnostic theme from the current ThemeStore selection.
    private func currentTerminalTheme() -> TerminalTheme {
        let t = ThemeStore.shared.current
        let fontSize = Double(STTheme.terminalFontSize)
        // Trace the size EVERY build: the user-reported "font grows after
        // app-switch resume" means some surface picks up a theme whose size
        // isn't the stored one (iPad's no-stored-value fallback is 14) — this
        // line plus [surface] created… in debug.log pins which and when.
        dlog("[theme] terminal theme fontSize=\(fontSize) (stored=\(UserDefaults.standard.double(forKey: "terminal_font_size")))")
        return TerminalTheme(
            background: t.bg,
            foreground: t.fg,
            ansi: t.ansi,
            fontSize: fontSize
        )
    }

    private func resolvedTerminalBackground() -> UIColor {
        reportedBgColor ?? ThemeStore.shared.current.bgColor
    }

    /// Push the current terminal bg + pane state onto the container surround,
    /// the surface, the title bar (whose fused band re-derives from `surfaceColor`),
    /// and the state wash. Animated on state change, instant on bg reports /
    /// theme reapplies.
    private func applyBackgrounds(animated: Bool) {
        let bgColor = resolvedTerminalBackground()
        let surround = STTheme.fusedBackground(
            bg: bgColor, state: titleBar.paneState, doneUnseen: titleBar.agentFinishedUnseen)
        let tint = titleBar.paneState.tintUIColor ?? .clear
        let apply = {
            self.view.backgroundColor = surround
            self.surface.backgroundColor = bgColor
            self.titleBar.surfaceColor = bgColor
            self.stateTint.backgroundColor = tint
        }
        if animated { UIView.animate(withDuration: 0.26, animations: apply) } else { apply() }
    }

    /// The engine reported a new bg (or the theme/appearance re-applied) —
    /// re-derive everything from the current pane state, without animating.
    private func applyTerminalBackground() {
        applyBackgrounds(animated: false)
    }

    @objc private func surfaceBackgroundChanged(_ note: Notification) {
        guard let s = note.object as? GhosttyTerminalSurface,
              s === surface,
              let color = s.reportedBackgroundColor else { return }
        reportedBgColor = color
        applyTerminalBackground()
    }

    /// Apply the user-selected color theme.
    private func applyTheme() {
        surface.applyTheme(currentTerminalTheme())
        // The surface re-reports its bg once the new config renders; until then
        // `resolvedTerminalBackground` falls back to the theme bg.
        applyTerminalBackground()
    }
}

// MARK: - Gestures

extension TerminalContainerVC {
    /// Inline gesture wiring. The libghostty surface has no built-in
    /// tap-to-keyboard or long-press selection, so unlike the SwiftTerm era we
    /// don't have to suppress any pre-existing recognizers — we just add ours.
    ///   - Voice press commits at 180ms (see VoicePressGesture).
    ///   - Single tap selects the pane.
    ///   - Double tap toggles the keyboard.
    private func attachGestures() {
        let voicePress = VoicePressGesture(target: self, action: #selector(handleVoicePress(_:)))
        voicePress.delegate = self
        // Finger-down prewarm: overlap the mic engine's cold start with the
        // 180ms hold threshold, so voice capture is live the moment the
        // overlay appears (macOS has had this since bba1c59; iOS didn't —
        // that gap cost the first syllables of every recording).
        voicePress.onTouchDown = { [weak self] in
            guard let self else { return }
            // A landing finger catches an in-flight fling immediately — the
            // defining iOS-scroll behavior — before any recognizer arms.
            self.stopMomentum()
            guard !self.keyboardMode else { return }
            self.voiceController?.prewarm()
        }
        // Catch-touch rule (mirrors UIScrollView's dead touch during
        // deceleration): a press that lands while the scrollback is still
        // gliding only pins the content — it must not arm voice (keyboard
        // down) or drag-selection (keyboard up). Deliberately no velocity
        // floor: any live glide swallows the press, so the failure mode is
        // "press again", never "accidental recording". Lift + press to talk.
        voicePress.shouldArm = { [weak self] in
            guard let self, self.momentumLink != nil else { return true }
            dlog("fling: caught by press — voice/selection veto")
            return false
        }
        surface.addGestureRecognizer(voicePress)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.cancelsTouchesInView = false
        singleTap.delaysTouchesBegan = false
        singleTap.delaysTouchesEnded = false
        singleTap.delegate = self
        surface.addGestureRecognizer(singleTap)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        doubleTap.delegate = self
        surface.addGestureRecognizer(doubleTap)

        // Two-finger tap keeps Bento's own tap (link, path preview) reachable in
        // a pane whose program has taken the single-finger one. `voicePress`
        // fails itself the moment a second finger lands, and the single-tap
        // recognizer requires exactly one touch, so neither competes for this.
        let localTap = UITapGestureRecognizer(target: self, action: #selector(handleLocalTap(_:)))
        localTap.numberOfTapsRequired = 1
        localTap.numberOfTouchesRequired = 2
        localTap.cancelsTouchesInView = false
        localTap.delegate = self
        surface.addGestureRecognizer(localTap)

        // Single-finger immediate drag → scrollback (PRD §3.1/§3.7). The voice
        // press fails on early movement (its 6pt slop), so a drag scrolls while
        // a still hold records — no extra coordination needed beyond ignoring
        // scroll while voice is actively recording.
        let scrollPan = UIPanGestureRecognizer(target: self, action: #selector(handleScrollPan(_:)))
        scrollPan.minimumNumberOfTouches = 1
        scrollPan.maximumNumberOfTouches = 1
        scrollPan.delegate = self
        surface.addGestureRecognizer(scrollPan)
    }

    @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
        // A tap clears an active selection (like iOS) before anything else.
        if keyboardMode, surface.hasSelection {
            surface.clearSelection(at: gesture.location(in: surface))
            hideSelectionHandles()
            return
        }
        onSelectPaneTapped?()
        let p = gesture.location(in: surface)
        // A program that turned on mouse tracking gets the tap as a click. Until
        // now only the WHEEL was forwarded, so an alt-screen TUI could be
        // scrolled but never pressed — and pressing things is most of what
        // Claude Code's fullscreen mode is. Selecting the pane still happens
        // first: focus is Bento's, the click is the program's.
        //
        // This takes the single-finger tap away from Bento's own handlers, which
        // is why they move to the two-finger tap below — the same trade the Mac
        // makes by checking ⌘-click before forwarding.
        if surface.forwardTap(at: p) {
            noteMouseGrabbed()
            return
        }
        // Tap on a URL opens it in the browser (after pane selection — both are
        // what the user means). Load-bearing for onboarding: a remote agent's
        // sign-in prints an OAuth URL that must open on THIS device.
        // A URL miss falls through to the file-path chip (disjoint detectors).
        if surface.openLinkIfPresent(at: p, wrapCols: paneVM?.pane.width) {
            return
        }
        maybeShowPathChip(at: p)
    }

    /// Two-finger tap = Bento's own tap, even when a program owns the mouse:
    /// open a link, preview a file path. The touch stand-in for ⌘-click, which
    /// the Mac surface checks before it forwards for exactly this reason.
    /// Harmless when nothing owns the mouse — it just does what one finger did.
    @objc private func handleLocalTap(_ gesture: UITapGestureRecognizer) {
        onSelectPaneTapped?()
        let p = gesture.location(in: surface)
        if surface.openLinkIfPresent(at: p, wrapCols: paneVM?.pane.width) { return }
        maybeShowPathChip(at: p)
    }

    /// Say it once, the first time a pane swallows a tap. A program grabbing the
    /// mouse is invisible — the user just finds that tapping a path stopped
    /// previewing it — and the Mac has the same problem, which is why it shows
    /// "hold ⇧ to select" the moment the grab bites.
    private func noteMouseGrabbed() {
        guard TipCenter.shared.consume(.mouseGrabbed) else { return }
        showToast("This app is using taps — two fingers for BentoTerm")
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if keyboardMode {
            // Typing → double-tap selects the word (standard iOS behavior); it
            // no longer dismisses the keyboard (use the accessory ⌄ button).
            let p = gesture.location(in: surface)
            if surface.selectWord(at: p) {
                refreshSelectionHandles()
                presentEditMenu(at: p)
            }
        } else if Self.prefersRawKeyboard {
            // Last time the user chose raw — resume it.
            _ = surface.becomeFirstResponder()
        } else {
            // Default (and last-remembered): the managed compose box — the
            // zero-latency local buffer for writing a line/message. Raw keys are
            // one tap away inside the box ("直接输入").
            openManagedCompose()
        }
    }

    /// Double-tap entry into the app's one managed input surface (the same
    /// inline compose bar voice uses). Targets this pane, then opens it empty +
    /// focused for typing. Falls back to the raw keyboard if the voice
    /// controller isn't wired.
    private func openManagedCompose() {
        guard let controller = voiceController else { _ = surface.becomeFirstResponder(); return }
        onSelectPaneTapped?()   // send to the pane the user double-tapped
        controller.readScreenText = { [weak self] in self?.surface?.readScrollback() }
        controller.onRequestRawKeyboard = { [weak self] in
            // "直接输入" — switching to raw makes raw the remembered mode.
            // Synchronous becomeFirstResponder: it must take over from the
            // compose TextField BEFORE the bar is dismissed, or the keyboard
            // collapses and re-shows through the switch.
            Self.prefersRawKeyboard = true
            _ = self?.surface.becomeFirstResponder()
        }
        controller.beginManualCompose()
    }

    @objc private func handleVoicePress(_ gesture: VoicePressGesture) {
        if gesture.state == .began {
            dlog("[voice] press began (keyboardMode=\(keyboardMode), controller=\(voiceController != nil))")
        }
        // Keyboard mode: long-press starts a drag text selection (not voice).
        if keyboardMode {
            let p = gesture.currentLocation()
            switch gesture.state {
            case .began:
                isSelecting = true
                hideSelectionHandles()
                surface.selectionBegin(at: p)
            case .changed:
                surface.selectionExtend(to: p)
            case .ended:
                isSelecting = false
                surface.selectionEnd()
                if surface.hasSelection {
                    refreshSelectionHandles()
                    presentEditMenu(at: p)
                }
            case .cancelled, .failed:
                isSelecting = false
                surface.selectionEnd()
            default:
                break
            }
            return
        }

        // Keyboard down: long-press = voice.
        guard let controller = voiceController, let view = gesture.view else { return }
        // Selecting on press makes voice transcripts land on the right pane
        // even if the user starts holding on a non-active pane.
        if gesture.state == .began {
            onSelectPaneTapped?()
            // Bind the Qwen context-biasing source to THIS pane's surface for the
            // recording that's about to start.
            controller.readScreenText = { [weak self] in self?.surface?.readScrollback() }
        }
        let local = gesture.currentLocation()
        // VoiceInputController positions its overlay in screen (window) coords,
        // so convert before forwarding.
        let screen = view.convert(local, to: nil)
        controller.handleLongPress(state: gesture.state, location: screen)
    }
}

// MARK: - Scroll & momentum

extension TerminalContainerVC {
    @objc private func handleScrollPan(_ g: UIPanGestureRecognizer) {
        // Don't scroll while voice recording or while a selection drag is active.
        if voiceController?.isRecording == true || isSelecting { return }
        let p = g.location(in: surface)
        switch g.state {
        case .began:
            stopMomentum()
            hidePathChip()   // rows shift under the chip; a stale anchor lies
            lastScrollPoint = p
        case .changed:
            let dy = p.y - lastScrollPoint.y
            let dx = p.x - lastScrollPoint.x
            lastScrollPoint = p
            // Finger down (dy>0) reveals older scrollback — natural touch paging.
            surface.scroll(deltaX: dx, deltaY: dy, at: p)
        case .ended:
            startMomentum(releaseVelocity: g.velocity(in: surface).y, at: p)
        default:
            break
        }
    }

    /// Begin the inertial phase of a scroll fling (vertical only — terminals
    /// have no horizontal scroll). Below the floor velocity the finger came to
    /// a controlled rest before lifting, so there is nothing to continue.
    private func startMomentum(releaseVelocity vy: CGFloat, at point: CGPoint) {
        dlog("fling: release v=\(Int(vy))pt/s")
        guard abs(vy) > 50 else { return }
        momentumVelocity = vy
        momentumAnchor = point
        momentumTravel = 0
        let link = CADisplayLink(target: MomentumLinkProxy(self),
                                 selector: #selector(MomentumLinkProxy.tick(_:)))
        // Track ProMotion: a 120Hz decay reads noticeably smoother on
        // row-quantized content than the 60Hz default.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        momentumLink = link
    }

    private func stopMomentum() {
        momentumLink?.invalidate()
        momentumLink = nil
        momentumVelocity = 0
    }

    fileprivate func momentumTick(_ link: CADisplayLink) {
        // The pane can close or the screen dismiss mid-flight; surface.scroll
        // itself is safe after teardown (nil engine handle), but there is no
        // point ticking a detached view.
        guard let surface, surface.window != nil else { stopMomentum(); return }
        let dt = link.targetTimestamp - link.timestamp
        surface.scroll(deltaX: 0, deltaY: momentumVelocity * dt, at: momentumAnchor)
        momentumTravel += momentumVelocity * dt
        momentumVelocity *= pow(Self.decelRate, dt * 1000)
        if abs(momentumVelocity) < 30 {
            dlog("fling: settled after \(Int(momentumTravel))pt")
            stopMomentum()
        }
    }
}

// MARK: - Selection handles & copy

extension TerminalContainerVC {
    /// Number of terminal columns a string occupies on one line (CJK/wide → 2).
    private func displayColumns(of s: Substring) -> Int {
        var n = 0
        for scalar in s.unicodeScalars {
            let v = scalar.value
            let wide = (v >= 0x1100 && v <= 0x115F) || (v >= 0x2E80 && v <= 0xA4CF) ||
                       (v >= 0xAC00 && v <= 0xD7A3) || (v >= 0xF900 && v <= 0xFAFF) ||
                       (v >= 0xFF00 && v <= 0xFF60) || (v >= 0x1F300 && v <= 0x1FAFF)
            n += wide ? 2 : 1
        }
        return n
    }

    /// Show / reposition the two draggable selection handles from the engine's
    /// current selection geometry. Hides them when there's no selection or the
    /// keyboard is down (selection only exists in keyboard mode).
    private func refreshSelectionHandles() {
        guard keyboardMode, surface.hasSelection, let geo = surface.selectionGeometry() else {
            hideSelectionHandles()
            return
        }
        let off = surface.frame.origin            // surface sits below the title bar
        let cell = geo.cell
        let startCorner = CGPoint(x: geo.topLeft.x + off.x, y: geo.topLeft.y + off.y)

        // ghostty only reports the selection's top-left, so derive the end:
        // single line → start + text width; multi-line → last line width, N rows
        // down (approximate, but the handle becomes exact once dragged).
        let text = surface.selectedText() ?? ""
        let endCorner: CGPoint
        if text.contains("\n") {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let lastCols = displayColumns(of: lines.last ?? "")
            endCorner = CGPoint(x: off.x + CGFloat(lastCols) * cell.width,
                                y: startCorner.y + CGFloat(lines.count) * cell.height)
        } else {
            endCorner = CGPoint(x: startCorner.x + CGFloat(displayColumns(of: text[...])) * cell.width,
                                y: startCorner.y + cell.height)
        }

        let start = ensureHandle(\.startHandle, isStart: true)
        let end = ensureHandle(\.endHandle, isStart: false)
        start.cellHeight = cell.height
        end.cellHeight = cell.height
        start.positionStemTop(CGPoint(x: startCorner.x, y: startCorner.y))
        end.positionStemTop(CGPoint(x: endCorner.x, y: endCorner.y - cell.height))
        view.bringSubviewToFront(start)
        view.bringSubviewToFront(end)
        start.isHidden = false
        end.isHidden = false
        selStartCorner = startCorner
        selEndCorner = endCorner
    }

    private func ensureHandle(_ keyPath: ReferenceWritableKeyPath<TerminalContainerVC, SelectionHandle?>,
                              isStart: Bool) -> SelectionHandle {
        if let h = self[keyPath: keyPath] { return h }
        let h = SelectionHandle(isStart: isStart)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleSelectionHandlePan(_:)))
        h.addGestureRecognizer(pan)
        view.addSubview(h)
        self[keyPath: keyPath] = h
        return h
    }

    private func hideSelectionHandles() {
        startHandle?.isHidden = true
        endHandle?.isHidden = true
        selStartCorner = nil
        selEndCorner = nil
    }

    @objc private func handleSelectionHandlePan(_ g: UIPanGestureRecognizer) {
        guard let handle = g.view as? SelectionHandle,
              let cell = surface.selectionGeometry()?.cell,
              let startCorner = selStartCorner, let endCorner = selEndCorner else { return }

        // Anchor at the cell center of the OTHER (fixed) end; extend to the
        // finger, clamped into the surface.
        let fixedCorner = handle.isStart ? endCorner : startCorner
        let anchorView = handle.isStart
            ? CGPoint(x: fixedCorner.x - cell.width / 2, y: fixedCorner.y - cell.height / 2)
            : CGPoint(x: fixedCorner.x + cell.width / 2, y: fixedCorner.y - cell.height / 2)

        let p = g.location(in: view)
        let off = surface.frame.origin
        func toSurface(_ pt: CGPoint) -> CGPoint {
            CGPoint(x: min(max(pt.x - off.x, 1), surface.bounds.width - 1),
                    y: min(max(pt.y - off.y, 1), surface.bounds.height - 1))
        }

        switch g.state {
        case .began:
            surface.selectionBegin(at: toSurface(anchorView))
            surface.selectionExtend(to: toSurface(p))
        case .changed:
            surface.selectionExtend(to: toSurface(p))
            refreshSelectionHandles()
        case .ended, .cancelled, .failed:
            surface.selectionEnd()
            refreshSelectionHandles()
            if surface.hasSelection { presentEditMenu(at: p) }
        default:
            break
        }
    }

    private func copySelection() {
        guard let text = surface.selectedText(), !text.isEmpty else { return }
        UIPasteboard.general.string = text
        HapticService.shared.sent()
        showCopyToast()
    }

    private func showCopyToast() { showToast("Copied") }

    /// Brief centred-bottom toast. Was inlined in the copy path; the
    /// mouse-grabbed hint needs the same thing, and one-off teaching moments
    /// like these are exactly what it's for.
    fileprivate func showToast(_ text: String) {
        let label = UILabel()
        label.text = "  \(text)  "
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.backgroundColor = UIColor(white: 0, alpha: 0.78)
        label.layer.cornerRadius = 12
        label.layer.masksToBounds = true
        label.alpha = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -40),
            label.heightAnchor.constraint(equalToConstant: 30),
        ])
        UIView.animate(withDuration: 0.18, animations: { label.alpha = 1 }) { _ in
            UIView.animate(withDuration: 0.25, delay: 0.9, options: [],
                           animations: { label.alpha = 0 },
                           completion: { _ in label.removeFromSuperview() })
        }
    }
}

// MARK: - Pane menu

extension TerminalContainerVC {
    private func makePaneMenu() -> UIMenu {
        // Split entries are resolved when the menu OPENS (deferred), so a
        // mode switch after the menu was attached still hides/shows them
        // correctly. Tiled only — List mode has no split entry anywhere.
        let splitSection = UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self, self.showsSplitActions?() ?? true else {
                completion([])
                return
            }
            completion([
                UIAction(title: "Split Right (-h)",
                         image: UIImage(systemName: "rectangle.split.2x1")) { [weak self] _ in
                    self?.onSplitRequested?(true)
                },
                UIAction(title: "Split Down (-v)",
                         image: UIImage(systemName: "rectangle.split.1x2")) { [weak self] _ in
                    self?.onSplitRequested?(false)
                },
            ])
        }
        // Only offered while tmux actually has the pane in a mode. Resolved at
        // menu-open (deferred) like the split entries, since the mode can be
        // entered and left by another client at any moment.
        let copyModeSection = UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self, self.titleBar.inCopyMode else {
                completion([])
                return
            }
            completion([
                UIAction(title: "Exit tmux copy-mode",
                         image: UIImage(systemName: "arrow.uturn.backward")) { [weak self] _ in
                    self?.onExitCopyMode?()
                },
            ])
        }
        // Maximize / Restore — state resolved at menu-open (deferred) like the
        // split entries, since the zoom can flip under the user at any moment
        // (another client, or the old title-bar target). Moved off the quick
        // keys bar (2026-08-02 user decision: the bar was longer than the
        // screen; the zoom button and paste now live here).
        let zoomSection = UIDeferredMenuElement.uncached { [weak self] completion in
            let zoomed = self?.isZoomed?() ?? false
            completion([
                UIAction(title: zoomed ? "Restore" : "Maximize",
                         image: UIImage(systemName: zoomed
                             ? "arrow.down.right.and.arrow.up.left"
                             : "arrow.up.left.and.arrow.down.right")) { [weak self] _ in
                    self?.onToggleZoom?()
                },
            ])
        }
        return UIMenu(children: [
            UIAction(title: "Find…",
                     image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in
                self?.onFindRequested?(nil)
            },
            zoomSection,
            UIAction(title: "Paste",
                     image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                // Same path the bar's paste key used: the pane surface's
                // clipboard paste.
                self?.handleAccessoryKey(.paste)
            },
            splitSection,
            copyModeSection,
            makeProfileMenu(),
            makeMoveToSessionMenu(),
            UIAction(title: "Close Pane",
                     image: UIImage(systemName: "xmark"),
                     attributes: .destructive) { [weak self] _ in
                self?.onCloseRequested?()
            },
        ])
    }

    /// Pane menu → Move to Session: other sessions (from the parent's cached
    /// list), plus "New Session…" which prompts for a name. The pane keeps
    /// running — it lands as a window of the target session, and moving the
    /// session's last pane makes the client follow it there. Resolution must
    /// stay synchronous — see `moveTargets`.
    private func makeMoveToSessionMenu() -> UIMenu {
        let deferred = UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else { completion([]); return }
            var items: [UIMenuElement] = (self.moveTargets?() ?? []).map { name in
                UIAction(title: name) { [weak self] _ in
                    self?.onMoveToSession?(name)
                }
            }
            items.append(UIAction(title: "New Session…",
                                  image: UIImage(systemName: "plus")) { [weak self] _ in
                self?.promptMoveToNewSession()
            })
            completion(items)
        }
        return UIMenu(title: "Move to Session",
                      image: UIImage(systemName: "rectangle.portrait.and.arrow.right"),
                      children: [deferred])
    }

    private func promptMoveToNewSession() {
        let alert = UIAlertController(
            title: "Move to New Session",
            message: "The pane keeps running — it becomes a window of the new session.",
            preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Session name" }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Move", style: .default) { [weak self, weak alert] _ in
            guard let name = alert?.textFields?.first?.text, !name.isEmpty else { return }
            self?.onMoveToSession?(name)
        })
        present(alert, animated: true)
    }

    /// Pane menu → Change Profile (PRD §3.5). Built lazily each time the menu
    /// opens so the checkmark reflects the current override; "Auto" clears it.
    private func makeProfileMenu() -> UIMenu {
        let deferred = UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else { completion([]); return }
            let current = self.currentProfileID?()
            var items: [UIMenuElement] = [
                UIAction(title: "Auto (detect)", state: current == nil ? .on : .off) { [weak self] _ in
                    self?.onSetProfile?(nil)
                }
            ]
            for profile in ProfileStore.shared.profiles {
                items.append(UIAction(title: profile.name,
                                      state: current == profile.id ? .on : .off) { [weak self] _ in
                    self?.onSetProfile?(profile.id)
                })
            }
            completion(items)
        }
        return UIMenu(title: "Profile",
                      image: UIImage(systemName: "slider.horizontal.3"),
                      children: [deferred])
    }
}

// MARK: - UIGestureRecognizerDelegate

extension TerminalContainerVC: @preconcurrency UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Our tap / voice-press recognizers are passive and should coexist with
        // any recognizers the surface may add (scroll, etc.).
        return true
    }
}

// MARK: - UIEditMenuInteractionDelegate (text selection menu)

extension TerminalContainerVC: @preconcurrency UIEditMenuInteractionDelegate {
    func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                             menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        var items: [UIMenuElement] = []
        if surface.hasSelection {
            items.append(UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.copySelection()
            })
        }
        // Paste lands at the terminal cursor (bracketed-paste-safe). Offered only
        // when the clipboard actually has text, so the menu doesn't show a dead item.
        if UIPasteboard.general.hasStrings {
            items.append(UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                self?.surface.pasteFromClipboard()
            })
        }
        items.append(UIAction(title: "Select All", image: UIImage(systemName: "selection.pin.in.out")) { [weak self] _ in
            guard let self else { return }
            self.surface.selectAll()
            if self.surface.hasSelection { self.copySelectionMenuReshow() }
        })
        return UIMenu(children: items)
    }

    /// After Select All, re-show the menu so Copy is available on the new selection.
    private func copySelectionMenuReshow() {
        let p = CGPoint(x: surface.bounds.midX, y: surface.bounds.midY)
        DispatchQueue.main.async { [weak self] in self?.presentEditMenu(at: p) }
    }
}

// MARK: - Pane Title Bar

/// Minimal title bar sitting atop the terminal. Just a state dot + title — the
/// zoom + pane-menu actions moved to the floating toolbar (the strip is one
/// cell tall in tiled mode, too short for touch targets). Two looks:
///   • Tiled (multi-pane): chrome mirrors the macOS host — a dark-green band
///     with bright-green text when active, dark-gray with muted text otherwise.
///   • Single / focus: blends into the terminal background (no contrast band),
///     so a fullscreen pane reads as one continuous surface.
///
/// Layout: [◉ state] [title……………………………………………] [mode]
final class PaneTitleBar: UIView {
    let titleLabel = UILabel()
    /// Leading semantic state glyph — the SAME symbol language as the macOS
    /// pane chrome and the window sidebar rows, not a bare dot. A dot carries
    /// only a color, which is why it had no way to say "done, unseen".
    private let stateIcon = UIImageView()
    /// Trailing mode glyph. Separate from the state dot on purpose: state is what
    /// the PROGRAM is doing, a mode is something about the pane that changes how
    /// it answers you. Hidden unless a mode is on — "nothing unusual" gets no
    /// marker, the same rule the idle state follows.
    private let modeIcon = UIImageView()

    /// tmux has this pane in copy-mode (entered from outside Bento).
    var inCopyMode: Bool = false {
        didSet {
            guard oldValue != inCopyMode else { return }
            modeIcon.isHidden = !inCopyMode
            updateChrome()
        }
    }

    /// Drives the state glyph, the title-bar band color, and (when active) text
    /// emphasis.
    var paneState: PaneState = .idle {
        didSet { updateStateVisuals(); updateChrome() }
    }

    /// An agent that finished while you were looking elsewhere → the green ✓, a
    /// display state that sits beside `paneState` rather than inside it (the
    /// same split the macOS chrome and the sidebar rows make).
    var agentFinishedUnseen: Bool = false {
        didSet {
            guard oldValue != agentFinishedUnseen else { return }
            updateStateVisuals(); updateChrome()
        }
    }

    /// Active state drives the green chrome (tiled) / text emphasis (blend).
    var isActivePane: Bool = false {
        didSet { updateChrome() }
    }

    /// Tiled mode → macOS-style green/gray chrome; otherwise blend into the
    /// terminal background (`surfaceColor`).
    var isTiled: Bool = false {
        didSet { if oldValue != isTiled { updateChrome() } }
    }

    /// The terminal's reported background. Drives the fused title band in BOTH
    /// modes — the band is this bg blended toward the state accent, so a bg
    /// report (or theme/appearance change) re-derives the whole band via
    /// `updateChrome`.
    var surfaceColor: UIColor = STTheme.term {
        didSet { updateChrome() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        // In tiled mode the strip is only one character cell tall; clip so the
        // centered dot never spills onto the terminal surface below.
        clipsToBounds = true

        stateIcon.contentMode = .scaleAspectFit
        stateIcon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stateIcon)

        titleLabel.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .secondaryLabel
        titleLabel.text = "shell"
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        modeIcon.image = UIImage(systemName: "doc.on.doc")
        modeIcon.contentMode = .scaleAspectFit
        modeIcon.isHidden = true
        modeIcon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(modeIcon)

        NSLayoutConstraint.activate([
            // A fixed-width slot, so the title never shifts as the state changes.
            stateIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stateIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            stateIcon.widthAnchor.constraint(equalToConstant: 14),
            stateIcon.heightAnchor.constraint(equalToConstant: 14),

            titleLabel.leadingAnchor.constraint(equalTo: stateIcon.trailingAnchor, constant: 7),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: modeIcon.leadingAnchor, constant: -6),

            modeIcon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            modeIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            modeIcon.widthAnchor.constraint(equalToConstant: 12),
            modeIcon.heightAnchor.constraint(equalToConstant: 12),
        ])

        updateStateVisuals()
        updateChrome()
    }

    /// The title band FUSES with the terminal's real background: the bg blended
    /// toward the state accent (working/awaiting/done), or nudged in luminance
    /// for a faint neutral band when idle so the bento grid stays legible. Tiled
    /// mode strengthens the active pane; blend (focus / single) mode lets the
    /// band dissolve into the bg. Ink keys off the bg's luminance so it stays
    /// legible even when a TUI repaints the bg at runtime.
    private func updateChrome() {
        // Done-unseen wins the band, otherwise the per-state color (nil for
        // idle → faint neutral band) — the macOS chrome's precedence.
        let accent: UIColor? = agentFinishedUnseen
            ? PaneState.uiColor(hex: PaneState.doneUnseenHex)
            : paneState.chromeAccentUIColor
        if isTiled {
            backgroundColor = STTheme.fusedBand(bg: surfaceColor, accent: accent, active: isActivePane)
        } else {
            backgroundColor = surfaceColor   // fullscreen pane: band = terminal bg
        }
        titleLabel.textColor = STTheme.fusedInk(bg: surfaceColor, active: isActivePane)
        // Same ink as the title: a mode is information, not an alarm, and it must
        // never be mistaken for one of the state colors.
        modeIcon.tintColor = titleLabel.textColor
    }

    /// Re-derive the band/ink for the current appearance (the band colors are
    /// resolved at compute time, not trait-reactive UIColors).
    func recolor() { updateChrome() }

    /// The leading glyph for the current state — identical mapping to the macOS
    /// title bar and the window sidebar rows: working = play, awaiting =
    /// question, done-unseen = check, idle = a quiet hollow gray ring (same
    /// `.circle` family, empty = at rest).
    private func updateStateVisuals() {
        let (symbol, hex): (String, UInt32) = {
            if agentFinishedUnseen { return ("checkmark.circle.fill", PaneState.doneUnseenHex) }
            switch paneState {
            case .working:       return ("play.circle.fill", PaneState.workingHex)
            case .awaitingInput: return ("questionmark.circle.fill", PaneState.awaitingHex)
            case .idle:          return ("circle", PaneState.idleHex)
            }
        }()
        let color = PaneState.uiColor(hex: hex)
        stateIcon.image = UIImage(systemName: symbol, withConfiguration:
            UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        stateIcon.tintColor = color

        // A pending question / running program gets a soft glow so it reads from
        // across the room; a settled pane doesn't.
        switch paneState {
        case .awaitingInput:
            stateIcon.layer.shadowColor = color.cgColor
            stateIcon.layer.shadowRadius = 3
            stateIcon.layer.shadowOpacity = 0.8
            stateIcon.layer.shadowOffset = .zero
        case .working:
            stateIcon.layer.shadowColor = color.cgColor
            stateIcon.layer.shadowRadius = 2.5
            stateIcon.layer.shadowOpacity = 0.6
            stateIcon.layer.shadowOffset = .zero
        case .idle:
            stateIcon.layer.shadowOpacity = 0
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// An iOS-style text-selection handle: a thin stem one cell tall with a round
/// knob at one end — top for the selection start, bottom for the end (PRD §3.8).
/// The view is padded by `inset` on every side so the small knob is easy to grab.
final class SelectionHandle: UIView {
    let isStart: Bool
    var cellHeight: CGFloat = 16 { didSet { setNeedsDisplay() } }
    private static let inset: CGFloat = 18
    private let knobRadius: CGFloat = 5.5
    private let stemWidth: CGFloat = 2

    init(isStart: Bool) {
        self.isStart = isStart
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Place the view so its stem starts at `stemTop` (superview coords) and
    /// runs down one cell.
    func positionStemTop(_ stemTop: CGPoint) {
        let i = Self.inset
        frame = CGRect(x: stemTop.x - i, y: stemTop.y - i,
                       width: i * 2, height: cellHeight + i * 2)
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let accent = STTheme.isLight ? STTheme.ChromeLight.accent : STTheme.ChromeDark.accent
        ctx.setFillColor(accent.cgColor)
        let cx = bounds.midX
        let top = Self.inset
        ctx.fill(CGRect(x: cx - stemWidth / 2, y: top, width: stemWidth, height: cellHeight))
        let knobY = isStart ? top : top + cellHeight
        ctx.fillEllipse(in: CGRect(x: cx - knobRadius, y: knobY - knobRadius,
                                   width: knobRadius * 2, height: knobRadius * 2))
    }
}

/// Weak-target trampoline for the scroll-momentum CADisplayLink — the link
/// retains its target, so pointing it straight at the VC would keep a dismissed
/// pane (and its fling) alive. Same pattern as the surface's render-link proxy.
/// @MainActor is sound here: the link is scheduled on the main run loop, and
/// the @objc thunk asserts the actor on entry.
@MainActor
private final class MomentumLinkProxy {
    private weak var vc: TerminalContainerVC?
    init(_ vc: TerminalContainerVC) { self.vc = vc }
    @objc func tick(_ link: CADisplayLink) {
        // If the VC died without teardown() mid-glide, self-invalidate so the
        // link doesn't fire into a dead target forever.
        guard let vc else { link.invalidate(); return }
        vc.momentumTick(link)
    }
}
