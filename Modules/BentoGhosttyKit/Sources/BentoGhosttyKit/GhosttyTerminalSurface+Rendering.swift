import BentoFilePreviewKit
import BentoFoundationKit
#if canImport(UIKit)
import UIKit
import Metal
import GhosttyKit

extension GhosttyTerminalSurface {

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
            //
            // Anything banked while we were away stays banked for now: the
            // render link drains it a slice per frame from `renderTick`.
            // Flushing it here instead — before the first draw of the returning
            // app — is exactly the push-with-no-drain that hung the app on
            // reopen. See `drainBudgetPerTurn`.
            needsDraw = true
            startRenderLink()
        } else {
            stopRenderLink()
        }
    }

    private func stopRenderLink() {
        renderLink?.invalidate()
        renderLink = nil
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

    func createSurfaceIfNeeded() {
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
        bytesPushedSinceDraw = 0   // this draw emptied the new surface's mailbox
        updateRenderActive()
        // Output that arrived before this surface existed is NOT pushed here:
        // `updateRenderActive` has started the render link, and `renderTick`
        // feeds the backlog a bounded slice at a time with a draw between
        // slices. See `drainBudgetPerTurn`.
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
    var renderScale: CGFloat {
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
        if !needsDraw && !idleDue && gridSettled && pendingBytes.isEmpty { return }
        needsDraw = false
        lastDrawNs = now
        ghostty_surface_draw(surface)
        if !gridSettled { reportSizeIfNeeded() }
        // The draw just emptied ghostty's mailbox, so this is the one moment
        // in the frame where handing it more output cannot block: reset the
        // budget, then push a slice of backlog against it.
        bytesPushedSinceDraw = 0
        drainPendingBytes()
    }

    // MARK: - Engine color report / renderer health

    /// Records the engine's rendered background — see `reportedBackgroundColor`.
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

    /// Forwarded to the host — see `onRendererHealthChanged`.
    public func handleRendererHealth(healthy: Bool) {
        onRendererHealthChanged?(healthy)
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
#endif
