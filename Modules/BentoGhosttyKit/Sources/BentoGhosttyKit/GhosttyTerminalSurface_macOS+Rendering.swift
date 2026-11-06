#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import BentoFilePreviewKit
import BentoFoundationKit
import AppKit
import GhosttyKit

extension GhosttyTerminalSurface {

    // MARK: - Lifecycle

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        renderObservers.forEach { NotificationCenter.default.removeObserver($0) }
        renderObservers.removeAll()
        guard let window else { stopRenderLink(); return }
        createSurfaceIfNeeded()
        // Start/stop the render loop with the window's visibility (occlusion /
        // miniaturize) so we never spin the GPU-blocking draw while off screen.
        let nc = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
            renderObservers.append(nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated { self.updateRenderActive() }
            })
        }
        // The renderer picks its vsync cadence from the display it believes it is
        // on; dragging a window to another monitor doesn't tell it. Without this
        // an external 60Hz panel keeps being driven on the built-in ProMotion
        // timing (and vice versa) — visible as uneven scrolling on the second
        // display. `viewDidChangeBackingProperties` only fires when the SCALE
        // differs, so it can't stand in for this.
        renderObservers.append(nc.addObserver(forName: NSWindow.didChangeScreenNotification,
                                              object: window, queue: .main) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.syncDisplayID() }
        })
        syncDisplayID()
        updateRenderActive()
    }

    /// Tell ghostty which CoreGraphics display this surface is rendering on.
    private func syncDisplayID() {
        guard let surface, let screen = window?.screen else { return }
        guard let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else { return }
        ghostty_surface_set_display_id(surface, number.uint32Value)
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

    // Fires when the window moves to a display with a different backing scale
    // factor (e.g. a 2× Retina panel ↔ a 1× external monitor). Push the new
    // content scale + drawable size to ghostty so glyphs keep the same physical
    // size; otherwise the OS up/down-scales a stale-resolution drawable and the
    // text balloons (1×→2×) or shrinks (2×→1×) by the scale ratio.
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateSurfaceSize()
    }

    public override func layout() {
        super.layout()
        createSurfaceIfNeeded()
        updateSurfaceSize()
        layoutComposeBar()
        layoutSearchBar()
        layoutHealthBanner()
    }

    var currentScale: CGFloat {
        let s = window?.backingScaleFactor ?? 2.0
        return s > 0 ? s : 2.0
    }

    func createSurfaceIfNeeded() {
        guard !isTornDown,
              surface == nil,
              bounds.width > 0, bounds.height > 0,
              let app = GhosttyRuntime.shared.app else { return }

        var cfg = ghostty_surface_config_new()
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()
        ))
        cfg.scale_factor = Double(currentScale)
        cfg.font_size = Float(theme.fontSize)
        cfg.wait_after_command = false

        guard let created = ghostty_surface_new(app, &cfg) else { return }
        // Publish the surface and claim any buffered bytes atomically — a feed
        // racing on renderQueue either appended to pendingBytes (captured here)
        // or will see the live surface and process directly.
        surfaceLock.lock()
        surface = created
        let queued = pendingBytes
        pendingBytes.removeAll()
        surfaceLock.unlock()
        lastAppliedFontSize = Float(theme.fontSize)

        updateSurfaceSize()
        ghostty_surface_set_focus(created, true)
        syncColorScheme()
        syncDisplayID()
        ghostty_surface_refresh(created)
        ghostty_surface_draw(created)
        updateRenderActive()

        DIAG("surf create \(debugLabel) bounds=\(Int(bounds.width))x\(Int(bounds.height)) queued=\(queued.count)")
        for chunk in queued { feed(chunk) }
    }

    private func updateSurfaceSize() {
        guard let surface, bounds.width > 0, bounds.height > 0 else { return }
        let scale = currentScale
        let w = bounds.width * scale
        let h = bounds.height * scale
        // Clamp to a sane drawable range. A multi-client tmux resize (e.g. the
        // system Terminal attached to the same session and dragging) can briefly
        // hand us a degenerate or huge size; an out-of-range Metal drawable
        // triggers a texture-validation abort / GPU stall. Metal's max texture
        // dimension is 16384 on Apple GPUs.
        guard w >= 1, h >= 1, w <= 16384, h <= 16384 else { return }
        // ghostty makes this a LAYER-HOSTING view (it assigns its own CAMetalLayer
        // via the nsview handle) and sets the layer's contentsScale ONCE at
        // creation from cfg.scale_factor. AppKit does NOT auto-maintain
        // contentsScale for a hosted layer, so when the window is dragged to a
        // display with a different backing scale (2× Retina ↔ 1× external),
        // set_content_scale below fixes ghostty's render density but the layer
        // still COMPOSITES the drawable at the stale scale — glyphs come out
        // wrong by exactly the ratio (and a window resize doesn't fix it, since
        // that only changes bounds). Sync it here, matching the iOS path's
        // synchronizeGhosttyLayerGeometry.
        if let layer, layer.contentsScale != scale {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contentsScale = scale
            CATransaction.commit()
        }
        ghostty_surface_set_content_scale(surface, Double(scale), Double(scale))
        ghostty_surface_set_size(surface, UInt32(w), UInt32(h))
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
            // the pty starts — otherwise the dirty gate would stop drawing first.
            setNeedsDraw()
            return
        }
        // Grid has settled — stop the per-frame size poll from renderTick.
        surfaceLock.lock(); gridSettled = true; surfaceLock.unlock()
        guard size != currentSize else { return }
        currentSize = size
        // Debounce the PTY-resize callback. A continuous window drag fires many
        // size changes; coalescing to one resize ~60ms after it settles means
        // the shell gets a single SIGWINCH and the TUI redraws once, instead of
        // garbling through a burst of mid-drag resizes. Rendering is unaffected
        // — ghostty already has the live pixel size via set_size/draw.
        sizeDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onSizeChanged?(size) }
        sizeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    nonisolated private func startRenderLink() {
        if renderLink == nil {
            var link: CVDisplayLink?
            CVDisplayLinkCreateWithActiveCGDisplays(&link)
            guard let link else { return }
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, userdata in
                guard let userdata else { return kCVReturnSuccess }
                let view = Unmanaged<GhosttyTerminalSurface>.fromOpaque(userdata).takeUnretainedValue()
                view.enqueueRenderTick()
                return kCVReturnSuccess
            }, ctx)
            renderLink = link
        }
        if let renderLink, !CVDisplayLinkIsRunning(renderLink) { CVDisplayLinkStart(renderLink) }
    }

    nonisolated func stopRenderLink() {
        if let renderLink, CVDisplayLinkIsRunning(renderLink) { CVDisplayLinkStop(renderLink) }
    }

    /// Run the render loop only while the surface is actually on screen. ghostty's
    /// draw blocks the main thread on `waitUntilCompleted`; when the window is
    /// occluded / miniaturized, Metal's `nextDrawable` stalls, so an unpaused
    /// display link hangs the app (multi-second beachballs). We also tell ghostty
    /// it's occluded so it skips its own rendering.
    private func updateRenderActive() {
        guard let surface, !isTornDown else { return }
        let visible = isSurfaceVisible
        ghostty_surface_set_occlusion(surface, visible)
        if visible { startRenderLink() } else { stopRenderLink() }
    }

    private var isSurfaceVisible: Bool {
        guard !isTornDown, let window, !isHiddenOrHasHiddenAncestor else { return false }
        if window.isMiniaturized { return false }
        return window.occlusionState.contains(.visible)
    }

    /// Called on the CVDisplayLink thread, once per vsync. Draws when dirty
    /// (output/interaction → full frame rate) or, when idle, at the low backstop
    /// rate (cursor blink + recovery for any un-marked change). This is what
    /// turns the always-on 60fps redraw of every surface into a dirty-driven one.
    nonisolated fileprivate func enqueueRenderTick() {
        scheduleDraw(allowIdle: true, throttle: false)
    }

    /// Schedule a draw on `renderQueue` if one isn't already in flight. Shared by
    /// the CVDisplayLink tick (`allowIdle: true`) and the draw-on-arrival path in
    /// `processFeed` (`throttle: true`). Draw-on-arrival is the latency win: a
    /// freshly-echoed keystroke paints immediately instead of waiting up to a
    /// full frame for the next display-link tick to notice it's dirty — measured
    /// as the dominant (and most jittery) segment of typing latency.
    nonisolated func scheduleDraw(allowIdle: Bool, throttle: Bool) {
        let now = DispatchTime.now().uptimeNanoseconds
        surfaceLock.lock()
        if renderInFlight || isTornDown { surfaceLock.unlock(); return }
        let sinceLast = now &- lastDrawNs
        let idleDue = allowIdle && sinceLast >= Self.idleRedrawIntervalNs
        let dirty = needsDraw
        if !dirty && !idleDue { surfaceLock.unlock(); return }
        // Rate-cap the arrival path so sustained output can't outrun the display
        // refresh; the next vsync tick coalesces whatever this skips.
        if throttle && dirty && sinceLast < Self.minArrivalDrawIntervalNs {
            surfaceLock.unlock(); return
        }
        needsDraw = false
        renderInFlight = true
        lastDrawNs = now
        surfaceLock.unlock()
        renderQueue.async { [weak self] in self?.renderTick() }
    }

    /// Mark the surface dirty so the next display-link tick draws it. Lock-guarded
    /// and callable from any thread — ghostty's RENDER action can arrive off the
    /// main thread, and output (`feed`) runs on `ioQueue`.
    nonisolated public func setNeedsDraw() {
        surfaceLock.lock(); needsDraw = true; surfaceLock.unlock()
    }

    /// Runs on `renderQueue` (NOT main). The synchronous GPU wait inside
    /// `ghostty_surface_draw` therefore blocks only this queue if a frame stalls.
    nonisolated private func renderTick() {
        surfaceLock.lock()
        let s = surface
        let torn = isTornDown
        let settled = gridSettled
        surfaceLock.unlock()
        defer {
            surfaceLock.lock(); renderInFlight = false; surfaceLock.unlock()
        }
        guard !torn, let s else { return }
        if !diagLoggedDraw { diagLoggedDraw = true; DIAG("surf FIRST-DRAW \(debugLabel) settled=\(settled)") }
        // `s` stays valid for this draw: the free is chained onto renderQueue
        // (via enqueueSurfaceFree), serialized behind this running block.
        ghostty_surface_draw(s)
        // ghostty computes its cell grid a few frames after creation; poll it from
        // the draw loop ONLY until it first settles (then `gridSettled` gates this
        // off). After that, size changes come through set_size, which calls
        // reportSizeIfNeeded directly — so we don't post a main-thread size-poll on
        // every frame of every pane (hundreds/sec across many live panes).
        if !settled {
            DispatchQueue.main.async { [weak self] in self?.reportSizeIfNeeded() }
        }
    }

    // MARK: - Engine color report

    /// Records the engine's rendered background — see `reportedBackgroundColor`.
    public func handleColorChange(kind: ghostty_action_color_kind_e, red: UInt8, green: UInt8, blue: UInt8) {
        guard kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND else { return }
        reportedBackgroundColor = NSColor(
            srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255, alpha: 1)
        NotificationCenter.default.post(name: .ghosttySurfaceBackgroundChanged, object: self)
    }

    // MARK: - Renderer health

    /// The Metal renderer reported it stopped working. Without this the pane just
    /// goes black and stays black with no explanation.
    public func handleRendererHealth(healthy: Bool) {
        if healthy {
            healthBanner?.removeFromSuperview()
            healthBanner = nil
            return
        }
        guard healthBanner == nil else { return }
        let label = NSTextField(labelWithString:
            "Renderer stopped — this pane won't update. Close it or restart Bento.")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .white
        label.alignment = .center
        label.wantsLayer = true
        // Brand salmon (docs/bento-icon.svg) — a warning that is deliberately NOT
        // one of the pane state colors, because this is not a pane state.
        label.layer?.backgroundColor = NSColor(srgbRed: 0xE8 / 255.0, green: 0x9B / 255.0,
                                               blue: 0x7C / 255.0, alpha: 1).cgColor
        label.drawsBackground = false
        addSubview(label)
        healthBanner = label
        layoutHealthBanner()
    }

    private func layoutHealthBanner() {
        guard let banner = healthBanner else { return }
        let h: CGFloat = 22
        banner.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
    }
}
#endif
