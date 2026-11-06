import BentoFilePreviewKit
import BentoFoundationKit
#if canImport(UIKit)
import UIKit
import GhosttyKit

/// A libghostty-backed terminal surface for iOS. The view is a CAMetalLayer that
/// libghostty renders into directly; we feed it remote bytes via
/// `ghostty_surface_process_output` and it emits encoded keystrokes back through
/// the runtime's `write_to_host` callback (the "external backend" path — no local
/// PTY, which iOS forbids). Host code (TerminalContainerVC) treats this purely
/// through the `TerminalSurface` protocol.
// Explicit @MainActor (not inherited from UIView): cross-module, inference
// through UIKit's @preconcurrency annotation degrades to task-isolated, and
// Swift 6 callers then reject sending the surface through async hops.
@MainActor
public final class GhosttyTerminalSurface: UIView, TerminalSurface, UITextInput {

    // MARK: TerminalSurface callbacks
    public var onInput: ((Data) -> Void)?
    public var onSizeChanged: ((TerminalSurfaceSize) -> Void)?
    /// Never fired by the current implementation — titles flow via tmux.
    public var onTitleChanged: ((String) -> Void)?
    public internal(set) var currentSize: TerminalSurfaceSize?

    /// Per-pane mouse-reporting mode, learned from tmux's `mouse_any_flag` /
    /// `mouse_sgr_flag` (in control mode the engine never sees the TUI's
    /// mouse-enable, so the host pushes it from list-panes). When `any` is on, a
    /// touch-scroll is FORWARDED to the program as wheel events instead of
    /// scrolling the surface's own scrollback — so an alt-screen TUI (Claude
    /// Code, less, htop…) scrolls its own content. Mirrors the macOS surface.
    public struct MouseReporting: Equatable {
        public var any: Bool
        public var sgr: Bool
        public init(any: Bool = false, sgr: Bool = false) { self.any = any; self.sgr = sgr }
    }
    public var mouseReporting = MouseReporting()
    /// Sub-cell scroll remainder, so slow drags still accumulate to whole rows.
    var wheelRows = ScrollRowAccumulator()

    /// tmux has this pane in a mode (copy-mode), entered from outside Bento —
    /// another client, a script, or the user's own binding. Bento does not
    /// implement copy-mode; this flag exists so the pane isn't a rectangle that
    /// silently refuses to scroll. See the macOS surface for the same pair.
    public var tmuxInMode = false

    /// Scroll travel while tmux owns the viewport, in rows (positive = toward
    /// older output). The host turns this into `send-keys -X scroll-up`.
    public var onCopyModeScroll: ((Int) -> Void)?
    var copyModeRows = ScrollRowAccumulator()

    /// The Metal renderer's health, reported by the engine.
    ///
    /// Forwarded to the HOST rather than drawn here: on iOS ghostty renders into
    /// a sublayer of this view's layer, and `synchronizeGhosttyLayerGeometry`
    /// stretches every sublayer to the full bounds — so any chrome added as a
    /// subview would be resized over the whole terminal. The pane's VC owns its
    /// chrome anyway.
    public var onRendererHealthChanged: ((Bool) -> Void)?

    nonisolated(unsafe) var surface: ghostty_surface_t?
    private(set) var theme: TerminalTheme
    nonisolated(unsafe) var renderLink: CADisplayLink?
    var pendingBytes: [Data] = []
    /// Dirty flag: the display link only draws when something changed, instead
    /// of an unconditional up-to-120Hz redraw of every pane (GPU/battery burn).
    /// Set true by any dirty source (ghostty's RENDER action, output, scroll,
    /// input, focus) and consumed in `renderTick`. Starts true so the first
    /// frames draw (which also poll ghostty's grid size — see
    /// `reportSizeIfNeeded`). All iOS surface entry points run on the main
    /// thread, so no lock is needed (unlike macOS).
    var needsDraw = true
    /// Timestamp of the last draw. Drives a low idle redraw rate so the cursor
    /// keeps blinking (the prebuilt libghostty drives blink internally and never
    /// emits a RENDER action) and any un-marked local change still recovers.
    var lastDrawNs: UInt64 = 0
    static let idleRedrawIntervalNs: UInt64 = 250_000_000   // 250ms ≈ 4fps
    /// Once ghostty's cell grid first reports a non-zero size, stop polling it
    /// from every render frame (see `renderTick`); later size changes arrive via
    /// `updateSurfaceSize`, which calls `reportSizeIfNeeded` directly. Mirrors
    /// the macOS surface's grid-settle gate.
    var gridSettled = false
    /// Set once teardown() runs; blocks any later surface (re)creation so a
    /// stray layout/window callback can't resurrect a freed surface.
    private(set) var isTornDown = false

    // State for the concerns split into GhosttyTerminalSurface+*.swift (stored
    // properties cannot live in extensions). Original order kept.
    /// True between `didEnterBackground` and `willEnterForeground`.
    ///
    /// iOS refuses GPU submissions from a background app, and this app keeps
    /// itself alive there for ~30 s to hold the SSH connection
    /// (`SessionManager.beginBackgroundTask`) — so without this the display link
    /// goes on ticking with no permission to draw. `ghostty_surface_draw` blocks
    /// the main thread on `waitUntilCompleted`, so the rejected command buffer
    /// both wedges the whole app and makes ghostty report its renderer
    /// unhealthy, which surfaces as a "Renderer stopped — this pane won't
    /// update" banner that never clears because the renderer never recovers.
    ///
    /// The macOS host has carried the equivalent guard since it hit the same
    /// stall on occluded and miniaturized windows (`updateRenderActive` there);
    /// this is the iOS half of it.
    var isBackgrounded = false
    nonisolated(unsafe) var lifecycleObservers: [NSObjectProtocol] = []

    /// The engine reported an actually-rendered color (initial theme
    /// resolution, config reload, or runtime OSC 10/11/12). Mirrors the macOS
    /// surface so the shared runtime can dispatch on either platform; iOS has
    /// no window chrome to recolor yet, but the value is kept for hosts.
    public internal(set) var reportedBackgroundColor: UIColor?

    /// OSC 7 working-directory report (shell integration on the remote side).
    /// Fallback cwd for path-preview when the pane isn't a tmux pane.
    public internal(set) var reportedPwd: String?

    /// Viewport-top row from the last SCROLLBAR action (visual-row space).
    var lastScrollTop: Int?
    let pathHitEngine = SurfacePathHitEngine()

    /// The engine asked the host to open its find UI (its own search keybind
    /// fired — hardware ⌘F on iPad). `needle` is a prefill, usually the selection.
    public var onSearchStartRequested: ((String?) -> Void)?
    /// The engine ended the search; the host should close its find UI.
    public var onSearchEnded: (() -> Void)?
    /// Match counts, nil = the engine's -1 ("none").
    public var onSearchCounts: ((_ total: Int?, _ selected: Int?) -> Void)?

    var searchTotal: Int?
    var searchSelected: Int?

    /// The engine's OSC 8 answer for the cell we last reported the pointer over.
    var engineLinkURL: String?

    /// Which machine this pane's `localhost` means, installed by the host that
    /// owns the pane. Unset (or nil) reads as this device — the same answer a
    /// local pane gives, so an unwired surface degrades to the old behaviour
    /// instead of guessing at a host.
    public var linkOriginProvider: (@MainActor () -> LinkOrigin?)?

    var _inputAccessoryView: UIView?

    // `.default` exposes the 🌐 globe key so the user can switch to a CJK keyboard.
    // Safe now that the view implements full UITextInput with marked-text support
    // (below): Pinyin/CJK candidates render inline via ghostty_surface_preedit and
    // commit through insertText. (Previously locked to `.asciiCapable` because
    // UIKeyInput alone can't receive marked text, so a CJK keyboard was dead.)
    public var keyboardType: UIKeyboardType = .default
    public var autocorrectionType: UITextAutocorrectionType = .no
    public var autocapitalizationType: UITextAutocapitalizationType = .none
    public var spellCheckingType: UITextSpellCheckingType = .no
    public var smartQuotesType: UITextSmartQuotesType = .no
    public var smartDashesType: UITextSmartDashesType = .no

    var markedTextValue = ""
    public var markedTextStyle: [NSAttributedString.Key: Any]?
    public weak var inputDelegate: UITextInputDelegate?
    lazy var _tokenizer: UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)

    public override class var layerClass: AnyClass { CAMetalLayer.self }

    public init(theme: TerminalTheme) {
        self.theme = theme
        // Non-zero initial frame so the Metal layer can size itself before layout.
        super.init(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        isOpaque = true
        backgroundColor = UIColor(hex: theme.background)
        isMultipleTouchEnabled = true
        contentScaleFactor = traitCollection.displayScale > 0 ? traitCollection.displayScale : UIScreen.main.scale
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        renderLink?.invalidate()
        renderLink = nil
        if let surface { ghostty_surface_free(surface) }
        surface = nil
    }

    /// Stop rendering and free the ghostty surface NOW, before the view/layer is
    /// torn down. The CADisplayLink keeps ticking (drawing whenever dirty or the
    /// idle backstop is due); if the host view is removed (e.g. the session is
    /// dismissed) while the link is still live, the next draw commits a
    /// Metal/CoreAnimation transaction against the half-freed layer and aborts
    /// the process
    /// (renderer.Metal.initTarget → MTLTextureDescriptor validation). Mirrors the
    /// macOS host's teardown(). Idempotent.
    public func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        lifecycleObservers.removeAll()
        renderLink?.invalidate()
        renderLink = nil
        if let surface {
            // The runtime answers clipboard reads (OSC 52) on whichever surface
            // last pasted — don't leave it pointing at a surface we're about to
            // free (mirrors the macOS teardown).
            if GhosttyRuntime.shared.pasteSurface == surface { GhosttyRuntime.shared.pasteSurface = nil }
            detachGhosttySublayers()
            ghostty_surface_free(surface)
        }
        surface = nil
    }

    /// Take ghostty's Metal sublayer(s) out of this view's layer tree.
    ///
    /// ghostty attaches its render layer as a SUBLAYER of ours (see
    /// `synchronizeGhosttyLayerGeometry`) and `ghostty_surface_free` releases
    /// the renderer that owns it. Nothing used to remove it from the tree, so
    /// a layer that died with its surface stayed a child of a live layer, and
    /// the next CoreAnimation commit walked into it and read a freed object:
    /// `CA::Context::commit_transaction → object_getClass`, EXC_BAD_ACCESS at
    /// 0x2500000000 — twice within ten seconds, same stack, same fault
    /// address, on 2026-08-02.
    ///
    /// Recreation carried a quieter second version of the same bug: every new
    /// surface added ANOTHER sublayer, so a pane whose font size changed N
    /// times accumulated N dead layers, each stretched over the full bounds by
    /// `synchronizeGhosttyLayerGeometry`.
    ///
    /// Removing ALL sublayers is correct rather than lazy: this view
    /// deliberately owns no chrome of its own (the pane's view controller does
    /// — see `onRendererHealthChanged`), so every sublayer here is ghostty's.
    ///
    /// Must run BEFORE the free, while the layer is still a valid object.
    private func detachGhosttySublayers() {
        guard let sublayers = layer.sublayers, !sublayers.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in sublayers { sublayer.removeFromSuperlayer() }
        CATransaction.commit()
    }

    /// Output that arrived with nowhere to put it — no surface yet, or the app
    /// in the background where feeding would block (see `feedOnMainActor`).
    ///
    /// Bounded: a session left in a pocket while a build scrolls by can emit
    /// without limit, and holding all of it would trade a watchdog kill for a
    /// memory kill. Terminal output is overwhelmingly repaint, so the newest
    /// bytes are the ones worth keeping.
    private static let maxPendingBytes = 8 << 20
    private var pendingByteCount = 0

    private func buffer(_ data: Data) {
        pendingBytes.append(data)
        pendingByteCount += data.count
        var dropped = 0
        while pendingByteCount > Self.maxPendingBytes, !pendingBytes.isEmpty {
            pendingByteCount -= pendingBytes.removeFirst().count
            dropped += 1
        }
        if dropped > 0 {
            dlog("surface: dropped \(dropped) buffered chunk(s) — over "
                + "\(Self.maxPendingBytes / (1 << 20))MB queued while unable to feed")
        }
    }

    /// How much backlog may be pushed into ghostty in a single main-thread turn.
    ///
    /// `ghostty_surface_process_output` is a SYNCHRONOUS push into a mailbox
    /// that only `ghostty_surface_draw` drains — and that draw runs on this
    /// same main thread. Handing the engine a whole backlog in one turn is
    /// therefore a self-deadlock waiting to happen: once the mailbox is full
    /// the push parks in a futex wait for a drain that cannot run until the
    /// push returns. That is the hang, five times across 2026-08-01/02, always
    /// on reopening from background — where up to 8 MB of tmux output banked
    /// during the SSH keep-alive window met a display link that had not
    /// started ticking yet. iOS ended each one with a scene-update watchdog
    /// kill (0x8BADF00D at 0% CPU: blocked, not spinning).
    ///
    /// One slice per frame at 60 Hz drains the 8 MB ceiling in well under a
    /// second, which is faster than the replay can be read anyway.
    private static let drainBudgetPerTurn = 256 << 10

    /// Bytes handed to the engine since the last draw.
    ///
    /// The budget has to be enforced against the DRAW, not against any one
    /// caller: the mailbox empties only in `ghostty_surface_draw`, so what
    /// matters is how much accumulates between two draws regardless of who
    /// pushed it. `TerminalContainerVC.feedProgressively` is the reason this
    /// is a counter rather than a per-call check — it slices a history replay
    /// into 32 KB pieces and drains them one per runloop turn, and the main
    /// queue turns over many times per frame, so the whole ~512 KB replay can
    /// still land between two display-link ticks.
    var bytesPushedSinceDraw = 0

    /// Push at most the remaining per-draw budget of backlog, oldest first.
    ///
    /// Only `renderTick` calls this, and only right after a draw — that
    /// ordering IS the fix: every push is preceded by the drain that makes
    /// room for it.
    func drainPendingBytes() {
        guard surface != nil, !isBackgrounded, !isTornDown, !pendingBytes.isEmpty else { return }
        var budget = Self.drainBudgetPerTurn - bytesPushedSinceDraw
        guard budget > 0 else { needsDraw = true; return }
        while budget > 0, let chunk = pendingBytes.first {
            if chunk.count > budget {
                // A single chunk can exceed a whole turn's budget on its own
                // (a reattach replays scrollback as one blob). Split it and
                // leave the tail at the head of the queue: the point is to
                // bound what one push hands the mailbox, not to count chunks.
                pendingBytes[0] = Data(chunk.dropFirst(budget))
                pendingByteCount -= budget
                pushToEngine(Data(chunk.prefix(budget)))
                budget = 0
            } else {
                pendingBytes.removeFirst()
                pendingByteCount -= chunk.count
                budget -= chunk.count
                pushToEngine(chunk)
            }
        }
        // Still behind — guarantee another tick, since the dirty gate is what
        // decides whether this method runs again.
        if !pendingBytes.isEmpty { needsDraw = true }
    }

    // MARK: - TerminalSurface

    /// `nonisolated` to satisfy the protocol (macOS needs output off the main
    /// thread — see TerminalSurface.feed). This surface still parses ON the main
    /// actor, unlike the macOS one, so callers arriving from another thread are
    /// hopped rather than let in: `surface`/`pendingBytes` here are plain
    /// main-actor state with no lock behind them.
    public nonisolated func feed(_ data: Data) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { feedOnMainActor(data) }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.feedOnMainActor(data) } }
        }
    }

    private func feedOnMainActor(_ data: Data) {
        guard !data.isEmpty else { return }
        guard let surface else { buffer(data); return }
        // `ghostty_surface_process_output` is a SYNCHRONOUS push into ghostty's
        // mailbox, and the draw loop is what drains it. Backgrounded there is no
        // draw loop — but the SSH connection is deliberately kept alive, so tmux
        // `%output` keeps arriving. The mailbox fills, the push blocks the main
        // thread, and iOS ends it with a scene-update watchdog kill
        // (0x8BADF00D, "exhausted real (wall clock) time allowance of 10.00
        // seconds", at 0% CPU — blocked, not spinning). Buffer instead and flush
        // when the draw loop is running again.
        guard !isBackgrounded else { buffer(data); return }
        // Two reasons to queue instead of pushing:
        //   * a backlog is already draining — pushing past it would put newer
        //     bytes ahead of older ones and repaint from out-of-order output;
        //   * this frame's push budget is spent, and more would risk the
        //     mailbox-full block that no draw can rescue (`drainBudgetPerTurn`).
        guard pendingBytes.isEmpty,
              bytesPushedSinceDraw + data.count <= Self.drainBudgetPerTurn else {
            buffer(data)
            setNeedsDraw()   // guarantee a tick that will drain what was just queued
            return
        }
        pushToEngine(data)
    }

    /// The one place bytes actually enter ghostty.
    ///
    /// Callers own the preconditions: a live surface, a foreground app, and
    /// FIFO order with respect to `pendingBytes`. Kept separate from
    /// `feedOnMainActor` precisely so `drainPendingBytes` can push the queue's
    /// own chunks without that method's "queue behind the backlog" guard
    /// sending them back into the queue they just came from.
    private func pushToEngine(_ data: Data) {
        guard let surface else { return }
        bytesPushedSinceDraw += data.count
        // The census has to be taken BEFORE the call: if this push is the one
        // that parks, nothing on this thread runs again, and the background
        // watchdog can only report what was already written down.
        MailboxWedgeProbe.beginPush(data, surfaceTag: ObjectIdentifier(self).hashValue & 0xffff)
        data.withUnsafeBytes { raw in
            guard let ptr = raw.bindMemory(to: CChar.self).baseAddress else { return }
            ghostty_surface_process_output(surface, ptr, UInt(data.count))
        }
        MailboxWedgeProbe.endPush()
        ghostty_surface_refresh(surface)
        setNeedsDraw()
    }

    /// ghostty's EFFECTIVE terminal background — the color ghostty actually
    /// renders, including its built-in default when the active theme writes no
    /// explicit `background` (the dark "System" theme). Chrome beside the terminal
    /// (the reserved toolbar band, the blend title bar) paints itself with this so
    /// it fuses with the terminal. nil → caller falls back to the theme color.
    public var effectiveBackgroundColor: UIColor? {
        guard let rgb = GhosttyRuntime.shared.effectiveBackgroundRGB() else { return nil }
        return UIColor(red: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255,
                       blue: CGFloat(rgb.b) / 255, alpha: 1)
    }

    public func applyTheme(_ theme: TerminalTheme) {
        self.theme = theme
        backgroundColor = UIColor(hex: theme.background)
        // Light/dark can flip with the font size untouched, so this sits outside
        // the recreate branch.
        syncColorScheme()
        // Font size / family are applied at surface creation via config. A live
        // change recreates the surface so the new metrics take effect.
        if surface != nil, abs(theme.fontSize - Double(lastAppliedFontSize)) > 0.01 {
            recreateSurface()
        }
        lastAppliedFontSize = Float(theme.fontSize)
    }

    /// Report the terminal's light/dark to the engine so programs running inside
    /// it can query it (OSC 2031 / DSR ?996). Sourced from the ACTIVE PALETTE,
    /// not the app chrome's appearance — what matters to vim/delta/bat is the
    /// background they are drawing onto.
    func syncColorScheme() {
        guard let surface else { return }
        ghostty_surface_set_color_scheme(
            surface, theme.isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    private var lastAppliedFontSize: Float = 0

    private func recreateSurface() {
        // Same teardown discipline as teardown()/the macOS host: stop the
        // render loop BEFORE freeing, and let the freed surface's last frame
        // commit before a new surface binds the same CAMetalLayer. Doing the
        // free/create pair synchronously under a live display link is the
        // renderer.Metal initTarget abort pattern — on device it crashed on
        // every font-size change; the simulator's Metal layer just happened
        // to tolerate it. Output arriving in the gap lands in pendingBytes
        // (feed() buffers while surface is nil) and flushes on create.
        renderLink?.invalidate()
        renderLink = nil
        // The layer the old surface rendered into must leave the tree before
        // the surface that owns it is freed, or the next CoreAnimation commit
        // reads a dead object — and the replacement surface would otherwise
        // stack a second layer on top of the corpse. See
        // `detachGhosttySublayers`.
        detachGhosttySublayers()
        if let surface { ghostty_surface_free(surface) }
        surface = nil
        currentSize = nil
        // New surface → re-poll the grid from the draw loop until it settles
        // (mirrors the macOS applyTheme path).
        gridSettled = false
        needsDraw = true
        pathHitEngine.invalidate()
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isTornDown else { return }
            self.createSurfaceIfNeeded()   // draws + restarts the render link
        }
    }

    public func setFocus(_ focused: Bool) {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, focused)
        setNeedsDraw()
    }

    /// Called by GhosttyRuntime when the engine has bytes for the host (SSH).
    public func handleHostWrite(_ data: Data) {
        onInput?(data)
    }

    /// Mark the surface dirty so the next display-link tick draws it. Called by
    /// GhosttyRuntime on GHOSTTY_ACTION_RENDER and by every local mutation in
    /// this file (output, scroll, input, selection, focus). Main-thread only —
    /// all iOS surface entry points are main-thread, so no lock (unlike macOS).
    public func setNeedsDraw() { needsDraw = true }

}

extension GhosttyTerminalSurface: @preconcurrency GhosttySurfaceUserdata {}
#endif
