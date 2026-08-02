import Foundation
import SwiftUI
import os
import BentoTmuxKit
import BentoFoundationKit

extension TerminalViewModel {
    // MARK: - Pane Management

    /// Strip tmux control-mode chatter that the parser can fold into a
    /// `capture-pane` response when a transport read splits the stream mid-line
    /// during a session switch (see ControlMode.handleLine). Feeding those lines to the
    /// surface paints raw protocol text — "%output %5 \033[…", "%begin/%end",
    /// "%layout-change …" — over the pane (BUG-007, iOS-mostly). Real captured
    /// screen content never begins with one of these exact markers, so dropping
    /// them is safe and only removes the interleaved junk. Cheap no-op when the
    /// capture has no '%' at all (the common case).
    static func stripControlModeChatter(_ text: String) -> String {
        guard text.utf8.contains(UInt8(ascii: "%")) else { return text }
        let markers = ["%output %", "%begin ", "%end ", "%error ",
                       "%layout-change ", "%window-add ", "%window-close ",
                       "%window-renamed ", "%window-pane-changed", "%unlinked-window-",
                       "%session-changed ", "%sessions-changed", "%pane-mode-changed ",
                       "%client-session-changed", "%config-error", "%exit",
                       "%pause", "%continue", "%subscription-changed"]
        // A line is chatter if it starts with a marker, OR (BUG-007) a marker
        // hides behind a leading NON-PRINTABLE escape/control junk prefix. The
        // non-printable anchor is what keeps real captured content — which starts
        // with a printable glyph — safe even if it contains a marker as substring.
        func isChatter(_ line: Substring) -> Bool {
            if markers.contains(where: { line.hasPrefix($0) }) { return true }
            guard let first = line.unicodeScalars.first,
                  first.value < 0x20 || first.value == 0x7f else { return false }
            let trimmed = line.drop { ch in
                ch.unicodeScalars.allSatisfy { $0.value < 0x20 || $0.value == 0x7f }
            }
            return markers.contains { trimmed.hasPrefix($0) }
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.contains(where: isChatter) else {
            return text   // nothing to strip — preserve the string exactly
        }
        return lines.filter { !isChatter($0) }.joined(separator: "\n")
    }

    public func refreshPanes() async {
        // Session-wide (-s): one command feeds both models — `sessionPanes`
        // (all windows, for the structure/list layer) and `paneViewModels`
        // (current window only, the panes with live surfaces).
        let response = await tmuxService.send(.listPanes(sessionWide: true))
        guard !response.isError else {
            dlog("list-panes error: \(response.output)")
            if response.output.hasPrefix("timeout") { noteCommandTimeout() }
            return
        }
        commandTimeoutStreak = 0

        let allPanes = TmuxParsers.parsePaneList(response.output)
        // Current window's panes via each line's own window_active flag — no
        // dependence on separately-refreshed (possibly stale) window state.
        let panes = allPanes.filter(\.inActiveWindow)
        dlog("Parsed \(allPanes.count) panes (\(panes.count) in active window): \(panes.map { "\($0.id) \($0.width)x\($0.height) at \($0.x),\($0.y)" })")

        // A live tmux session always has at least one pane. An empty parse here
        // is never real state — under fast input the `list-panes` response gets
        // raced/interleaved with `%output` and `parsePaneList` drops every line
        // (it `compactMap`s unparseable lines to nothing). Applying that empty
        // result would wipe `paneViewModels`, tearing down EVERY ghostty surface
        // (black screen + broken responder chain → each keystroke beeps) until
        // the next refresh rebuilds them. Real session/window teardown arrives
        // via `.exit` / `.windowClose`, which change `phase` — so while we still
        // hold panes and the session is live, treat empty as a transient glitch:
        // skip the destructive update and re-fetch shortly.
        // (No isTmuxReady condition: during a REATTACH isTmuxReady is still
        // false while panes are populated — applying an empty parse there
        // would wipe the view-models the surfaces are bound to, which is
        // exactly the "input works, rendering dead" zombie.)
        // A clean response parses every non-empty line; a shortfall means the
        // body was interleaved with %output (see refreshWindows) — partial
        // results would silently drop panes, so treat them like empty.
        let paneLineCount = response.output.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        if panes.isEmpty || allPanes.count != paneLineCount, !paneViewModels.isEmpty, usingTmux {
            log.warning("refreshPanes: ignored raced list-panes parse (\(allPanes.count, privacy: .public)/\(paneLineCount, privacy: .public) lines, have \(self.paneViewModels.count, privacy: .public) panes) — re-fetching")
            DIAG("[DUP] refreshPanes DEFER raced parse (\(allPanes.count)/\(paneLineCount) lines) — re-fetch in 250ms; shared layoutChangeDebounce token")
            layoutChangeDebounce?.cancel()
            layoutChangeDebounce = Task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await refreshPanes()
            }
            return
        }
        // [DUP] The applied set. If a duplicated pane appears in one line then a
        // LATER line (a stale list-panes issued before it existed) omits it,
        // updatePaneViewModels → syncPanes tears its surface down = "闪一下就关掉".
        let dropped = Set(sessionPanes.map(\.id)).subtracting(allPanes.map(\.id))
        DIAG("[DUP] refreshPanes APPLY all=[\(allPanes.map { "\($0.id)" }.joined(separator: ","))] active=[\(panes.map { "\($0.id)" }.joined(separator: ","))]\(dropped.isEmpty ? "" : " DROPPED=[\(dropped.map { "\($0)" }.joined(separator: ","))]")")
        if sessionPanes != allPanes { sessionPanes = allPanes }
        updatePaneViewModels(panes)
        recomputeSessionMode()
    }

    public func refreshWindows() async {
        let response = await tmuxService.send(.listWindows())
        guard !response.isError else { return }
        let parsed = TmuxParsers.parseWindowList(response.output)

        // Under heavy output (e.g. the repaint burst right after select-window
        // resizes the newly-current window) the command response can get
        // interleaved with `%output`, so lines drop or split and the parse
        // comes back partial/empty — same race as refreshPanes' empty-parse
        // guard. Applying a partial list here shrinks `windows`, which
        // e.g. hides the phone's window tab bar until something else happens
        // to refresh. A CLEAN response parses every non-empty line as a
        // window and is never empty on a live session — anything else is
        // corrupt: keep the current list and re-fetch shortly.
        let lineCount = response.output.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        if usingTmux, !windows.isEmpty, parsed.count != lineCount || parsed.isEmpty {
            log.warning("refreshWindows: ignored corrupt list-windows parse (\(parsed.count, privacy: .public)/\(lineCount, privacy: .public) lines, have \(self.windows.count, privacy: .public)) — re-fetching")
            windowsRefreshRetry?.cancel()
            windowsRefreshRetry = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await refreshWindows()
            }
            return
        }
        if windows != parsed { windows = parsed }
        let newActiveWindowID = windows.first(where: { $0.isActive })?.id ?? activeWindowID
        if activeWindowID != newActiveWindowID { activeWindowID = newActiveWindowID }
    }

    /// Apply pane geometry parsed from a `%layout-change` layout string to the
    /// existing panes, immediately, so their ghostty surfaces resize before the
    /// program's repaint output arrives. Updates only geometry (the layout string
    /// carries no command/title/mouse/active info) on panes we already have; new
    /// or removed panes are reconciled by the debounced `refreshPanes`.
    func applyLayoutGeometry(_ layout: String) {
        let geom = TmuxParsers.parsePaneGeometry(layout)
        guard !geom.isEmpty else { return }
        var changed = false
        for g in geom {
            guard let vm = paneViewModels.first(where: { $0.paneID == g.id }) else { continue }
            var p = vm.pane
            guard p.width != g.width || p.height != g.height || p.x != g.x || p.y != g.y else { continue }
            p.width = g.width; p.height = g.height; p.x = g.x; p.y = g.y
            vm.updatePane(p)
            changed = true
        }
        // Resize surfaces SYNCHRONOUSLY now (not via the async $paneViewModels
        // publisher), so they are at the new size before the program's repaint
        // %output — the next notification on this main-actor stream — is fed to
        // ghostty. Each pane already exists (geometry-only change), so the host
        // just re-runs layoutCells; added / removed panes are handled by the
        // debounced refreshPanes.
        if changed { onGeometryApplied?() }
    }

    func updatePaneViewModels(_ panes: [Pane]) {
        // Snapshot BEFORE updatePane mutates the reused instances, so the
        // no-change gate below compares against what was actually published.
        let oldVMs = paneViewModels
        let oldPanes = oldVMs.map(\.pane)

        var newViewModels: [PaneViewModel] = []
        var newPaneIDs: [TmuxPaneID] = []

        for pane in panes {
            if let existing = paneViewModels.first(where: { $0.paneID == pane.id }) {
                existing.updatePane(pane)
                if existing.isActive != pane.isActive { existing.isActive = pane.isActive }
                newViewModels.append(existing)
            } else {
                let vm = PaneViewModel(pane: pane, tmuxService: tmuxService)
                vm.isActive = pane.isActive
                newViewModels.append(vm)
                newPaneIDs.append(pane.id)
                // Lets `%output` for this pane bypass the main thread entirely
                // (see enqueueTmuxNotification). `feedData` is nonisolated and
                // internally locked, so the parse queue can call it directly.
                setOutputSink(pane.id) { [weak vm] data in vm?.feedData(data) }
                DIAG("newVM \(pane.id) \(pane.width)x\(pane.height)")
            }
        }

        // Drop sinks for panes that went away, so a dead pane's bytes don't keep
        // a view model alive or land on a surface that's being torn down.
        let liveIDs = Set(newViewModels.map(\.paneID))
        for old in oldVMs where !liveIDs.contains(old.paneID) {
            setOutputSink(old.paneID, nil)
        }

        // Equality-gate the array publish: the 2s poll usually returns the same
        // panes with the same data, and every republish makes the hosts re-run
        // syncPanes/layout. Identical = same instances in the same order, no
        // new panes, and no per-pane data change.
        let identical = newPaneIDs.isEmpty
            && newViewModels.count == oldVMs.count
            && zip(newViewModels, oldVMs).allSatisfy { $0 === $1 }
            && panes == oldPanes
        if !identical { paneViewModels = newViewModels }

        if !newPaneIDs.isEmpty {
            Task {
                await seedNewPanes(newPaneIDs)
            }
        }

        if let active = panes.first(where: { $0.isActive }) {
            if activePaneID != active.id { activePaneID = active.id }
            // window_zoomed_flag is per-window; the zoomed pane is the active one.
            let newZoom = active.isZoomed ? active.id : nil
            if zoomedPaneID != newZoom { zoomedPaneID = newZoom }
        } else {
            if zoomedPaneID != nil { zoomedPaneID = nil }
        }
    }

    /// Seed freshly-created panes' surfaces with their current screen content
    /// (capture-pane snapshot), then refresh the state pipeline. Extracted from
    /// `updatePaneViewModels`.
    /// How far back a fresh surface is seeded from tmux's history, in lines.
    ///
    /// This used to be one screenful, which meant a pane's scrollback effectively
    /// began at the moment its surface was created — and surfaces are recreated
    /// whenever the pane set changes (`GhosttyTiledPaneHost.syncPanes` tears them
    /// down), so **every window switch threw the scrollback away**. Nothing that
    /// reads backwards worked past that line: scrolling up, scroll-review-
    /// compose, and now ⌘F.
    ///
    /// tmux clamps `-S` to whatever history actually exists, so this is a ceiling,
    /// not a cost floor — an idle shell pane still seeds a few dozen lines, and an
    /// alt-screen TUI has no history at all. The ceiling matters for a pane that
    /// really has scrolled a lot: the capture is one control-mode response, so a
    /// deep one adds latency to the window switch that reveals it. 2000 = tmux's
    /// own default `history-limit`. Override without a rebuild via the
    /// `terminal_seed_history_lines` default.
    /// 2000 = tmux's own default `history-limit`, over a local pty where the
    /// capture is a pipe read.
    ///
    /// Over a network link it is a very different bill: the same capture is
    /// decrypted and drained on the main thread (iOS does all of that there),
    /// it is paid again on every window switch, and `escapes: true` inflates a
    /// colorful agent pane several-fold. So a remote link seeds a few screens —
    /// enough that scrolling back and ⌘F still find something, not enough to
    /// stall an attach on a phone.
    var seedHistoryLines: Int {
        let v = UserDefaults.standard.integer(forKey: "terminal_seed_history_lines")
        if v > 0 { return v }
        return transport.isLocalLink ? 2000 : 400
    }

    func seedNewPanes(_ ids: [TmuxPaneID]) async {
        for paneVM in paneViewModels where ids.contains(paneVM.paneID) {
            let screen = paneVM.pane.height > 0 ? paneVM.pane.height : 50
            let lines = max(screen, seedHistoryLines)
            // Seed the fresh surface with the pane's current screen.
            // `escapes: true` keeps SGR color/style codes so a freshly
            // shown pane (e.g. after a window switch) seeds in full color
            // instead of plain text that then flashes when the live
            // %output repaints. Detection (recordOutput below) strips
            // ANSI anyway, so the escapes are harmless there.
            //
            // capture-pane can race the select-window %output burst
            // (timeout, or a parse that comes back empty): a lost seed
            // leaves the new surface blank until the TUI happens to
            // repaint a region — the "white screen, only updated parts
            // show" on a window switch. Retry a few times on
            // error/empty so the seed actually lands.
            var seeded = false
            for attempt in 0..<3 {
                let resp = await tmuxService.send(.capturePane(id: paneVM.paneID, lines: lines, escapes: true))
                let text = resp.isError ? "" : Self.stripControlModeChatter(resp.output)
                DIAG("seed \(paneVM.paneID) attempt \(attempt): err=\(resp.isError) bytes=\(text.utf8.count)")
                guard !resp.isError, !text.isEmpty else {
                    try? await Task.sleep(for: .milliseconds(120))
                    continue
                }
                let termText = text.replacingOccurrences(of: "\n", with: "\r\n")
                if let data = termText.data(using: .utf8) {
                    paneVM.feedData(data)
                    DIAG("seed \(paneVM.paneID) FED bytes=\(data.count)")
                }
                if let rawData = text.data(using: .utf8) {
                    stateDetection.recordOutput(pane: paneVM.paneID, data: rawData)
                }
                // Restore the caret to the pane's REAL cursor. capture-pane returns
                // the screen rows WITH trailing blank lines below a short prompt;
                // fed as \r\n-terminated rows they park the caret at the bottom of
                // the captured region, not where tmux's cursor actually is. A
                // freshly-split pane then shows its prompt at the top but the caret
                // at the window bottom (other tmux clients don't text-seed, so they
                // render fine). An explicit CUP to tmux's #{cursor_y} #{cursor_x} —
                // 0-based, so +1 for the 1-based CSI — fixes shells and TUIs alike.
                // Fields are SPACE-separated, never ";": ";" is tmux's command
                // separator and would split display-message into two commands; the
                // space also makes the format a quoted single arg (see escapeArg).
                let cur = await tmuxService.send(.displayMessage(format: "#{cursor_y} #{cursor_x}", target: paneVM.paneID))
                let fields = cur.isError ? [] : cur.output
                    .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
                if fields.count == 2, let cy = Int(fields[0]), let cx = Int(fields[1]),
                   let cup = "\u{1b}[\(cy + 1);\(cx + 1)H".data(using: .utf8) {
                    paneVM.feedData(cup)
                    DIAG("seed \(paneVM.paneID) CURSOR restore y=\(cy) x=\(cx)")
                }
                seeded = true
                break
            }
            if !seeded {
                DIAG("seed \(paneVM.paneID) gave up (error/empty)")
            }
        }
        await updatePaneStates()
    }

}
