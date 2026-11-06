#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import BentoFilePreviewKit
import BentoFoundationKit
import AppKit
import GhosttyKit

/// libghostty-backed terminal surface for macOS. Same external-backend contract
/// as the iOS surface (`TerminalSurface`): host feeds remote/pty bytes via
/// `feed`, the engine emits encoded keystrokes back through the runtime's
/// `write_to_host` callback. The view is a CAMetalLayer that libghostty renders
/// into. Mac code (BentoTermMac terminal window) uses it through the protocol,
/// identically to iOS.
// Explicit @MainActor (not inherited from NSView): cross-module, inference
// through AppKit's @preconcurrency annotation degrades to task-isolated, and
// Swift 6 callers then reject sending the surface through async hops.
// Sendable: the class is globally MainActor-isolated, so the conformance is
// sound — the weak capture in `vm.onRawDataReceived` (a @Sendable closure
// firing from the parse queue) can then hop back via `Task { @MainActor }`.
@MainActor
public final class GhosttyTerminalSurface: NSView, TerminalSurface, Sendable {

    public var onInput: ((Data) -> Void)?
    public var onSizeChanged: ((TerminalSurfaceSize) -> Void)?
    /// Never fired by the current implementation — titles flow via tmux.
    public var onTitleChanged: ((String) -> Void)?
    /// Split request (⌘D = side-by-side, ⌘⇧D = stacked). Host wires to the VM.
    public var onSplit: ((_ horizontal: Bool) -> Void)?

    /// The pane-structure section of this surface's right-click menu, supplied
    /// by the host because those actions belong to it (splits, layout, zoom,
    /// swap, move-to-session, close) and this module knows nothing about panes.
    ///
    /// Right-click is the entry point that lands on the pane you MEAN, needs no
    /// travel, and is the only mouse route at all in Focus mode, which has no
    /// pane title bar. Built freshly per open — zoom state and the session list
    /// both change under the user.
    public var contextMenuPaneItems: (() -> [NSMenuItem])?
    /// Click anywhere in the surface → make this the active pane. Host wires to
    /// `viewModel.selectPane`. (The surface consumes mouseDown for selection, so
    /// the container's click handler no longer fires — this restores it.)
    public var onSelect: (() -> Void)?
    /// Right-click-and-hold → voice input. `onVoiceStart` fires (with the press
    /// point in SCREEN coords) once the hold passes the threshold; `onVoiceDrag`
    /// streams the cursor (screen coords) for the compass; `onVoiceEnd` fires on
    /// release. Host wires these to its `MacVoiceController`. When unset, the hold
    /// falls back to the normal right-click (context menu / mouse-report forward).
    public var onVoiceStart: ((NSPoint) -> Void)?
    public var onVoiceDrag: ((NSPoint) -> Void)?
    public var onVoiceEnd: (() -> Void)?
    /// Fires the moment the right button goes down (before the hold threshold) so
    /// the host can pre-warm the mic engine — overlapping cold-start with the hold
    /// the user is already waiting through, so recording is live by the threshold.
    public var onVoicePrewarm: (() -> Void)?
    public internal(set) var currentSize: TerminalSurfaceSize?

    nonisolated(unsafe) var surface: ghostty_surface_t?
    private(set) var theme: TerminalTheme
    nonisolated(unsafe) var renderLink: CVDisplayLink?

    /// `ghostty_surface_draw` synchronously waits for the GPU
    /// (`MTLCommandBuffer.waitUntilCompleted`). When a frame stalls (Space
    /// switch, display sleep, occluded-but-visible transitions, GPU contention)
    /// that wait can last many seconds — so it must NOT run on the main thread,
    /// or the whole app freezes (keys, voice, everything). The display link
    /// enqueues the draw here instead; a stalled frame blocks only this queue,
    /// the UI stays live. `surfaceLock` guards the `surface` pointer across the
    /// render queue (draw + free) and the main thread (create + teardown).
    let renderQueue = DispatchQueue(label: "com.novashang.bento.render", qos: .userInteractive)
    /// Output parsing (`ghostty_surface_process_output`) runs here, SEPARATE from
    /// `renderQueue`, so a slow parse (ghostty's periodic `PageList.grow` bzero)
    /// doesn't make draws queue up behind it — they interleave instead, keeping
    /// the screen updating under heavy output. ghostty's own terminal lock
    /// serializes the parse against the draw internally. The surface free is
    /// chained through BOTH queues (`enqueueSurfaceFree`) so it can never run
    /// while a parse or a draw is still touching the surface.
    private let ioQueue = DispatchQueue(label: "com.novashang.bento.io", qos: .userInteractive)
    let surfaceLock = NSLock()
    /// TEMP: pane-id label + one-shot flags for the white-screen-on-switch trace. REMOVE when fixed.
    nonisolated(unsafe) public var debugLabel = "?"
    nonisolated(unsafe) private var diagLoggedFeed = false
    nonisolated(unsafe) var diagLoggedDraw = false
    /// Coalesce display-link ticks: never queue a second draw while one is still
    /// in flight (a stalled frame would otherwise pile up thousands of draws).
    nonisolated(unsafe) var renderInFlight = false
    /// Dirty flag: the display link only draws when something changed, instead of
    /// an unconditional 60fps redraw of every surface (which kept the GPU and this
    /// queue busy all day on an idle background app — battery drain). Set true by any
    /// dirty source (ghostty's RENDER action, output, resize, focus) and consumed
    /// when a draw is scheduled. Starts true so the first frames draw (which also
    /// poll ghostty's grid size to start the pty — see reportSizeIfNeeded).
    /// Guarded by `surfaceLock` since `setNeedsDraw` is called from any thread.
    nonisolated(unsafe) var needsDraw = true
    /// Timestamp of the last scheduled draw. Drives a low idle redraw rate so the
    /// cursor keeps blinking (the prebuilt libghostty drives blink internally and
    /// never emits a RENDER action) and any un-marked local change still recovers.
    /// Touched only under `surfaceLock`.
    nonisolated(unsafe) var lastDrawNs: UInt64 = 0
    nonisolated static let idleRedrawIntervalNs: UInt64 = 250_000_000   // 250ms ≈ 4fps
    /// Floor between *draw-on-arrival* kicks (a draw fired straight from output
    /// processing instead of waiting for the next CVDisplayLink tick). Keeps a
    /// flood of output from driving the render queue past the display refresh —
    /// anything skipped here is still picked up by the next vsync tick. ~7ms ≈
    /// 140fps ceiling, below ProMotion's 120Hz only marginally.
    nonisolated static let minArrivalDrawIntervalNs: UInt64 = 7_000_000
    /// Once ghostty's cell grid first reports a non-zero size, stop polling it from
    /// every render frame (see `renderTick`): later size changes arrive through
    /// `set_size` (window resize / font change), which calls `reportSizeIfNeeded`
    /// directly. Without this every drawn frame of every pane posts a size-poll to
    /// the main thread — hundreds/sec across many live panes. Guarded by `surfaceLock`.
    nonisolated(unsafe) var gridSettled = false
    nonisolated(unsafe) var pendingBytes: [Data] = []
    var lastAppliedFontSize: Float = 0

    // IME state. `markedText` holds the in-flight composition (e.g. pinyin
    // before a candidate is chosen); the key event currently being routed
    // through the input context is stashed so `doCommandBySelector` can encode
    // special keys (Enter/Tab/arrows) via the engine.
    var markedText = NSMutableAttributedString()
    var keyEventForIME: NSEvent?
    nonisolated(unsafe) private(set) var isTornDown = false

    // Scroll-review-compose: local draft capture while scrolled into history.
    // See docs/scroll-review-compose.md and ScrollReviewCompose.swift.
    let compose = ScrollReviewCompose()
    var composeBar: ComposeBarView?

    // Engine-requested mouse cursor shape (I-beam over text, pointer over links,
    // resize over splits) and hide-on-type visibility.
    var mouseCursor: NSCursor = .iBeam
    var mouseHidden = false

    // Path preview (⌘hover to highlight, ⌘click to open, also on the context
    // menu). The host attaches a `PathPreviewContext` when the pane's files are
    // reachable (local panes; remote fetch is wired per-transport); nil = off.
    /// Open the preview for a confirmed hit. Wired by the host to the app's
    /// preview panel (`BentoTerminalWindow.openPreview`) — the surface layer
    /// must not name the app window type.
    public var onOpenPreview: ((String, Int?, PathPreviewContext) -> Void)?
    public var pathPreviewContext: PathPreviewContext?
    /// Wrap width for the visual-row math. tmux panes pass `pane.width`; nil
    /// falls back to ghostty's grid.
    public var pathWrapCols: (() -> Int?)?
    let pathHitEngine = SurfacePathHitEngine()
    var pathHighlight: PathHighlightView?
    var hoveredPathHit: SurfacePathHitEngine.Hit?
    var lastHoverCell: (col: Int, row: Int)?
    /// Viewport-top row from the last SCROLLBAR action (visual-row space).
    var lastScrollTop: Int?

    // State for the concerns split into GhosttyTerminalSurface_macOS+*.swift
    // (stored properties cannot live in extensions). Original order kept.
    var renderObservers: [NSObjectProtocol] = []

    var sizeDebounce: DispatchWorkItem?

    /// Sub-row remainder for the trackpad → wheel-report path, so a slow drag
    /// still accumulates to whole rows instead of being truncated away.
    var wheelReportRows = ScrollRowAccumulator()

    /// tmux reports this pane as `pane_in_mode`. Bento does not implement
    /// copy-mode; this flag exists so a pane that entered it elsewhere (another
    /// client, a script, the user's own binding) isn't a rectangle that ignores
    /// the scroll wheel with no explanation.
    public var tmuxInMode = false {
        didSet {
            guard oldValue != tmuxInMode else { return }
            if tmuxInMode {
                // Right-click, not the title-bar glyph: Focus mode hides the pane
                // title bar entirely, so the badge isn't always there to point at.
                PaneHintChip.show("tmux copy-mode — scroll to move, right-click to exit", in: self)
            } else {
                PaneHintChip.dismiss(in: self)
            }
        }
    }

    /// Leave copy-mode (host sends tmux's `cancel`).
    public var onExitCopyMode: (() -> Void)?

    /// Wheel travel in copy-mode, in rows (positive = toward older output). The
    /// host turns this into `send-keys -X -N n scroll-up`.
    public var onCopyModeScroll: ((Int) -> Void)?

    var copyModeRows = ScrollRowAccumulator()

    var trackingArea: NSTrackingArea?

    /// The cell the engine was last told the pointer is over.
    var lastEngineMouseCell: (col: Int, row: Int)?
    /// The engine's own answer for that cell: an OSC 8 hyperlink's target.
    var engineLink: (url: String, col: Int, row: Int)?

    /// Per-pane mouse-reporting mode, learned from tmux's `mouse_any_flag` /
    /// `mouse_sgr_flag` (the engine can't see the program's mouse-enable through
    /// control mode). When `any` is on, mouse events are ENCODED and forwarded to
    /// the program via `onInput` instead of doing local selection. Set by the host.
    public struct MouseReporting: Equatable {
        public var any: Bool
        public var sgr: Bool
        public init(any: Bool = false, sgr: Bool = false) { self.any = any; self.sgr = sgr }
    }
    public var mouseReporting = MouseReporting()

    /// User override: mouse reporting suppressed for this pane until toggled back
    /// (the sticky escape hatch behind ⇧-drag). Mirrors ghostty's
    /// `toggle_mouse_reporting`; the pane's title bar shows a glyph while it's on
    /// so a pane that stopped talking to its program explains itself.
    public var mouseReportingSuppressed = false {
        didSet {
            guard oldValue != mouseReportingSuppressed else { return }
            onMouseReportingSuppressedChanged?(mouseReportingSuppressed)
        }
    }
    public var onMouseReportingSuppressedChanged: ((Bool) -> Void)?

    /// Where a mouse-reported drag started, for the "hold ⇧ to select" hint.
    var reportedDragOrigin: NSPoint?
    var lastMouseGrabHintAt: Date?

    /// Whether the CURRENT left/middle button press was forwarded to the
    /// program. Release and drag follow the press's decision rather than
    /// re-deciding, so a report can never arrive unpaired.
    ///
    /// Load-bearing for ⌘click: that path consumes the press for Bento (a path
    /// preview) and returns, so re-deciding at `mouseUp` sent the program a
    /// release with no press. Claude Code's fullscreen mode accepts a bare
    /// release as a click — so every ⌘click on a file path also fired whatever
    /// CC had under the cursor (in practice: copy-to-tmux-buffer), on top of
    /// the preview not opening.
    var leftButtonForwarded = false
    var middleButtonForwarded = false

    /// Bento itself took this press (⌘click on a link or a path). Neither the
    /// program nor the selection engine gets to see the rest of the gesture:
    /// `GhosttySel.end`/`extend` on a press that never called `begin` leaves a
    /// stray selection behind, and a live selection is exactly what the link
    /// reader used to refuse to run on.
    var bentoConsumedPress = false

    // Right button. Press-and-hold (≥ holdThreshold) → voice input (select this
    // pane + start hold-to-talk); a quick right-click → the existing behavior
    // (mouse-report forward, else the Copy/Paste context menu). We defer the
    // quick-click action until release so we can tell a hold from a click.
    var rightHoldTimer: Timer?
    var rightVoiceActive = false
    var rightDownEvent: NSEvent?

    /// The hit captured when the context menu was built, consumed by its item.
    var contextMenuPathHit: SurfacePathHitEngine.Hit?

    /// URL under the pointer (nil when not over a link) → surface tooltip.
    /// A ⌘-mouseDown that hit a URL, resolved (opened) or cancelled (drag) at
    /// mouseUp — standard button semantics.
    var pendingLinkClick: (url: String, forceSystem: Bool)?

    /// Which machine this pane's `localhost` means — see the iOS surface's copy.
    public var linkOriginProvider: (@MainActor () -> LinkOrigin?)?

    var lastReportedLinkURL: String?

    /// OSC 7 working-directory report (shell integration). Lets path-preview
    /// resolve relative paths in non-tmux local panes.
    public internal(set) var reportedPwd: String?

    /// Serial number so a slow resolution can't open a panel for a stale click.
    var pathClickSeq = 0

    /// Rate limit for the "⌘click to preview" nudge.
    var lastPathHintAt: Date?

    /// Debounce timer for arming review mode on a scroll-up. nil unless a
    /// not-at-bottom update is waiting out the settle window.
    var pendingReviewEntry: DispatchWorkItem?

    /// The engine reported an actually-rendered color (initial theme
    /// resolution, config reload, or runtime OSC 10/11/12). Background reports
    /// are broadcast so the window chrome can wear the terminal's true color —
    /// reading the configured theme instead would miss the user's own ghostty
    /// config and any runtime OSC changes.
    public internal(set) var reportedBackgroundColor: NSColor?

    var searchBar: PaneSearchBar?

    var searchTotal: Int?
    var searchSelected: Int?

    var healthBanner: NSTextField?

    public init(theme: TerminalTheme) {
        self.theme = theme
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        // ghostty attaches and manages its own Metal layer on the NSView (via
        // the nsview handle in the surface config). We must NOT override
        // makeBackingLayer / supply our own CAMetalLayer, or ghostty's layer
        // never renders. Just enable layer-backing.
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setupCompose()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        if let renderLink { CVDisplayLinkStop(renderLink) }
        // Free serialized behind any in-flight draw (teardown normally already
        // ran; this is the fallback). Captures only the C pointer, not self.
        surfaceLock.lock(); let s = surface; surface = nil; surfaceLock.unlock()
        if let s { enqueueSurfaceFree(s) }
    }

    /// Explicitly release the ghostty surface + CVDisplayLink, on the main
    /// thread, BEFORE the view/window is deallocated. Relying on `deinit` races
    /// with the display-link render callback and the window-close CoreAnimation
    /// transaction (which committed against the half-freed Metal layer and
    /// crashed — EXC_BAD_ACCESS in -[_NSWindowTransformAnimation dealloc]).
    /// Stopping the link first guarantees no further `ghostty_surface_draw`
    /// touches the layer while AppKit tears the window down. Idempotent.
    public func teardown() {
        guard !isTornDown else { return }
        pendingReviewEntry?.cancel()
        pendingReviewEntry = nil
        rightHoldTimer?.invalidate()
        rightHoldTimer = nil
        searchBar?.model.cancelPendingQuery()
        searchBar?.removeFromSuperview()
        searchBar = nil
        clearPathHover()
        pathHitEngine.invalidate()
        if mouseHidden { NSCursor.unhide(); mouseHidden = false }
        renderObservers.forEach { NotificationCenter.default.removeObserver($0) }
        renderObservers.removeAll()
        if let link = renderLink {
            // Stops scheduling new ticks. (The callback only enqueues onto
            // renderQueue, so this no longer waits for an in-flight draw.)
            CVDisplayLinkStop(link)
            renderLink = nil
        }
        // Detach the surface pointer under the lock so an in-flight parse/draw
        // sees `isTornDown` / nil. Free it behind both queues (enqueueSurfaceFree):
        // serialized after any running parse or draw, so it can never free a
        // surface mid-use — even if a draw is stuck for seconds (the free just
        // waits its turn off-main; the main thread / window close is never blocked).
        surfaceLock.lock()
        isTornDown = true
        let s = surface
        surface = nil
        surfaceLock.unlock()
        if let s {
            if GhosttyRuntime.shared.pasteSurface == s { GhosttyRuntime.shared.pasteSurface = nil }
            enqueueSurfaceFree(s)
        }
        currentSize = nil
    }

    public override var acceptsFirstResponder: Bool { true }
    public override var isFlipped: Bool { true }
    // Allow a click to both focus this pane AND register as the first mouse event
    // (so the click that focuses a pane also reaches a mouse-reporting TUI).
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Keep ghostty's focus in sync with first-responder status. ghostty gates
    // key input AND mouse reporting on the surface being focused; without this
    // the active pane's surface stays unfocused in the engine after a pane/tab
    // switch, so mouse events (and keys) are dropped. (iOS does the same.)
    @discardableResult
    public override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if let surface { ghostty_surface_set_focus(surface, true) }
        return ok
    }

    @discardableResult
    public override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if let surface { ghostty_surface_set_focus(surface, false) }
        return ok
    }

    // MARK: - TerminalSurface

    /// Process terminal output OFF the main thread, on `ioQueue`.
    ///
    /// `ghostty_surface_process_output` parses the byte stream into ghostty's
    /// screen model; under sustained output it periodically grows the scrollback
    /// (`PageList.grow`), whose large `bzero` was blocking the MAIN thread for
    /// ~1s — freezing keystrokes and stalling further output delivery (the
    /// "freeze then burst of many lines" + input lag). ghostty's processing is
    /// internally locked and safe to run off the UI thread (its own apprt does
    /// IO on a dedicated thread). Running on `ioQueue` (separate from the draw's
    /// `renderQueue`) lets draws interleave with parsing instead of queuing
    /// behind it; `enqueueSurfaceFree` chains the free through both queues so it
    /// can never race an in-flight parse or draw (no use-after-free).
    public nonisolated func feed(_ data: Data) {
        ioQueue.async { [weak self] in self?.processFeed(data) }
    }

    nonisolated private func processFeed(_ data: Data) {
        // Read the surface pointer under the lock. If it's gone (torn down) bail;
        // if it's not created yet, buffer. `s` stays valid for the rest of this
        // method because the free is chained behind both queues (see
        // `enqueueSurfaceFree`), so it can't run until this parse returns.
        surfaceLock.lock()
        if isTornDown { surfaceLock.unlock(); return }
        guard let s = surface else {
            if !data.isEmpty { pendingBytes.append(data) }
            let first = !diagLoggedFeed; diagLoggedFeed = true
            surfaceLock.unlock()
            if first { DIAG("surf feed \(debugLabel) bytes=\(data.count) → BUFFERED (no surface yet)") }
            return
        }
        if !diagLoggedFeed { diagLoggedFeed = true; DIAG("surf feed \(debugLabel) bytes=\(data.count) → LIVE surface") }
        surfaceLock.unlock()

        guard !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            guard let ptr = raw.bindMemory(to: CChar.self).baseAddress else { return }
            ghostty_surface_process_output(s, ptr, UInt(data.count))
        }
        ghostty_surface_refresh(s)
        setNeedsDraw()
        // Draw-on-arrival: paint this output now (rate-capped) instead of waiting
        // for the next CVDisplayLink tick to discover the dirty flag. Both run on
        // off-main queues, so this never adds main-thread contention.
        scheduleDraw(allowIdle: false, throttle: true)
    }

    /// Free a surface only after BOTH the parse queue and the render queue have
    /// drained their current work. The caller must have already detached the
    /// pointer (`surface = nil` under `surfaceLock`) so new parse/draw calls bail
    /// without using it. Chaining `ioQueue → renderQueue` guarantees any
    /// in-flight `process_output` (ioQueue) and `draw` (renderQueue) — which each
    /// captured the raw pointer before the detach — have finished before the
    /// free runs. Captures only the queue + pointer, never `self` (safe from
    /// `deinit`).
    nonisolated private func enqueueSurfaceFree(_ s: ghostty_surface_t) {
        let rq = renderQueue
        ioQueue.async { rq.async { ghostty_surface_free(s) } }
    }

    public func applyTheme(_ theme: TerminalTheme) {
        self.theme = theme
        // Light/dark can flip without the font size changing (theme switch,
        // follow-system flip), so this must not live inside the recreate branch.
        syncColorScheme()
        if surface != nil, abs(theme.fontSize - Double(lastAppliedFontSize)) > 0.01 {
            // Stop the render loop BEFORE the create, and defer the create by
            // one main tick so the old surface's last frame commits before a
            // new surface binds the same CAMetalLayer — the iOS
            // recreateSurface discipline (the free/create pair under a live
            // display link is the renderer.Metal initTarget abort pattern,
            // which crashed on device on every font-size change).
            stopRenderLink()
            // Free the old surface only after any in-flight parse/draw finish
            // (see enqueueSurfaceFree) — never out from under either queue.
            surfaceLock.lock()
            let old = surface
            surface = nil
            surfaceLock.unlock()
            if let old { enqueueSurfaceFree(old) }
            currentSize = nil
            // New surface → re-poll the grid from the draw loop until it settles.
            surfaceLock.lock(); gridSettled = false; surfaceLock.unlock()
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isTornDown else { return }
                self.createSurfaceIfNeeded()   // draws + restarts the render link
            }
        }
    }

    public func setFocus(_ focused: Bool) {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, focused)
        setNeedsDraw()
    }

    /// Called by GhosttyRuntime when the engine has bytes for the host.
    public func handleHostWrite(_ data: Data) {
        onInput?(data)
    }

}

// NSTextInputClient is an unisolated AppKit protocol; the class is
// main-actor-isolated (NSView). @preconcurrency silences the crossing check —
// the input-context callbacks only ever arrive on the main thread.
extension GhosttyTerminalSurface: @preconcurrency NSTextInputClient {}
extension GhosttyTerminalSurface: @preconcurrency GhosttySurfaceUserdata {}
#endif
