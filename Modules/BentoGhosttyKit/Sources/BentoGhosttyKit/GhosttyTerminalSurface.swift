import BentoFilePreviewKit
import BentoFoundationKit
#if canImport(UIKit)
import UIKit
import Metal
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
    public private(set) var currentSize: TerminalSurfaceSize?

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
    private var scrollWheelAccum: CGFloat = 0

    /// tmux has this pane in a mode (copy-mode), entered from outside Bento —
    /// another client, a script, or the user's own binding. Bento does not
    /// implement copy-mode; this flag exists so the pane isn't a rectangle that
    /// silently refuses to scroll. See the macOS surface for the same pair.
    public var tmuxInMode = false

    /// Scroll travel while tmux owns the viewport, in rows (positive = toward
    /// older output). The host turns this into `send-keys -X scroll-up`.
    public var onCopyModeScroll: ((Int) -> Void)?
    private var copyModeScrollAccum: CGFloat = 0

    /// The Metal renderer's health, reported by the engine.
    ///
    /// Forwarded to the HOST rather than drawn here: on iOS ghostty renders into
    /// a sublayer of this view's layer, and `synchronizeGhosttyLayerGeometry`
    /// stretches every sublayer to the full bounds — so any chrome added as a
    /// subview would be resized over the whole terminal. The pane's VC owns its
    /// chrome anyway.
    public var onRendererHealthChanged: ((Bool) -> Void)?

    nonisolated(unsafe) private var surface: ghostty_surface_t?
    private var theme: TerminalTheme
    nonisolated(unsafe) private var renderLink: CADisplayLink?
    private var pendingBytes: [Data] = []
    /// Dirty flag: the display link only draws when something changed, instead
    /// of an unconditional up-to-120Hz redraw of every pane (GPU/battery burn).
    /// Set true by any dirty source (ghostty's RENDER action, output, scroll,
    /// input, focus) and consumed in `renderTick`. Starts true so the first
    /// frames draw (which also poll ghostty's grid size — see
    /// `reportSizeIfNeeded`). All iOS surface entry points run on the main
    /// thread, so no lock is needed (unlike macOS).
    private var needsDraw = true
    /// Timestamp of the last draw. Drives a low idle redraw rate so the cursor
    /// keeps blinking (the prebuilt libghostty drives blink internally and never
    /// emits a RENDER action) and any un-marked local change still recovers.
    private var lastDrawNs: UInt64 = 0
    private static let idleRedrawIntervalNs: UInt64 = 250_000_000   // 250ms ≈ 4fps
    /// Once ghostty's cell grid first reports a non-zero size, stop polling it
    /// from every render frame (see `renderTick`); later size changes arrive via
    /// `updateSurfaceSize`, which calls `reportSizeIfNeeded` directly. Mirrors
    /// the macOS surface's grid-settle gate.
    private var gridSettled = false
    /// Set once teardown() runs; blocks any later surface (re)creation so a
    /// stray layout/window callback can't resurrect a freed surface.
    private var isTornDown = false

    public override class var layerClass: AnyClass { CAMetalLayer.self }

    public init(theme: TerminalTheme) {
        self.theme = theme
        // Non-zero initial frame so the Metal layer can size itself before layout.
        super.init(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        isOpaque = true
        backgroundColor = UIColor(rgb: theme.background)
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
        if let surface { ghostty_surface_free(surface) }
        surface = nil
    }

    // MARK: - Lifecycle / surface creation

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            observeAppLifecycleIfNeeded()
            createSurfaceIfNeeded()
            synchronizeGhosttyLayerGeometry()
            updateSurfaceSize()
            updateRenderActive()
        } else {
            // Left the hierarchy — stop drawing so we never render into a layer
            // that's being torn down (Metal abort). The surface is freed in
            // teardown()/deinit.
            stopRenderLink()
        }
    }

    // MARK: - Render gating

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
    private var isBackgrounded = false
    nonisolated(unsafe) private var lifecycleObservers: [NSObjectProtocol] = []

    private func observeAppLifecycleIfNeeded() {
        guard lifecycleObservers.isEmpty else { return }
        // A pane can be built during the background grace window (a reconnect
        // that lands while the phone is in a pocket), and it would never see a
        // `didEnterBackground` for the state it was already in.
        isBackgrounded = UIApplication.shared.applicationState == .background
        let nc = NotificationCenter.default
        for (name, backgrounded) in [
            (UIApplication.didEnterBackgroundNotification, true),
            (UIApplication.willEnterForegroundNotification, false),
        ] {
            lifecycleObservers.append(
                nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    guard let self else { return }
                    self.isBackgrounded = backgrounded
                    self.updateRenderActive()
                })
        }
    }

    /// Run the render loop only while there is a window and the app is in the
    /// foreground, and tell ghostty when it is occluded so it skips its own
    /// rendering too.
    private func updateRenderActive() {
        guard !isTornDown else { return }
        let active = window != nil && !isBackgrounded
        if let surface { ghostty_surface_set_occlusion(surface, active) }
        if active {
            // Nothing was drawn while we were away and the engine has no reason
            // to think the screen is stale — ask for one frame on return.
            needsDraw = true
            startRenderLink()
            flushPendingBytes()
        } else {
            stopRenderLink()
        }
    }

    private func stopRenderLink() {
        renderLink?.invalidate()
        renderLink = nil
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

    private func flushPendingBytes() {
        guard !pendingBytes.isEmpty else { return }
        let queued = pendingBytes
        pendingBytes.removeAll()
        pendingByteCount = 0
        for chunk in queued { feedOnMainActor(chunk) }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        createSurfaceIfNeeded()
        synchronizeGhosttyLayerGeometry()
        updateSurfaceSize()
    }

    /// ghostty attaches its Metal render layer as a SUBLAYER of this view's
    /// layer on iOS. We must size that sublayer to our bounds and set the
    /// content scale, or it renders into a zero/unscaled drawable and nothing
    /// is visible. (macOS doesn't need this — ghostty owns the whole layer there.)
    private func synchronizeGhosttyLayerGeometry() {
        let hostBounds = layer.bounds
        let scale = renderScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contentsScale = scale
        for sublayer in layer.sublayers ?? [] {
            sublayer.frame = hostBounds
            sublayer.contentsScale = scale
            sublayer.setNeedsDisplay()
        }
        CATransaction.commit()
    }

    private func createSurfaceIfNeeded() {
        guard !isTornDown,
              surface == nil,
              bounds.width > 0, bounds.height > 0,
              let app = GhosttyRuntime.shared.app else { return }

        var cfg = ghostty_surface_config_new()
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.platform_tag = GHOSTTY_PLATFORM_IOS
        cfg.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(
            uiview: Unmanaged.passUnretained(self).toOpaque()
        ))
        cfg.scale_factor = Double(renderScale)
        cfg.font_size = Float(theme.fontSize)
        cfg.wait_after_command = false

        guard let created = ghostty_surface_new(app, &cfg) else { return }
        surface = created
        dlog("[surface] created font=\(cfg.font_size) scale=\(cfg.scale_factor) bounds=\(bounds.size)")

        synchronizeGhosttyLayerGeometry()
        updateSurfaceSize()
        ghostty_surface_set_focus(created, true)
        syncColorScheme()
        ghostty_surface_refresh(created)
        ghostty_surface_draw(created)
        updateRenderActive()

        flushPendingBytes()
    }

    private var currentScale: CGFloat {
        let s = window?.screen.scale ?? traitCollection.displayScale
        return s > 0 ? s : UIScreen.main.scale
    }

    /// The scale ghostty actually renders at. Normally the device scale, but a
    /// huge canvas (a Pinned session's full tmux page can be thousands of
    /// points wide) times the device scale can exceed Metal's max texture side
    /// — the drawable is derived from layer bounds × contentsScale, so the
    /// set_size clamp alone can't prevent the abort. Degrade DPI just enough
    /// that bounds × scale fits. Every point↔pixel conversion must use THIS
    /// scale so input, selection, and scroll stay aligned with the drawable.
    private var renderScale: CGFloat {
        let device = currentScale
        let maxSide = max(bounds.width, bounds.height)
        guard maxSide > 0 else { return device }
        return min(device, Self.maxDrawableDimension / maxSide)
    }

    /// Metal's maximum 2D texture dimension on THIS device. Exceeding it aborts
    /// in the Metal validation layer, so the render target must never be larger.
    /// Not a constant: the simulator's MTLSimDevice caps 2D textures at 8192
    /// regardless of the host GPU (observed abort: "width (8712) greater than
    /// the maximum allowed size of 8192"), and only Apple3+ hardware raises the
    /// limit to 16384.
    private static let maxDrawableDimension: CGFloat = {
        #if targetEnvironment(simulator)
        return 8192
        #else
        guard let device = MTLCreateSystemDefaultDevice() else { return 8192 }
        return device.supportsFamily(.apple3) ? 16384 : 8192
        #endif
    }()

    private func updateSurfaceSize() {
        guard let surface, bounds.width > 0, bounds.height > 0 else { return }
        let scale = renderScale
        // Clamp the drawable to Metal's limits: a 0 or oversized texture aborts
        // the process in MTLTextureDescriptor validation. (A very large Pinned
        // page can otherwise overflow.)
        let wPx = min(max(bounds.width * scale, 1), Self.maxDrawableDimension)
        let hPx = min(max(bounds.height * scale, 1), Self.maxDrawableDimension)
        ghostty_surface_set_content_scale(surface, Double(scale), Double(scale))
        ghostty_surface_set_size(surface, UInt32(wPx), UInt32(hPx))
        ghostty_surface_refresh(surface)
        setNeedsDraw()
        reportSizeIfNeeded()
    }

    private func reportSizeIfNeeded() {
        guard let surface else { return }
        let s = ghostty_surface_size(surface)
        let size = TerminalSurfaceSize(
            columns: Int(s.columns),
            rows: Int(s.rows),
            cellWidthPx: Int(s.cell_width_px),
            cellHeightPx: Int(s.cell_height_px)
        )
        guard size.columns > 0, size.rows > 0 else {
            // Grid not computed yet (ghostty needs a few frames after creation).
            // Keep requesting draws until it settles, so onSizeChanged fires and
            // the pty/tmux resize starts — otherwise the dirty gate would stop
            // drawing first. (Mirrors the macOS surface.)
            setNeedsDraw()
            return
        }
        // Grid has settled — stop the per-frame size poll from renderTick.
        gridSettled = true
        guard size != currentSize else { return }
        currentSize = size
        onSizeChanged?(size)
    }

    private func startRenderLink() {
        guard renderLink == nil, surface != nil, window != nil,
              !isBackgrounded, !isTornDown else { return }
        // Target a weak proxy, NOT self: CADisplayLink retains its target, so
        // `target: self` would be a retain cycle — the view would never deinit,
        // the link would keep firing draws forever (even off-screen), and a
        // teardown could never happen. The proxy holds the view weakly.
        let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick))
        link.add(to: .main, forMode: .common)
        renderLink = link
    }

    fileprivate func renderTick() {
        // Never draw while detached from a window — the layer may be mid-teardown
        // — nor while backgrounded, where the GPU submission is rejected and the
        // blocking draw wedges the main thread. See `isBackgrounded`.
        guard let surface, window != nil, !isBackgrounded else { return }
        // Draw only when dirty (output/interaction) or when the low idle
        // backstop is due (cursor blink + recovery for any un-marked change) —
        // not unconditionally on every display-link tick. Until the grid
        // settles, draw every tick and poll the size so onSizeChanged fires
        // once it's non-zero (drives tmux/PTY resize). Same dirty-driven
        // pattern the macOS surface ships.
        let now = DispatchTime.now().uptimeNanoseconds
        let idleDue = now &- lastDrawNs >= Self.idleRedrawIntervalNs
        if !needsDraw && !idleDue && gridSettled { return }
        needsDraw = false
        lastDrawNs = now
        ghostty_surface_draw(surface)
        if !gridSettled { reportSizeIfNeeded() }
    }

    // MARK: - TerminalSurface

    /// Scroll the terminal (scrollback / copy-mode) by a touch delta in points.
    /// ghostty applies scroll at the tracked mouse position, so we set that to
    /// the touch point first (a hard-won lesson from the macOS scrollWheel path —
    /// without mouse_pos the engine ignores the scroll). `precise` marks the
    /// delta as high-resolution (touch), matching trackpad behavior.
    public func scroll(deltaX: CGFloat, deltaY: CGFloat, at point: CGPoint) {
        guard let surface else { return }
        // tmux has the pane in copy-mode: IT owns the viewport and repaints from
        // its own scroll position, so moving our scrollback as well means two
        // scroll positions for one screen — the finger drags and nothing appears
        // to happen. Hand the gesture to tmux's copy-mode instead.
        if tmuxInMode {
            let rows = copyModeScrollRows(deltaY)
            if rows != 0 { onCopyModeScroll?(rows) }
            return
        }
        // Mouse-reporting pane (an alt-screen TUI that enabled mouse tracking) →
        // forward the scroll to the program as wheel events instead of moving the
        // surface's local scrollback. Without this, scrolling in Claude Code's
        // fullscreen mode paged the terminal's own history rather than the TUI.
        if mouseReporting.any {
            forwardWheel(deltaY: deltaY, at: point)
            return
        }
        let p = pxPoint(point)
        ghostty_surface_mouse_pos(surface, p.0, p.1, GHOSTTY_MODS_NONE)
        // bit 0 = high-precision; momentum left at NONE (touch drag, not inertial).
        let mods: Int32 = 1
        // ghostty's precise-scroll path interprets the delta in DEVICE PIXELS —
        // it divides by the cell's pixel height to convert to rows. The pan
        // gesture reports finger movement in POINTS, so on a 2×/3× screen the
        // raw delta was 2-3× too small: you had to swipe several row-heights to
        // move one line. Scale points → pixels so scrolling tracks the finger 1:1
        // (renderScale: the drawable's actual pixel density, see its doc).
        let s = Double(renderScale)
        ghostty_surface_mouse_scroll(surface, Double(deltaX) * s, Double(deltaY) * s, mods)
        ghostty_surface_refresh(surface)
        setNeedsDraw()
    }

    /// Forward a touch-scroll to a mouse-reporting program as wheel events. The
    /// pan delta is continuous, so accumulate it and emit one wheel report per
    /// whole cell-row crossed. Finger DOWN (deltaY > 0) reveals older content =
    /// wheel-up (button 64); finger up = wheel-down (65) — matching the local
    /// scrollback direction.
    private func forwardWheel(deltaY: CGFloat, at point: CGPoint) {
        guard let size = currentSize, size.cellHeightPx > 0 else { return }
        let cellH = CGFloat(size.cellHeightPx) / renderScale   // points per row
        scrollWheelAccum += deltaY
        let rows = Int(scrollWheelAccum / cellH)
        guard rows != 0 else { return }
        scrollWheelAccum -= CGFloat(rows) * cellH
        let button = rows > 0 ? 64 : 65
        let (col, row) = cellCoord(point)
        // A wheel notch is a press with no release — there is no "wheel up" event.
        for _ in 0..<min(abs(rows), 8) { sendMouse(button: button, press: true, col: col, row: row) }
    }

    /// Forward a tap to a mouse-reporting program as a left-button press followed
    /// by a release on the tapped cell — the touch equivalent of a click.
    /// Returns false when no program owns the mouse, so the host can fall back to
    /// Bento's own tap handling.
    ///
    /// Without this, `scroll` forwarded the wheel and nothing else did anything:
    /// you could scroll an alt-screen TUI but never press anything in it, which
    /// is most of what Claude Code's fullscreen mode is made of. Press and
    /// release go out together because a touch has no hover — there is no state
    /// in between for the program to observe.
    @discardableResult
    public func forwardTap(at point: CGPoint) -> Bool {
        guard mouseReporting.any else { return false }
        let (col, row) = cellCoord(point)
        sendMouse(button: 0, press: true, col: col, row: row)
        sendMouse(button: 0, press: false, col: col, row: row)
        return true
    }

    /// Accumulate a pan delta into whole rows for copy-mode. Same points-per-row
    /// as the local scrollback path, so a pane in copy-mode scrolls at the speed
    /// every other pane does.
    private func copyModeScrollRows(_ deltaY: CGFloat) -> Int {
        guard let size = currentSize, size.cellHeightPx > 0 else { return 0 }
        let cellH = CGFloat(size.cellHeightPx) / renderScale
        copyModeScrollAccum += deltaY
        let rows = Int(copyModeScrollAccum / cellH)
        guard rows != 0 else { return 0 }
        copyModeScrollAccum -= CGFloat(rows) * cellH
        // Cap the burst: a flick would otherwise hand tmux a very large repeat
        // count in one command, and over a laggy link that lands as a lurch.
        return max(-12, min(12, rows))
    }

    /// 1-based cell (col,row) under a view point, from the engine's cell pixel
    /// size (mirrors the macOS `cellCoord`).
    private func cellCoord(_ point: CGPoint) -> (col: Int, row: Int) {
        guard let size = currentSize, size.cellWidthPx > 0, size.cellHeightPx > 0 else { return (1, 1) }
        let s = renderScale
        let col = max(1, Int(point.x / (CGFloat(size.cellWidthPx) / s)) + 1)
        let row = max(1, Int(point.y / (CGFloat(size.cellHeightPx) / s)) + 1)
        return (col, row)
    }

    /// Encode a mouse event and send it to the program via `onInput`. `button`:
    /// 0 = left, 64 = wheel-up, 65 = wheel-down. No modifier bits — a touch has
    /// no modifier keys to carry. Encoding is shared with the Mac surface
    /// (`MouseReport`) so the two can't drift.
    private func sendMouse(button: Int, press: Bool, col: Int, row: Int) {
        onInput?(MouseReport.encode(button: button, press: press, col: col, row: row,
                                    sgr: mouseReporting.sgr))
    }

    // MARK: - Selection

    /// Mouse position for ghostty in LOGICAL POINTS (not backing pixels).
    /// ghostty applies the surface content scale internally, so multiplying by
    /// `currentScale` double-applies it — selection landed at 2× the row on
    /// Retina (click row n → selected row 2n−1). Matches the macOS surface.
    private func pxPoint(_ point: CGPoint) -> (x: Double, y: Double) {
        return (Double(point.x), Double(point.y))
    }

    // Selection logic is shared with macOS via `GhosttySel` — these are thin
    // forwarders that supply the surface handle and view-point→pixel conversion.

    /// Select the word under `point`. Returns whether a selection now exists.
    @discardableResult
    public func selectWord(at point: CGPoint) -> Bool {
        guard let surface else { return false }
        let ok = GhosttySel.selectWord(surface, px: pxPoint(point))
        setNeedsDraw()
        return ok
    }

    /// Begin a drag selection (anchor) at `point`.
    public func selectionBegin(at point: CGPoint) {
        guard let surface else { return }
        GhosttySel.begin(surface, px: pxPoint(point))
        setNeedsDraw()
    }

    /// Extend the in-progress drag selection to `point`.
    public func selectionExtend(to point: CGPoint) {
        guard let surface else { return }
        GhosttySel.extend(surface, px: pxPoint(point))
        setNeedsDraw()
    }

    /// Finish the drag selection.
    public func selectionEnd() {
        guard let surface else { return }
        GhosttySel.end(surface)
        setNeedsDraw()
    }

    public var hasSelection: Bool {
        guard let surface else { return false }
        return GhosttySel.hasSelection(surface)
    }

    /// Geometry for laying out selection handles: the selection's top-left in
    /// THIS view's points, and the cell size in points. nil if no selection.
    ///
    /// Coordinate-space trap (measured, not assumed): `ghostty_text_s.tl_px`
    /// arrives in the surface's POINT space — the same space the mouse input
    /// takes — despite the `_px` name (verified: selectWord at y=524.5 reported
    /// tl.y=524.0 on a scale-2 device). Dividing it by the content scale put
    /// the iOS selection handles at half the true offset, completely detached
    /// from the highlight ghostty renders. The cell sizes from `currentSize`
    /// ARE device pixels, so only those divide by scale.
    public func selectionGeometry() -> (topLeft: CGPoint, cell: CGSize)? {
        guard let surface, let size = currentSize,
              let tl = GhosttySel.selectionTopLeftPx(surface) else { return nil }
        let s = renderScale
        guard s > 0 else { return nil }
        return (CGPoint(x: tl.x, y: tl.y),
                CGSize(width: CGFloat(size.cellWidthPx) / s,
                       height: CGFloat(size.cellHeightPx) / s))
    }

    /// The currently selected text, or nil.
    public func selectedText() -> String? {
        guard let surface else { return nil }
        return GhosttySel.selectedText(surface)
    }

    /// Select the entire scrollback/screen via the ghostty keybind action.
    @discardableResult
    public func selectAll() -> Bool {
        guard let surface else { return false }
        let ok = GhosttySel.selectAll(surface)
        setNeedsDraw()
        return ok
    }

    /// Clear any selection (a plain left click collapses it).
    public func clearSelection(at point: CGPoint? = nil) {
        guard let surface else { return }
        GhosttySel.clear(surface, px: point.map { pxPoint($0) })
        setNeedsDraw()
    }

    /// Paste the system clipboard into the terminal at the cursor. Mirrors the
    /// macOS surface: route through ghostty's `paste_from_clipboard` action (not
    /// raw `ghostty_surface_text`) so multi-line text gets bracketed-paste
    /// wrapping — otherwise every newline fires Enter and a pasted block runs
    /// line by line (e.g. can't paste a multi-line command into Claude Code).
    /// The action pulls the text back through the runtime's `read_clipboard_cb`,
    /// which completes on the surface registered here.
    public func pasteFromClipboard() {
        guard let surface, let text = TerminalClipboard.read(), !text.isEmpty else { return }
        GhosttyRuntime.shared.pasteSurface = surface
        GhosttySel.bindingAction("paste_from_clipboard", on: surface)
    }

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
        data.withUnsafeBytes { raw in
            guard let ptr = raw.bindMemory(to: CChar.self).baseAddress else { return }
            ghostty_surface_process_output(surface, ptr, UInt(data.count))
        }
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
        backgroundColor = UIColor(rgb: theme.background)
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
    private func syncColorScheme() {
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

    /// Called by GhosttyRuntime on every SCROLLBAR action.
    public func handleScrollbar(total: UInt64, offset: UInt64, len: UInt64) {
        lastScrollTop = Int(offset)
    }

    /// The engine reported an actually-rendered color (initial theme
    /// resolution, config reload, or runtime OSC 10/11/12). Mirrors the macOS
    /// surface so the shared runtime can dispatch on either platform; iOS has
    /// no window chrome to recolor yet, but the value is kept for hosts.
    public private(set) var reportedBackgroundColor: UIColor?

    public func handleColorChange(kind: ghostty_action_color_kind_e, red: UInt8, green: UInt8, blue: UInt8) {
        guard kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND else { return }
        // Trace every engine bg report (initial resolution / config reload /
        // OSC 11) — the chrome's fusion depends on it landing; a missing line
        // here pins a persistent dark-mode seam on the report path.
        dlog("[color] engine reported bg #\(String(format: "%02X%02X%02X", red, green, blue))")
        reportedBackgroundColor = UIColor(
            red: CGFloat(red) / 255, green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255, alpha: 1)
        NotificationCenter.default.post(name: .ghosttySurfaceBackgroundChanged, object: self)
    }

    // MARK: - Path preview hit-testing

    /// OSC 7 working-directory report (shell integration on the remote side).
    /// Fallback cwd for path-preview when the pane isn't a tmux pane.
    public private(set) var reportedPwd: String?
    public func handlePwd(_ pwd: String?) {
        if let pwd, !pwd.isEmpty { reportedPwd = pwd }
    }

    /// Viewport-top row from the last SCROLLBAR action (visual-row space).
    private var lastScrollTop: Int?
    private let pathHitEngine = SurfacePathHitEngine()

    /// Ordered path candidates + highlight rects under a tap at `point`
    /// (surface coords) — wrap-chain joins first, bare fragment last — plus
    /// screen-context root hints. The caller stat-verifies in order unless
    /// `hits[0].fastPath`. `wrapCols` is the tmux pane width when available;
    /// nil falls back to ghostty's grid. Public: the iOS host lives in the app
    /// target.
    public func pathTapHits(at point: CGPoint, wrapCols: Int?) -> SurfacePathHitEngine.TapScan {
        guard let cs = currentSize, cs.cellWidthPx > 0, cs.cellHeightPx > 0 else { return .empty }
        let s = currentScale
        guard s > 0 else { return .empty }
        let cell = CGSize(width: CGFloat(cs.cellWidthPx) / s, height: CGFloat(cs.cellHeightPx) / s)
        return pathHitEngine.tapHits(
            point: point, cellSize: cell, viewportRows: cs.rows,
            cols: wrapCols ?? cs.columns,
            scrollTop: lastScrollTop,
            readText: { [weak self] in self?.readScrollback() })
    }

    /// The whole scrollback as text (one line per row, top-aligned with the
    /// SCROLLBAR row space). Public: the iOS host lives in the app target.
    public func readScrollback() -> String? {
        guard let surface else { return nil }
        return GhosttySel.readRegion(surface, tag: GHOSTTY_POINT_SCREEN)?.text
    }

    /// Mark the surface dirty so the next display-link tick draws it. Called by
    /// GhosttyRuntime on GHOSTTY_ACTION_RENDER and by every local mutation in
    /// this file (output, scroll, input, selection, focus). Main-thread only —
    /// all iOS surface entry points are main-thread, so no lock (unlike macOS).
    public func setNeedsDraw() { needsDraw = true }

    // Per-surface engine actions — mostly no-ops on iOS (no pointer cursor).
    public func handleMouseShape(_ shape: ghostty_action_mouse_shape_e) {}
    public func handleMouseVisibility(_ visible: Bool) {}

    // Scrollback search is macOS-only for now — the engine side is shared (see
    // GhosttySel.search), only the find-bar UI is not built for touch yet. These
    // stubs exist because the runtime's action router is one shared switch.
    // MARK: - Scrollback search
    //
    // The engine owns the search itself — it walks the scrollback, highlights
    // the matches in the renderer, tracks the current hit and reports the counts
    // back. The surface only relays; the host owns the find bar, because on iOS
    // it has to be positioned against the keyboard.

    /// The engine asked the host to open its find UI (its own search keybind
    /// fired — hardware ⌘F on iPad). `needle` is a prefill, usually the selection.
    public var onSearchStartRequested: ((String?) -> Void)?
    /// The engine ended the search; the host should close its find UI.
    public var onSearchEnded: (() -> Void)?
    /// Match counts, nil = the engine's -1 ("none").
    public var onSearchCounts: ((_ total: Int?, _ selected: Int?) -> Void)?

    private var searchTotal: Int?
    private var searchSelected: Int?

    /// Start (or re-run) the search. An empty needle ends it.
    public func runSearch(_ needle: String) {
        guard let surface else { return }
        GhosttySel.search(surface, needle: needle)
        if needle.isEmpty {
            searchTotal = nil
            searchSelected = nil
            onSearchCounts?(nil, nil)
        }
        setNeedsDraw()
    }

    public func navigateSearch(forward: Bool) {
        guard let surface else { return }
        GhosttySel.navigateSearch(surface, forward: forward)
        setNeedsDraw()
    }

    public func endSearch() {
        guard let surface else { return }
        GhosttySel.endSearch(surface)
        searchTotal = nil
        searchSelected = nil
        setNeedsDraw()
    }

    /// Current selection, when it makes a usable needle (single-line, non-empty).
    /// Seeds the find field the way ⌘E does on the Mac.
    public func selectionAsNeedle() -> String? {
        guard let surface, let text = GhosttySel.selectedText(surface),
              !text.isEmpty, !text.contains("\n") else { return nil }
        return text
    }

    public func handleStartSearch(needle: String?) { onSearchStartRequested?(needle) }
    public func handleEndSearch() { onSearchEnded?() }

    public func handleSearchTotal(_ total: Int?) {
        searchTotal = total
        onSearchCounts?(searchTotal, searchSelected)
    }

    public func handleSearchSelected(_ selected: Int?) {
        searchSelected = selected
        onSearchCounts?(searchTotal, searchSelected)
    }

    public func handleRendererHealth(healthy: Bool) {
        onRendererHealthChanged?(healthy)
    }

    // MARK: - Tap-to-open links

    public func handleMouseOverLink(_ url: String?) {
        // This prebuilt libghostty never emits MOUSE_OVER_LINK (verified — like
        // RENDER, its whole link pipeline expects the desktop apprt's hover
        // plumbing, so hover state is never populated and click-activation
        // checks it in vain). Link hit-testing is therefore OURS: see
        // openLinkIfPresent below.
    }

    /// A tap landed at `point` — if a URL is rendered under it, open it. This
    /// is what makes remote agent sign-in (an OAuth URL printed by a headless
    /// host) completable from the phone.
    ///
    /// ghostty's own link pipeline is inert in this prebuilt (see above), so
    /// the hit-test is done here: read the VISUAL row under the tap via a
    /// transient row-selection ("what you see is what we scan" — no
    /// logical-line/visual-row mapping), reassemble the wrap-chain when the
    /// row runs edge-to-edge (long OAuth URLs always wrap), then regex for a
    /// URL span containing the tap column.
    /// Returns whether a URL was found and opened — callers chain the
    /// path-preview hit-test off a miss (the two detectors are disjoint).
    @discardableResult
    public func openLinkIfPresent(at point: CGPoint) -> Bool {
        guard let surface, let size = currentSize else { return false }
        // A live selection means the tap is selection management, not a link.
        guard !GhosttySel.hasSelection(surface) else { return false }
        let scale = renderScale
        let cellW = CGFloat(size.cellWidthPx) / scale
        let cellH = CGFloat(size.cellHeightPx) / scale
        guard cellW > 0, cellH > 0, size.columns > 0 else { return false }
        let tapRow = Int(point.y / cellH)
        let tapCol = Int(point.x / cellW)
        guard tapRow >= 0, tapCol >= 0, tapCol < size.columns else { return false }

        // Cheap first pass: just the tapped row. Most taps hit nothing linky.
        guard let rowText = readVisualRow(tapRow, cellH: cellH),
              rowText.contains("://") || rowText.contains("mailto:") || rowChainMayWrap(rowText, columns: size.columns)
        else {
            clearSelection()
            return false
        }

        // Read the neighbors so a wrapped URL reassembles across rows.
        let radius = 3
        let lo = max(0, tapRow - radius)
        var rows: [String] = []
        for r in lo...(tapRow + radius) {
            guard let text = readVisualRow(r, cellH: cellH) else { break }
            rows.append(text)
        }
        clearSelection()

        guard let url = TerminalLinkDetector.urlHit(rows: rows, tapRow: tapRow - lo,
                                                    tapCol: tapCol, columns: size.columns) else {
            return false
        }
        GhosttyRuntime.openExternalURL(url)
        return true
    }

    /// A row whose glyphs run to the very last column is (very likely) wrapped
    /// — its URL may START on an earlier row even if "://" isn't on this one.
    private func rowChainMayWrap(_ text: String, columns: Int) -> Bool {
        TerminalLinkDetector.displayWidth(text) >= columns
    }

    /// Read one visual row's text via a transient edge-to-edge selection at
    /// that row's y-band. Caller clears the selection when done. The drag is
    /// stepped through a few intermediate positions — a single press→far-jump
    /// →release reads as a click to the engine, not a drag, and yields a
    /// fragment (observed: only the row's trailing segment came back).
    private func readVisualRow(_ row: Int, cellH: CGFloat) -> String? {
        guard let surface else { return nil }
        let y = (Double(row) + 0.5) * Double(cellH)
        guard y < Double(bounds.height) else { return nil }
        let maxX = Double(bounds.width) - 1.0
        _ = GhosttySel.begin(surface, px: (1.0, y))
        for step in 1...4 {
            GhosttySel.extend(surface, px: (maxX * Double(step) / 4.0, y))
        }
        GhosttySel.end(surface)
        return GhosttySel.selectedText(surface) ?? ""
    }


    // MARK: - Input (UIKeyInput)

    public override var canBecomeFirstResponder: Bool { true }
    public var hasText: Bool { true }

    // ghostty_surface_key (used for hardware keys below) is ignored unless the
    // surface is focused, so keep ghostty's focus in sync with first-responder
    // status. (ghostty_surface_text / insertText doesn't need this, which is why
    // soft-keyboard text worked even without it.)
    @discardableResult
    public override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if let surface { ghostty_surface_set_focus(surface, true) }
        setNeedsDraw()
        return ok
    }

    @discardableResult
    public override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if let surface { ghostty_surface_set_focus(surface, false) }
        setNeedsDraw()
        return ok
    }

    private var _inputAccessoryView: UIView?
    public override var inputAccessoryView: UIView? {
        get { _inputAccessoryView }
        set { _inputAccessoryView = newValue }
    }
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

    public func insertText(_ text: String) {
        guard let surface, !text.isEmpty else { return }
        // Committed text (typing or a chosen IME candidate): drop any in-flight
        // composition preedit before sending it.
        if !markedTextValue.isEmpty {
            markedTextValue = ""
            GhosttySel.setPreedit(surface, nil)
        }
        // The soft keyboard delivers Enter as "\n" (LF), but a terminal expects
        // CR (0x0d) to run the line — zsh/readline's line editor only accepts
        // the line on CR.
        //
        // We CANNOT just rewrite "\n" -> "\r" and feed it through
        // ghostty_surface_text: that channel is for printable text, and ghostty
        // drops the bare CR control byte instead of emitting it to the host, so
        // Enter appears to do nothing (the line never runs). Instead, split the
        // input — printable runs still go through ghostty (so per-mode encoding
        // and IME keep working) while each newline is written to the host
        // directly as CR, the same proven path deleteBackward() and the
        // accessory Enter key (sendString("\r")) already use.
        var run = ""
        func flushRun() {
            guard !run.isEmpty else { return }
            let bytes = Array(run.utf8)
            bytes.withUnsafeBufferPointer { buf in
                buf.baseAddress?.withMemoryRebound(to: CChar.self, capacity: buf.count) { ptr in
                    ghostty_surface_text(surface, ptr, UInt(buf.count))
                }
            }
            run = ""
        }
        for ch in text {
            if ch == "\n" || ch == "\r" {
                flushRun()
                onInput?(Data([0x0d]))
            } else {
                run.append(ch)
            }
        }
        flushRun()
        setNeedsDraw()
    }

    public func deleteBackward() {
        // While composing, UIKit edits the marked text via setMarkedText — never
        // send a host backspace mid-composition.
        if !markedTextValue.isEmpty { unmarkText(); return }
        onInput?(Data([0x7f]))
    }

    // MARK: - IME (UITextInput marked text)
    //
    // The terminal isn't an editable text document, so this is a DEGENERATE
    // UITextInput: the "document" is just the in-flight IME composition (marked
    // text). Committed text and hardware keys still go through insertText /
    // pressesBegan. Marked text (Pinyin/CJK candidates) is rendered INLINE by the
    // engine via ghostty_surface_preedit; nothing reaches the host until commit.
    // Rendering is dirty-driven (like macOS), so each preedit change marks the
    // surface dirty and paints on the next display-link tick.

    private var markedTextValue = ""
    public var markedTextStyle: [NSAttributedString.Key: Any]?
    public weak var inputDelegate: UITextInputDelegate?
    private lazy var _tokenizer: UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)
    public var tokenizer: UITextInputTokenizer { _tokenizer }

    public var markedTextRange: UITextRange? {
        markedTextValue.isEmpty ? nil : TermTextRange(0, markedTextValue.count)
    }

    public func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        let text = markedText ?? ""
        markedTextValue = text
        guard let surface else { return }
        GhosttySel.setPreedit(surface, text)
        setNeedsDraw()
    }

    /// Mosh-style predicted keystrokes, painted as the engine's preedit overlay
    /// (same underlined styling as IME composition — apt for "typed but not yet
    /// confirmed"). A live IME composition owns the slot and takes precedence.
    public func setPredictedText(_ text: String) {
        guard let surface, markedTextValue.isEmpty else { return }
        GhosttySel.setPreedit(surface, text)
        setNeedsDraw()
    }

    public func unmarkText() {
        // The marked text was only a ghostty preedit OVERLAY — it was never
        // actually inserted into the document. So when the IME "unmarks" to
        // confirm a candidate (iOS treats our reported marked range as already-in-
        // document text and commits by unmarking, NOT by calling insertText), we
        // must COMMIT it to the host here, or the chosen characters are lost.
        // insertText-based commits already emptied markedTextValue, so this can't
        // double-send.
        let pending = markedTextValue
        if pending.isEmpty {
            if let surface { GhosttySel.setPreedit(surface, nil) }
            setNeedsDraw()
            return
        }
        insertText(pending)   // clears marked + preedit, then sends to the host
    }

    // MARK: - UITextInput document model (degenerate)

    public var beginningOfDocument: UITextPosition { TermTextPosition(0) }
    public var endOfDocument: UITextPosition { TermTextPosition(markedTextValue.count) }

    public var selectedTextRange: UITextRange? {
        get { let n = markedTextValue.count; return TermTextRange(n, n) }
        set { }
    }

    public func text(in range: UITextRange) -> String? {
        guard let r = range as? TermTextRange else { return nil }
        let chars = Array(markedTextValue)
        let f = min(max(r.from, 0), chars.count)
        let t = min(max(r.to, 0), chars.count)
        guard f <= t else { return "" }
        return String(chars[f..<t])
    }
    public func replace(_ range: UITextRange, withText text: String) {
        // Some input paths confirm a candidate via replace() rather than
        // insertText() — treat it as a commit so the text reaches the host.
        if !text.isEmpty { insertText(text) }
    }

    public func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        TermTextRange(off(fromPosition), off(toPosition))
    }
    public func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        TermTextPosition(off(position) + offset)
    }
    public func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        TermTextPosition(off(position) + offset)
    }
    public func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        let a = off(position), b = off(other)
        return a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }
    public func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        off(toPosition) - off(from)
    }
    public func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        (direction == .left || direction == .up) ? range.start : range.end
    }
    public func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        let p = off(position); return TermTextRange(p, p)
    }
    public func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection { .leftToRight }
    public func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) { }

    // Geometry — anchor inline UI (IME candidates) and keyboard avoidance at the
    // real terminal cursor, which isn't always at the bottom (TUIs put it
    // anywhere). Falls back to a bottom-left caret if the surface is gone.
    public func firstRect(for range: UITextRange) -> CGRect { caretRect(for: range.start) }
    public func caretRect(for position: UITextPosition) -> CGRect {
        cursorRect() ?? CGRect(x: 2, y: max(bounds.height - 24, 0), width: 2, height: 22)
    }

    /// The terminal cursor (insertion point) rect in this surface's coordinate
    /// space, from ghostty's IME point. ghostty reports LOGICAL POINTS with a
    /// TOP-LEFT origin relative to the surface — the same convention as
    /// `mouse_pos`/`pxPoint` (content scale applied internally), so no y-flip or
    /// scale division. nil if there's no live surface.
    public func cursorRect() -> CGRect? {
        guard let surface else { return nil }
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        let width = w > 1 ? CGFloat(w) : 2
        let height = h > 1 ? CGFloat(h) : 18
        return CGRect(x: CGFloat(x), y: CGFloat(y), width: width, height: height)
    }
    public func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }
    public func closestPosition(to point: CGPoint) -> UITextPosition? { TermTextPosition(0) }
    public func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? { range.start }
    public func characterRange(at point: CGPoint) -> UITextRange? { nil }

    private func off(_ p: UITextPosition) -> Int { (p as? TermTextPosition)?.offset ?? 0 }

    // Hardware keys (arrows / Enter / Ctrl chords / function keys) arrive as
    // UIPress, not insertText. Route through ghostty_surface_key so the engine
    // encodes them (needs focus — handled above).
    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if forwardPresses(presses, action: GHOSTTY_ACTION_PRESS) { return }
        super.pressesBegan(presses, with: event)
    }

    public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if forwardPresses(presses, action: GHOSTTY_ACTION_RELEASE) { return }
        super.pressesEnded(presses, with: event)
    }

    public override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if forwardPresses(presses, action: GHOSTTY_ACTION_RELEASE) { return }
        super.pressesCancelled(presses, with: event)
    }

    private func forwardPresses(_ presses: Set<UIPress>, action: ghostty_input_action_e) -> Bool {
        guard let surface else { return false }
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            handled = true
            let keyMods = mods(from: key.modifierFlags)
            var keyEvent = ghostty_input_key_s(
                action: action,
                mods: keyMods,
                consumed_mods: consumedMods(keyMods, surface: surface),
                keycode: UInt32(key.keyCode.rawValue),
                text: nil,
                unshifted_codepoint: key.charactersIgnoringModifiers.unicodeScalars.first?.value ?? 0,
                composing: false
            )
            let text = key.characters
            if text.isEmpty {
                ghostty_surface_key(surface, keyEvent)
            } else {
                text.utf8CString.withUnsafeBufferPointer { buf in
                    keyEvent.text = buf.baseAddress
                    ghostty_surface_key(surface, keyEvent)
                }
            }
        }
        return handled
    }

    /// Which of the held modifiers ghostty should treat as already "consumed" to
    /// produce this event's text — the layout's translation mods (Shift/CapsLock/
    /// Option-as-Alt), minus Ctrl/Super. Mirrors the macOS `consumedMods(from:
    /// surface:)`. Critical for shifted symbols whose glyph is NOT a case-fold of
    /// the base key (":" "?" "!" "@" …): with consumed_mods hardcoded to NONE the
    /// engine saw an unconsumed Shift over a symbol it couldn't reconcile and
    /// dropped the key — e.g. Shift+; never emitted ":" from an external keyboard.
    private func consumedMods(_ keyMods: ghostty_input_mods_e, surface: ghostty_surface_t) -> ghostty_input_mods_e {
        let translated = ghostty_surface_key_translation_mods(surface, keyMods)
        var raw = translated.rawValue
        raw &= ~GHOSTTY_MODS_CTRL.rawValue
        raw &= ~GHOSTTY_MODS_SUPER.rawValue
        return ghostty_input_mods_e(rawValue: raw)
    }

    private func mods(from flags: UIKeyModifierFlags) -> ghostty_input_mods_e {
        var raw = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.alternate) { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.alphaShift) { raw |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(rawValue: raw)
    }
}

/// Weak relay between CADisplayLink and the surface, so the link doesn't retain
/// the view (which would leak it and keep it drawing after teardown).
private final class DisplayLinkProxy {
    weak var surface: GhosttyTerminalSurface?
    init(_ surface: GhosttyTerminalSurface) { self.surface = surface }
    @objc func tick() {
        // CADisplayLink fires on the main run loop (added with .main mode).
        MainActor.assumeIsolated { surface?.renderTick() }
    }
}

/// Integer-offset position/range for the terminal's degenerate UITextInput
/// document (the document is just the in-flight IME composition).
private final class TermTextPosition: UITextPosition {
    let offset: Int
    init(_ offset: Int) { self.offset = max(0, offset) }
}

private final class TermTextRange: UITextRange {
    let from: Int
    let to: Int
    init(_ a: Int, _ b: Int) { from = min(a, b); to = max(a, b) }
    override var start: UITextPosition { TermTextPosition(from) }
    override var end: UITextPosition { TermTextPosition(to) }
    override var isEmpty: Bool { from == to }
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
extension GhosttyTerminalSurface: @preconcurrency GhosttySurfaceUserdata {}
#endif
