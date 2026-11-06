#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import BentoFilePreviewKit
import BentoFoundationKit
import AppKit
import GhosttyKit

extension GhosttyTerminalSurface {

    // MARK: - Scroll

    /// Rows scrolled per row of finger travel, for high-precision (trackpad)
    /// deltas. AppKit already accelerates those deltas, so tracking them 1:1
    /// overshoots when you're reading text — half speed is the readable ratio.
    /// Lower this to slow the trackpad further; the mouse wheel is unaffected.
    private static let trackpadScrollRatio = 0.5

    public override func scrollWheel(with event: NSEvent) {
        clearPathHover()   // rows shift under the cursor; stale highlight lies
        guard let surface else { return }

        // tmux has this pane in copy-mode: IT owns the viewport, and it repaints
        // the pane from its own scroll position. Running our scrollback scroll as
        // well means two scroll positions for one screen — you scroll up, tmux
        // repaints the same rows, nothing appears to move. Hand the wheel to
        // tmux's copy-mode instead.
        if tmuxInMode {
            let rows = copyModeScrollRows(event)
            if rows != 0 { onCopyModeScroll?(rows) }
            return
        }

        // Mouse-reporting pane → forward wheel as button 64 (up) / 65 (down).
        // ⇧-scroll falls through to our own scrollback, matching xterm (and the
        // ⇧-drag bypass right below it).
        if shouldReportMouse(event) {
            forwardScrollAsWheel(event)
            return
        }

        // ghostty applies scroll at the tracked mouse position, so make sure it
        // knows the cursor is inside this surface first.
        updateMousePosition(event)

        // Pack ghostty's scroll mods: bit 0 = high-precision (trackpad),
        // bits 1-3 = momentum phase (see src/input/mouse.zig).
        var mods: Int32 = 0
        if event.hasPreciseScrollingDeltas { mods |= 1 }
        let momentum: ghostty_input_mouse_momentum_e
        switch event.momentumPhase {
        case .began:      momentum = GHOSTTY_MOUSE_MOMENTUM_BEGAN
        case .stationary: momentum = GHOSTTY_MOUSE_MOMENTUM_STATIONARY
        case .changed:    momentum = GHOSTTY_MOUSE_MOMENTUM_CHANGED
        case .ended:      momentum = GHOSTTY_MOUSE_MOMENTUM_ENDED
        case .cancelled:  momentum = GHOSTTY_MOUSE_MOMENTUM_CANCELLED
        case .mayBegin:   momentum = GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN
        default:          momentum = GHOSTTY_MOUSE_MOMENTUM_NONE
        }
        mods |= Int32(momentum.rawValue) << 1

        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            // ghostty's precise path reads the delta in DEVICE PIXELS (it divides
            // by the cell's pixel height to get rows), but AppKit reports trackpad
            // deltas in POINTS — passing them raw made the speed depend on the
            // display: 1:1 with the finger on a non-Retina monitor, half that on
            // Retina. Convert points → pixels, then apply the ratio so every
            // display scrolls alike.
            let s = Double(currentScale) * Self.trackpadScrollRatio
            x *= s
            y *= s
        } else {
            // Mouse wheel: deltas are in lines — scale so each notch moves a few rows.
            x *= 3
            y *= 3
        }
        ghostty_surface_mouse_scroll(surface, x, y, mods)
        ghostty_surface_refresh(surface)
        setNeedsDraw()
    }

    // MARK: - tmux copy-mode (entered from outside Bento)

    private func copyModeScrollRows(_ event: NSEvent) -> Int {
        let dy = event.scrollingDeltaY
        guard event.hasPreciseScrollingDeltas else {
            return dy == 0 ? 0 : (dy > 0 ? 3 : -3)   // one notch ≈ a few rows
        }
        if event.phase == .began { copyModeRows.reset() }
        guard let cell = cellSizePoints() else { return 0 }
        // Same points-per-row as the local scrollback path, so a pane in
        // copy-mode scrolls at the speed the others do.
        let rows = copyModeRows.rows(adding: dy, rowHeight: cell.height / Self.trackpadScrollRatio)
        guard rows != 0 else { return 0 }
        // Cap the burst; a flick's momentum tail would otherwise send tmux a very
        // large repeat count in one command.
        return max(-12, min(12, rows))
    }

    /// Forward a scroll to a mouse-reporting program (an alt-screen TUI) as wheel
    /// button reports. A wheel notch is one report, but a trackpad emits a
    /// continuous stream of tiny deltas at ~60-120 Hz — one report each sent the
    /// TUI flying. Accumulate the precise deltas and emit one report per whole
    /// cell-row of travel instead, matching the touch path on iOS.
    private func forwardScrollAsWheel(_ event: NSEvent) {
        let dy = event.scrollingDeltaY
        guard event.hasPreciseScrollingDeltas else {
            guard dy != 0 else { return }
            forwardMouse(event, button: dy > 0 ? 64 : 65, press: true)
            return
        }
        if event.phase == .began { wheelReportRows.reset() }   // fresh gesture
        guard let cell = cellSizePoints() else { return }
        // Points of finger travel per report — the same ratio the local
        // scrollback path uses, so both kinds of pane scroll at one speed.
        let rows = wheelReportRows.rows(adding: dy,
                                        rowHeight: cell.height / Self.trackpadScrollRatio)
        guard rows != 0 else { return }
        let button = rows > 0 ? 64 : 65
        // Cap the burst: a flick's momentum tail can cross many rows in one
        // event, and TUIs handle a wall of wheel reports poorly.
        for _ in 0..<min(abs(rows), 8) { forwardMouse(event, button: button, press: true) }
    }

    public override func mouseMoved(with event: NSEvent) {
        updateMousePosition(event)
        if event.modifierFlags.contains(.command) {
            updatePathHover(event)
        } else {
            clearPathHover()
        }
    }

    // A tracking area is required for `mouseMoved` to fire at all — without it,
    // mouse-motion reporting (xterm modes 1002/1003) and hover never reach the
    // app. Scoped to the key window + visible rect so background panes stay quiet.
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    private func updateMousePosition(_ event: NSEvent) {
        guard let surface else { return }
        // Remember WHERE we told the engine the pointer is, so a MOUSE_OVER_LINK
        // that comes back can be attributed to a cell. Without that anchor a
        // stale hover from three cells ago would answer the next ⌘click.
        lastEngineMouseCell = cellCoord(event)
        let p = pxPoint(event)
        ghostty_surface_mouse_pos(surface, p.x, p.y, modsFromFlags(event.modifierFlags))
    }

    /// 1-based cell under a view point (the `cellCoord(_ event:)` twin).
    func cellCoord(atPoint p: NSPoint) -> (col: Int, row: Int) {
        GhosttyCellGeometry.cell(at: p, size: currentSize, scale: currentScale)
    }

    // MARK: - Mouse selection

    /// Mouse position for ghostty in LOGICAL POINTS (not backing pixels).
    /// ghostty applies the surface content scale internally, so passing pixels
    /// double-applies the scale (selection landed at 2× the row on Retina).
    private func pxPoint(_ event: NSEvent) -> (x: Double, y: Double) {
        let loc = convert(event.locationInWindow, from: nil)
        return (Double(loc.x), Double(loc.y))
    }

    // MARK: - Mouse reporting (tmux -CC)

    /// Holding SHIFT takes the mouse back from a program that grabbed it, so you
    /// can always drag out a selection. This is xterm's convention and ghostty's
    /// default (`mouse-shift-capture = false`) — worth matching exactly, because
    /// it's the reflex a terminal user already has.
    ///
    /// Note this is NOT free today: `forwardMouse` encodes shift as a modifier
    /// bit, so before this the shift-drag just reached the program as a modified
    /// drag and the user got no selection and no explanation.
    private func mouseReportingBypassed(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(.shift)
    }

    /// Whether this event should be handed to the program rather than used for
    /// local selection.
    private func shouldReportMouse(_ event: NSEvent) -> Bool {
        mouseReporting.any && !mouseReportingSuppressed && !mouseReportingBypassed(event)
    }

    /// Explain the grabbed mouse the moment it bites: the user pressed and
    /// dragged a meaningful distance in a pane whose program owns the mouse, and
    /// got no selection for it. Rate-limited so it teaches once and then stays
    /// out of the way.
    private func noteReportedDrag(_ event: NSEvent) {
        guard let origin = reportedDragOrigin else { return }
        let p = convert(event.locationInWindow, from: nil)
        let cell = cellSizePoints() ?? CGSize(width: 8, height: 16)
        guard abs(p.x - origin.x) > cell.width * 3 || abs(p.y - origin.y) > cell.height * 2 else { return }
        reportedDragOrigin = nil   // one evaluation per drag
        if let last = lastMouseGrabHintAt, Date().timeIntervalSince(last) < 60 { return }
        lastMouseGrabHintAt = Date()
        PaneHintChip.show("This app is using the mouse — hold ⇧ to select", in: self)
    }

    /// Cell (col,row), 1-based, for a mouse event — from the cell pixel size.
    func cellCoord(_ event: NSEvent) -> (col: Int, row: Int) {
        let p = pxPoint(event)
        return cellCoord(atPoint: NSPoint(x: p.x, y: p.y))
    }

    private func mouseModBits(_ flags: NSEvent.ModifierFlags) -> Int {
        (flags.contains(.shift) ? 4 : 0)
            + (flags.contains(.option) ? 8 : 0)
            + (flags.contains(.control) ? 16 : 0)
    }

    /// Encode a mouse event and forward it to the program. `button`: 0=left,
    /// 1=middle, 2=right, 64=wheel-up, 65=wheel-down. Returns true if sent.
    @discardableResult
    private func forwardMouse(_ event: NSEvent, button: Int, press: Bool, motion: Bool = false) -> Bool {
        // The gate lives here so every entry point (click, drag, middle, right,
        // wheel) honors the ⇧ bypass and the sticky suppression identically.
        guard shouldReportMouse(event) else { return false }
        sendMouseReport(event, button: button, press: press, motion: motion)
        return true
    }

    /// Ungated encode-and-send. Only for completing a gesture whose PRESS was
    /// already forwarded: the release and the drags in between must go out even
    /// if the gate has since flipped (the user pressed ⇧ mid-drag, or the pane
    /// stopped reporting), or the program is left believing a button is still
    /// down and every later click reads as a drag.
    private func sendMouseReport(_ event: NSEvent, button: Int, press: Bool, motion: Bool = false) {
        let (col, row) = cellCoord(event)
        // Encoding is shared with the iOS surface (`MouseReport`) — same bytes,
        // one place, so a touch click and a mouse click can't disagree.
        onInput?(MouseReport.encode(button: button, press: press, col: col, row: row,
                                    mods: mouseModBits(event.modifierFlags),
                                    motion: motion, sgr: mouseReporting.sgr))
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onSelect?()
        leftButtonForwarded = false
        bentoConsumedPress = false
        guard let surface else { return }
        // ⌘-click declares link intent (standard terminal convention), checked
        // before TUI forwarding and instead of starting a selection: a URL
        // opens (queued to mouseUp so a drag can still cancel), a recognized
        // file path previews. The two detectors are disjoint — the path
        // scanner excludes URLs — so the order is just cost.
        if event.modifierFlags.contains(.command) {
            let p = convert(event.locationInWindow, from: nil)
            if let url = linkURL(at: p) {
                // ⌘⇧-click is the way out to the system browser; plain ⌘-click
                // goes wherever the preference says (the side dock by default).
                pendingLinkClick = (url, event.modifierFlags.contains(.shift))
                bentoConsumedPress = true
                return
            }
            let scan = pathTapHits(at: p)
            if !scan.hits.isEmpty {
                handlePathClick(scan)
                bentoConsumedPress = true
                return
            }
        }
        // Mouse-reporting pane → forward the click to the program (not selection),
        // unless the user is holding ⇧ to take the mouse back.
        if forwardMouse(event, button: 0, press: true) {
            leftButtonForwarded = true
            let p = convert(event.locationInWindow, from: nil)
            reportedDragOrigin = p
            // Not when ⌘ is already down — that click reached here because the
            // path scan found nothing, and telling someone to do what they just
            // did is worse than saying nothing.
            if !event.modifierFlags.contains(.command) { notePathClickForwarded(at: p) }
            return
        }
        reportedDragOrigin = nil
        if event.clickCount >= 2 {
            _ = GhosttySel.selectWord(surface, px: pxPoint(event))
        } else {
            GhosttySel.begin(surface, px: pxPoint(event), mods: modsFromFlags(event.modifierFlags))
        }
        setNeedsDraw()
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let surface else { return }
        pendingLinkClick = nil   // a drag is never a link click
        if bentoConsumedPress { return }
        if leftButtonForwarded {
            sendMouseReport(event, button: 0, press: true, motion: true)
            noteReportedDrag(event)
            return
        }
        GhosttySel.extend(surface, px: pxPoint(event), mods: modsFromFlags(event.modifierFlags))
        setNeedsDraw()
    }

    public override func mouseUp(with event: NSEvent) {
        let wasForwarded = leftButtonForwarded
        let wasConsumed = bentoConsumedPress
        leftButtonForwarded = false
        bentoConsumedPress = false
        guard let surface else { return }
        if let click = pendingLinkClick {
            pendingLinkClick = nil
            LinkRouter.open(click.url, from: linkOrigin, forceSystem: click.forceSystem)
            return
        }
        if wasForwarded {
            sendMouseReport(event, button: 0, press: false)
            return
        }
        if wasConsumed { return }
        GhosttySel.end(surface, mods: modsFromFlags(event.modifierFlags))
    }

    // Middle button → forward (mouse-report pane, or X11-style middle paste).
    public override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseDown(with: event) }
        middleButtonForwarded = false
        if forwardMouse(event, button: 1, press: true) {
            middleButtonForwarded = true
            return
        }
        guard let surface else { return }
        updateMousePosition(event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE,
                                         modsFromFlags(event.modifierFlags))
    }

    public override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
        if middleButtonForwarded {
            middleButtonForwarded = false
            sendMouseReport(event, button: 1, press: false)
            return
        }
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE,
                                         modsFromFlags(event.modifierFlags))
    }

    private static let voiceHoldThreshold: TimeInterval = 0.25

    public override func rightMouseDown(with event: NSEvent) {
        rightDownEvent = event
        rightVoiceActive = false
        rightHoldTimer?.invalidate()
        // Arm the hold only if voice is wired for this pane; otherwise the quick
        // right-click on release handles everything. We DON'T forward/menu on
        // down so a hold can supersede the click.
        if onVoiceStart != nil {
            // Pre-warm the mic engine NOW (button down) so it's live by the time
            // the hold threshold fires — the warm-up overlaps the wait instead of
            // delaying capture after the compass appears.
            onVoicePrewarm?()
            // Add in `.common` modes so it still fires while the mouse button is
            // held (a default-mode timer is starved during event tracking).
            let timer = Timer(timeInterval: Self.voiceHoldThreshold, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.triggerVoiceHold() }
            }
            RunLoop.current.add(timer, forMode: .common)
            rightHoldTimer = timer
        }
    }

    public override func rightMouseDragged(with event: NSEvent) {
        if rightVoiceActive { onVoiceDrag?(NSEvent.mouseLocation) }
    }

    public override func rightMouseUp(with event: NSEvent) {
        rightHoldTimer?.invalidate()
        rightHoldTimer = nil
        if rightVoiceActive {
            rightVoiceActive = false
            onVoiceEnd?()
            rightDownEvent = nil
            return
        }
        // Released before the hold threshold → a normal right-click. Forward to a
        // mouse-reporting program (press+release together), else pop our menu.
        if shouldReportMouse(event) {
            _ = forwardMouse(event, button: 2, press: true)
            _ = forwardMouse(event, button: 2, press: false)
        } else if let menu = menu(for: event), let down = rightDownEvent {
            menu.popUp(positioning: nil, at: convert(down.locationInWindow, from: nil), in: self)
        }
        rightDownEvent = nil
    }

    /// Hold passed the threshold → enter voice input for this pane.
    private func triggerVoiceHold() {
        guard !isTornDown, onVoiceStart != nil else { return }
        rightVoiceActive = true
        window?.makeFirstResponder(self)
        onSelect?()
        onVoiceStart?(NSEvent.mouseLocation)
    }
}
#endif
