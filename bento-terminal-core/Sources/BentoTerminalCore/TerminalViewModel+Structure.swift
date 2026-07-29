import Foundation
import SwiftTmux

/// Bento's two-mode model. The user thinks in exactly two shapes:
///
///   Tiled — ONE window, many panes: see every agent at once.
///   List  — many windows, ONE pane each: focus one, switch fast.
///
/// The mode is a READING of the tmux session's structure, never client-side
/// state, and every in-app operation preserves its mode's invariant — inside
/// Bento you cannot produce any third shape. Mixed structures (several
/// windows, some multi-pane) only appear when attaching a session built
/// outside Bento; they read as Tiled (of the current window) and flattening
/// them into List is the one mode switch that asks for confirmation.
///
/// Switching modes IS the structure transformation (break-pane / join-pane —
/// processes untouched, lossless, reversible), shared by every attached
/// device; sizes stay per-device. A degenerate 1×1 session presents as Tiled
/// (Bento's default face) unless the user explicitly chose List, remembered
/// server-side in the `@bento_mode` session option.
public enum TmuxSessionMode: String, Equatable, Sendable {
    case tiled, list
}

/// The raw structural shape (internal reading behind `sessionMode`).
public enum TmuxSessionStructure: Equatable, Sendable {
    /// One window, one pane — both modes coincide.
    case degenerate
    /// One window, many panes.
    case tiled
    /// Many windows, every one a single pane.
    case list
    /// Many windows, at least one holding multiple panes — external sessions
    /// only; reads as Tiled, flattens to List with confirmation.
    case hierarchical
}

/// A window row/tab's visual status — the state aggregate plus the blue
/// "done, unseen" layer that isn't a `PaneState`. See `windowStatus`.
public enum WindowDisplayStatus: Equatable, Sendable {
    case idle       // nothing running / seen — no accent
    case working    // an agent is running — blue
    case awaiting   // an agent needs input — amber
    case doneUnseen // an agent finished while unfocused — green (✓)

    /// Stable signature for the toolbar strip: the segment group is rebuilt
    /// whenever a title OR a dot changes, and mutating a live group's images
    /// doesn't reliably re-render.
    public var dotKey: String {
        switch self {
        case .idle: return "idle"
        case .working: return "working"
        case .awaiting: return "awaiting"
        case .doneUnseen: return "doneUnseen"
        }
    }
}

/// Where a cross-session move lands in the target session. `.auto` derives
/// it from the target's shape (Parallel → its current window, Focus → a new
/// window); the explicit cases are what the UI passes back after the
/// "unsettled target" prompt.
public enum MoveLanding: Sendable, Equatable {
    case auto, joinCurrentWindow, newWindow
}

/// Outcome of a cross-session move. `.needsLandingChoice` means nothing was
/// moved: the target is neither clearly Parallel nor Focus (a fresh 1×1 with
/// no remembered mode, or a mixed external structure) — ask the user and
/// call again with an explicit `MoveLanding`.
public enum MoveResult: Sendable, Equatable {
    case moved, needsLandingChoice, failed
}

/// How a new window (List) or pane (Tiled) gets seeded — the two creation
/// paths, identical in both modes.
public enum WindowSeed: Sendable {
    /// Same working directory and start command as the current pane.
    case duplicateCurrent
    /// Explicit working directory and/or command (nil command = plain shell).
    case custom(path: String?, command: String?)
}

@MainActor
public extension TerminalViewModel {
    // MARK: - Derived structure & mode

    /// The session's structural shape, derived purely from `sessionPanes`.
    var sessionStructure: TmuxSessionStructure {
        let byWindow = panesByWindow
        if byWindow.count <= 1 {
            return (sessionPanes.count > 1) ? .tiled : .degenerate
        }
        return byWindow.values.contains { $0.count > 1 } ? .hierarchical : .list
    }

    /// True when the structure came from outside Bento (windows AND splits) —
    /// the UI warns before flattening it into List.
    var isMixedStructure: Bool {
        panesByWindow.count > 1 && panesByWindow.values.contains { $0.count > 1 }
    }

    /// Recompute `sessionMode` from structure (+ the remembered preference
    /// for the degenerate case). Called after every pane refresh.
    internal func recomputeSessionMode() {
        loadModePreferenceIfNeeded()
        let byWindow = panesByWindow
        let mode: TmuxSessionMode
        if byWindow.count > 1 {
            // Many windows: List — unless it's a mixed external structure,
            // which reads as Tiled (of the current window).
            mode = isMixedStructure ? .tiled : .list
        } else if sessionPanes.count > 1 {
            mode = .tiled
        } else {
            // Degenerate: Bento's default face is Tiled; an explicit List
            // choice sticks so closing down to one window doesn't yank the
            // user out of their List workflow (and its "+" affordance).
            mode = savedModePreference ?? .tiled
        }
        if mode != sessionMode { sessionMode = mode }
    }

    /// One-shot read of the session's remembered mode (`@bento_mode`).
    private func loadModePreferenceIfNeeded() {
        guard usingTmux, !modePreferenceLoaded else { return }
        modePreferenceLoaded = true
        Task { [weak self] in
            guard let self else { return }
            if let raw = await self.readSessionOption(Self.modeOption),
               let saved = TmuxSessionMode(rawValue: raw) {
                self.savedModePreference = saved
                self.recomputeSessionMode()
            }
        }
    }

    /// Switch the session's mode — THE structure transformation. Lossless and
    /// unconfirmed by design, with one exception: flattening a mixed external
    /// structure into List can't be exactly restored, so it requires
    /// `force: true` (the UI warns first). Returns false when it declined.
    @discardableResult
    func setMode(_ mode: TmuxSessionMode, force: Bool = false) async -> Bool {
        guard usingTmux else { return false }
        if mode == .list, isMixedStructure, !force { return false }

        switch (sessionStructure, mode) {
        case (.tiled, .list), (.hierarchical, .list):
            await spreadToList()
        case (.list, .tiled), (.hierarchical, .tiled):
            await mergeToTiled()
        default:
            break   // degenerate or already in shape — presentation only
        }

        savedModePreference = mode
        _ = await tmuxService.send(.setSessionOption(name: Self.modeOption, value: mode.rawValue))
        recomputeSessionMode()
        return true
    }

    // MARK: - Grouping & naming

    /// Session panes grouped by window, in `list-panes -s` order (window
    /// order, then pane-index order within each window).
    var panesByWindow: [TmuxWindowID: [Pane]] {
        var result: [TmuxWindowID: [Pane]] = [:]
        for pane in sessionPanes {
            guard let win = pane.windowID else { continue }
            result[win, default: []].append(pane)
        }
        return result
    }

    /// Panes of one window, in pane-index order.
    func panes(in windowID: TmuxWindowID) -> [Pane] {
        sessionPanes.filter { $0.windowID == windowID }
    }

    /// The LIVE display name for a window, prefixed with tmux's own
    /// `#{window_index}` so the label reads exactly like `list-windows` and can
    /// be carried straight to `select-window -t <index>`. A single-pane window
    /// is named by its pane's title (what's actually running — auto-updated); a
    /// multi-pane window falls back to the tmux window name.
    ///
    /// The index is the honest part (it addresses the window in any tmux
    /// command); the name is the useful part (it says what's running). Showing
    /// only the derived name left users with a label that matched nothing they
    /// could type.
    func windowDisplayName(_ windowID: TmuxWindowID) -> String {
        let window = windows.first { $0.id == windowID }
        let body = windowBodyName(windowID, window: window)
        guard let index = window?.index else { return body }
        return "\(index):\(body)"
    }

    /// `windowDisplayName` without the index prefix — for places that show the
    /// index separately (or have no room for it).
    func windowBodyName(_ windowID: TmuxWindowID) -> String {
        windowBodyName(windowID, window: windows.first { $0.id == windowID })
    }

    private func windowBodyName(_ windowID: TmuxWindowID, window: TmuxWindow?) -> String {
        let winPanes = panes(in: windowID)
        let windowName = window?.name.trimmingCharacters(in: .whitespaces)
        if winPanes.count > 1 {
            return windowName.flatMap { $0.isEmpty ? nil : $0 } ?? "\(winPanes.count) panes"
        }
        let pane = winPanes.first
        return [pane?.title, pane?.currentCommand, windowName]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? "shell"
    }

    /// Aggregate agent state for a window's row/tab, highest priority first:
    /// any pane awaiting input → awaiting; else any working → working; else
    /// idle. Reads the `paneStates` cache that `updatePaneStates` fills for
    /// every session pane through the one detection pipeline — the SAME
    /// judgment that colors the Tiled pane chrome, never a separate re-run.
    /// Background windows keep reporting because control mode streams every
    /// pane's output and titles.
    func windowState(_ windowID: TmuxWindowID) -> PaneState {
        var sawWorking = false
        for pane in panes(in: windowID) {
            guard let state = paneStates[pane.id] else { continue }
            if case .awaitingInput = state { return state }
            if state == .working { sawWorking = true }
        }
        return sawWorking ? .working : .idle
    }

    /// A window's display status, richest first — the same aggregate as
    /// `windowState` PLUS the blue "done, unseen" layer, which isn't a PaneState
    /// (an agent finished its turn in a window you weren't looking at). Reads the
    /// `paneStates` / `paneDoneUnseen` caches the one pipeline fills, so it stays
    /// in lockstep with the Tiled pane chrome. Priority: awaiting → working →
    /// done → idle.
    func windowStatus(_ windowID: TmuxWindowID) -> WindowDisplayStatus {
        var sawWorking = false
        var sawDone = false
        for pane in panes(in: windowID) {
            if let state = paneStates[pane.id] {
                if case .awaitingInput = state { return .awaiting }
                if state == .working { sawWorking = true }
            }
            if paneDoneUnseen[pane.id] == true { sawDone = true }
        }
        if sawWorking { return .working }
        if sawDone { return .doneUnseen }
        return .idle
    }

    // MARK: - Creation (identical in both modes; only the landing differs)

    /// The active pane's live working directory (nil if unknown). Seeds the New
    /// Window / Split directory picker so confirming immediately reuses the
    /// current folder, or the user can navigate elsewhere.
    func activePaneWorkingDirectory() async -> String? {
        guard let id = activePaneID,
              let vm = paneViewModels.first(where: { $0.paneID == id }) else { return nil }
        return await vm.currentWorkingDirectory()
    }

    /// List mode: open a new window seeded per `seed`.
    func newListWindow(_ seed: WindowSeed) async {
        guard usingTmux else { return }
        let (path, command) = await resolveSeed(seed)
        DIAG("[DUP] newListWindow seed=\(seed) path=\(path ?? "nil") cmd=\(String(describing: command)) panesBefore=\(sessionPanes.map { "\($0.id)" }.joined(separator: ","))")
        let resp = await tmuxService.send(.newWindow(path: path, command: command))
        DIAG("[DUP] new-window resp err=\(resp.isError) out=[\(resp.output.trimmingCharacters(in: .whitespacesAndNewlines))]")
        await refreshWindows()
        await refreshPanes()
        DIAG("[DUP] newListWindow done panesAfter=\(sessionPanes.map { "\($0.id)" }.joined(separator: ",")) windows=\(windows.map { "\($0.id)" }.joined(separator: ","))")
    }

    /// Tiled mode: split the active pane, seeded per `seed` (creation parity
    /// with List — duplicate current / specify path+command).
    func splitPane(horizontal: Bool, seed: WindowSeed) async {
        guard usingTmux else { return }
        let (path, command) = await resolveSeed(seed)
        DIAG("[DUP] splitPane target=\(activePaneID.map { "\($0)" } ?? "nil") h=\(horizontal) path=\(path ?? "nil") cmd=\(String(describing: command)) panesBefore=\(sessionPanes.map { "\($0.id)" }.joined(separator: ","))")
        let resp = await tmuxService.send(.splitWindow(
            target: activePaneID, horizontal: horizontal, path: path, command: command))
        DIAG("[DUP] split-window resp err=\(resp.isError) out=[\(resp.output.trimmingCharacters(in: .whitespacesAndNewlines))]")
        await refreshPanes()
        DIAG("[DUP] splitPane done panesAfter=\(sessionPanes.map { "\($0.id)" }.joined(separator: ","))")
    }

    /// Resolve a seed to (path, command). "Duplicate current" reads the active
    /// pane's live cwd and program from tmux.
    ///
    /// Program resolution, in order:
    ///  1. `#{pane_start_command}` — the command tmux itself launched the pane
    ///     with (an Agent-wizard pane, or List's "Path & Command…"). Comes back
    ///     in tmux's own quoting → spliced VERBATIM (`.tmuxSyntax`); re-escaping
    ///     it nests the quotes and the new pane exits at once (see `SpawnCommand`).
    ///  2. If empty (the program was TYPED into a shell — the common case for an
    ///     agent), fall back to `#{pane_current_command}`, the live foreground
    ///     program, so duplicating a running claude/codex/vim relaunches IT rather
    ///     than dropping you at a bare shell. It's a plain program name (no args),
    ///     so it's shell-quoted (`.shell`).
    ///  3. A bare shell prompt (zsh/bash/…) means nothing is running → no command,
    ///     i.e. a plain shell in the same directory (no pointless nested shell).
    private func resolveSeed(_ seed: WindowSeed) async -> (String?, SpawnCommand?) {
        switch seed {
        case .custom(let path, let command):
            return (blankToNil(path), blankToNil(command).map(SpawnCommand.shell))
        case .duplicateCurrent:
            guard let pane = activePaneID else { return (nil, nil) }
            let path = await displayValue("#{pane_current_path}", pane: pane)
            if let start = await displayValue("#{pane_start_command}", pane: pane) {
                DIAG("[DUP] resolveSeed src=\(pane) start_command=[\(start)] path=[\(path ?? "nil")]")
                return (path, .tmuxSyntax(start))
            }
            let current = await displayValue("#{pane_current_command}", pane: pane)
            let cmd = current.flatMap { Self.isShellName($0) ? nil : $0 }
            DIAG("[DUP] resolveSeed src=\(pane) start=nil current=[\(current ?? "nil")] → cmd=[\(cmd ?? "nil→shell")] path=[\(path ?? "nil")]")
            return (path, cmd.map(SpawnCommand.shell))
        }
    }

    /// Whether a `#{pane_current_command}` value is just a login/interactive
    /// shell (so "duplicate" should open a plain shell, not re-run the shell as
    /// a program). tmux reports the leaf name, sometimes with a login `-` prefix.
    private static func isShellName(_ command: String) -> Bool {
        let name = command.hasPrefix("-") ? String(command.dropFirst()) : command
        return ["zsh", "bash", "sh", "fish", "dash", "tcsh", "csh", "ksh"].contains(name)
    }

    private func displayValue(_ format: String, pane: TmuxPaneID) async -> String? {
        let resp = await tmuxService.send(.displayMessage(format: format, target: pane))
        guard !resp.isError else { return nil }
        return blankToNil(resp.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func blankToNil(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }

    // MARK: - Structure transforms (internals of setMode)

    /// Server-side memory: the pre-spread structure (for merge-back) and the
    /// user's explicit mode choice.
    ///
    /// `@bento_structure` supersedes the older `@bento_orig_layout` +
    /// `@bento_pane_order` pair, which between them could only describe ONE
    /// window. Any other shape — the ordinary `N windows × M panes` a tmux user
    /// builds — took a "no save" branch, so leaving Focus collapsed the whole
    /// session into a single window with tmux's even layout. The two old
    /// options are still READ so a session spread by an earlier build can still
    /// be put back.
    private static let structureOption = "@bento_structure"
    private static let savedLayoutOption = "@bento_orig_layout"
    private static let savedOrderOption = "@bento_pane_order"
    private static let modeOption = "@bento_mode"

    /// Record the current window/pane shape so it can be rebuilt after a
    /// spread. Captures every window, including ones already holding a single
    /// pane — their names are part of the shape too.
    private func saveStructureSnapshot() async {
        let byWindow = panesByWindow
        let snapshot = TmuxStructureSnapshot(windows: windows.compactMap { window in
            let panes = byWindow[window.id] ?? []
            guard !panes.isEmpty else { return nil }
            return .init(index: window.index,
                         name: window.name,
                         layout: window.layout,
                         panes: panes.map(\.id))
        })
        guard !snapshot.windows.isEmpty, let encoded = snapshot.encoded() else {
            DIAG("[MODE] snapshot SKIPPED (no windows or encode failed)")
            return
        }
        DIAG("[MODE] snapshot SAVE \(snapshot.debugJSON)")
        dlog("[MODE] snapshot save windows=\(snapshot.windows.count) panes=\(snapshot.allPanes.count)")
        _ = await tmuxService.send(.setSessionOption(name: Self.structureOption, value: encoded))
    }

    /// The snapshot to restore from, preferring the structure record and
    /// falling back to the single-window pair written by older builds.
    private func loadStructureSnapshot() async -> TmuxStructureSnapshot? {
        if let snapshot = TmuxStructureSnapshot.decode(await readSessionOption(Self.structureOption)) {
            return snapshot
        }
        // Legacy: one layout string + a flat pane order, i.e. exactly one window.
        guard let layout = await readSessionOption(Self.savedLayoutOption), !layout.isEmpty else {
            return nil
        }
        let order = (await readSessionOption(Self.savedOrderOption))?
            .split(separator: " ")
            .compactMap { TmuxPaneID(string: String($0)) } ?? []
        guard !order.isEmpty else { return nil }
        DIAG("[MODE] snapshot LEGACY layout=[\(layout)] order=\(order.map { "\($0)" }.joined(separator: ","))")
        return TmuxStructureSnapshot(windows: [
            .init(index: nil, name: "", layout: layout, panes: order)
        ])
    }

    private func clearStructureSnapshot() async {
        _ = await tmuxService.send(.setSessionOption(name: Self.structureOption, value: ""))
        _ = await tmuxService.send(.setSessionOption(name: Self.savedLayoutOption, value: ""))
        _ = await tmuxService.send(.setSessionOption(name: Self.savedOrderOption, value: ""))
    }

    /// tiled → list: break every pane out into its own window (processes
    /// untouched), after recording the shape so merging back can rebuild it.
    ///
    /// The snapshot covers every window unconditionally. Previously it was
    /// written only when the session happened to be a single multi-pane window;
    /// every other shape took a "no save" branch and could not be restored, so
    /// a user who had arranged three windows got one window back.
    @discardableResult
    internal func spreadToList() async -> Bool {
        guard usingTmux else { return false }
        await refreshWindows()
        await refreshPanes()
        let byWindow = panesByWindow
        let multiPane = byWindow.filter { $0.value.count > 1 }
        guard !multiPane.isEmpty else { return false }

        await saveStructureSnapshot()

        for (_, winPanes) in multiPane {
            // Break all but the first, deliberately WITHOUT `-n`.
            //
            // This used to name each new window after the pane's title at that
            // instant, which looked harmless — the comment even said "compat
            // only". It isn't: naming a window explicitly makes tmux turn
            // `automatic-rename` OFF for it forever. The name froze at whatever
            // the agent's OSC title happened to say mid-spread, stopped tracking
            // what was running, and survived the merge back onto the window that
            // became the base — so the toolbar ended up showing a title that
            // matched no pane in it. Left alone, tmux keeps renaming from the
            // running command, and a name the USER types (sidebar → Rename
            // Window…) still sticks, which is tmux's own rule.
            for pane in winPanes.dropFirst() {
                let resp = await tmuxService.send(.breakPane(source: pane.id))
                if resp.isError { dlog("spreadToList: break-pane \(pane.id) failed: \(resp.output)") }
            }
        }

        await refreshWindows()
        await refreshPanes()
        return true
    }

    /// Leaving Focus: put the remembered shape back.
    ///
    /// "Back" means whatever was captured, which may be several windows — a
    /// mixed structure is a shape a tmux user builds on purpose, not a foreign
    /// object to be flattened. With nothing remembered (or nothing of it left
    /// alive) this falls back to the historical behavior of gathering every
    /// pane into one window.
    @discardableResult
    internal func mergeToTiled() async -> Bool {
        guard usingTmux else { return false }
        await refreshWindows()
        await refreshPanes()
        guard panesByWindow.count > 1 else { return false }

        let live = sessionPanes.compactMap { $0.windowID != nil ? $0.id : nil }
        let snapshot = await loadStructureSnapshot()

        // Exactly one remembered window is the classic Parallel shape. Keep the
        // long-debugged path for it: the layout TREE is edited to match reality
        // so survivors land back in their exact cells and panes created while in
        // Focus are folded in. With several windows there is no single obvious
        // home for a newcomer, so unknown panes are left in their own window
        // rather than being pushed somewhere arbitrary.
        if let windows = snapshot?.windows, windows.count > 1 {
            let plan = snapshot!.restorePlan(livePanes: Set(live))
            if !plan.isEmpty {
                DIAG("[MODE] restoreStructure windows=\(plan.count) live=[\(live.map { "\($0)" }.joined(separator: ","))]")
                for step in plan { await rebuildWindow(step) }
                await clearStructureSnapshot()
                await refreshWindows()
                await refreshPanes()
                return true
            }
        }

        let remembered = snapshot?.windows.count == 1 ? snapshot?.windows.first : nil
        let savedLayout = remembered?.layout
        let savedOrder = remembered?.panes ?? []

        // Edit the remembered layout tree to the live pane set.
        var tree = savedLayout.flatMap { TmuxLayoutTree.parse($0) }
        if var t = tree {
            let liveRaw = Set(live.map(\.raw))
            for gone in savedOrder where !liveRaw.contains(gone.raw) {
                t = TmuxLayoutTree.removing(pane: gone.raw, from: t) ?? t
            }
            for newcomer in live where !savedOrder.contains(newcomer) {
                t = TmuxLayoutTree.inserting(pane: newcomer.raw, into: t)
            }
            // Sanity: the edited tree must hold exactly the live panes.
            let leaves = Set(TmuxLayoutTree.leafOrder(of: t))
            tree = leaves == liveRaw ? t : nil
            if tree == nil {
                DIAG("[MODE] mergeToTiled TREE-NIL leaves=[\(leaves.sorted().map(String.init).joined(separator: ","))] live=[\(liveRaw.sorted().map(String.init).joined(separator: ","))] — will fall back to even 'tiled'")
            }
        }
        DIAG("[MODE] mergeToTiled savedLayout=[\(savedLayout ?? "nil")] savedOrder=[\(savedOrder.map { "\($0)" }.joined(separator: ","))] live=[\(live.map { "\($0)" }.joined(separator: ","))]")
        dlog("[MODE] merge savedLayout=[\(savedLayout?.prefix(90) ?? "nil")] treeNil=\(tree == nil) savedOrder=\(savedOrder.count) live=\(live.count)")   // BUG-005 device diag

        // Join in the tree's leaf order (or saved-then-newcomers without one).
        let ordered: [TmuxPaneID]
        if let tree {
            ordered = TmuxLayoutTree.leafOrder(of: tree).compactMap { raw in
                live.first { $0.raw == raw }
            }
        } else {
            var o = savedOrder.filter { live.contains($0) }
            o += live.filter { !o.contains($0) }
            ordered = o
        }
        guard let base = ordered.first else { return false }

        // All panes merge INTO base's window. `join-pane -t prev` splits its
        // target IN HALF; a naive chain advances prev to each freshly-joined
        // pane, so successive targets shrink geometrically (½, ¼, ⅛…) and past
        // ~5-6 panes the target is below tmux's minimum pane size → join-pane is
        // refused ("create pane failed: pane too small") and the pane is stranded
        // in its own window. That geometric shrink — not any device-size cap — is
        // the ~5 "Parallel pane limit". Fix: even the window out
        // (`select-layout tiled`) after each join to reclaim the space, and retry
        // once on failure, so as many panes as the window TRULY fits merge into
        // one (the real, device-size limit tmux computes from the dimensions).
        // `prev` only advances to panes actually IN base's window, so a genuine
        // overflow (more panes than physically fit) stays as its own window
        // rather than scattering into a second multi-pane window. The final saved
        // layout (below) overwrites these intermediate even layouts.
        let baseWin = sessionPanes.first(where: { $0.id == base })?.windowID
        var prev = base
        for pane in ordered.dropFirst() {
            var resp = await tmuxService.send(.joinPane(source: pane, target: prev))
            if resp.isError, let win = baseWin {
                _ = await tmuxService.send(.selectLayout(window: win, layout: "tiled"))
                resp = await tmuxService.send(.joinPane(source: pane, target: prev))
            }
            if resp.isError {
                // Genuinely doesn't fit (or "can't join a pane to its own window"
                // in a mixed merge) — leave it in its own window; keep prev on a
                // base-window pane so the next join still targets base's window.
                dlog("mergeToTiled: join-pane \(pane): \(resp.output)")
                DIAG("[MODE] mergeToTiled join-pane \(pane) → \(prev) FAILED: \(resp.output.trimmingCharacters(in: .whitespacesAndNewlines)) — left in its own window (overflow past device fit)")
            } else {
                // Reclaim space so the NEXT chain-split has room.
                if let win = baseWin { _ = await tmuxService.send(.selectLayout(window: win, layout: "tiled")) }
                prev = pane
            }
        }

        await refreshPanes()
        if let baseWin = sessionPanes.first(where: { $0.id == base })?.windowID {
            let layout = tree.map(TmuxLayoutTree.serialize) ?? "tiled"
            let resp = await tmuxService.send(.selectLayout(window: baseWin, layout: layout))
            DIAG("[MODE] mergeToTiled select-layout win=\(baseWin) layout=[\(layout)] err=\(resp.isError) out=[\(resp.output.trimmingCharacters(in: .whitespacesAndNewlines))]")
            dlog("[MODE] merge select-layout err=\(resp.isError) applied=[\(layout.prefix(90))] out=[\(resp.output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))]")   // BUG-005 device diag
        } else {
            DIAG("[MODE] mergeToTiled NO baseWin for base=\(base) — layout not applied")
        }
        await clearStructureSnapshot()

        await refreshWindows()
        await refreshPanes()
        return true
    }

    /// Join one remembered window's panes back together and re-apply its saved
    /// geometry. A step with nothing to join is already in shape (it was a
    /// single-pane window before the spread too), so it is left untouched —
    /// notably it is NOT renamed: `rename-window` turns tmux's
    /// `automatic-rename` off for that window, which would quietly freeze names
    /// that used to track what's running.
    ///
    /// `join-pane -t prev` splits its target IN HALF; a naive chain advances
    /// `prev` to each freshly-joined pane, so successive targets shrink
    /// geometrically (½, ¼, ⅛…) and past ~5-6 panes the target is below tmux's
    /// minimum pane size → join-pane is refused ("create pane failed: pane too
    /// small") and the pane is stranded. That geometric shrink — not any
    /// device-size cap — was the ~5 "Parallel pane limit". Evening the window out
    /// after each join reclaims the space; a retry covers the boundary case. A
    /// pane that genuinely doesn't fit stays in its own window, and `prev` stays
    /// on a pane that IS in the base window so the next join still targets it.
    private func rebuildWindow(_ step: TmuxStructureSnapshot.RestoreStep) async {
        guard !step.join.isEmpty else { return }
        await refreshPanes()
        let baseWin = sessionPanes.first(where: { $0.id == step.base })?.windowID
        var prev = step.base
        for pane in step.join {
            var resp = await tmuxService.send(.joinPane(source: pane, target: prev))
            if resp.isError, let win = baseWin {
                _ = await tmuxService.send(.selectLayout(window: win, layout: "tiled"))
                resp = await tmuxService.send(.joinPane(source: pane, target: prev))
            }
            if resp.isError {
                dlog("restoreStructure: join-pane \(pane): \(resp.output)")
                DIAG("[MODE] restore join-pane \(pane) → \(prev) FAILED: \(resp.output.trimmingCharacters(in: .whitespacesAndNewlines)) — left in its own window")
            } else {
                if let win = baseWin {
                    _ = await tmuxService.send(.selectLayout(window: win, layout: "tiled"))
                }
                prev = pane
            }
        }
        await refreshPanes()
        guard let win = sessionPanes.first(where: { $0.id == step.base })?.windowID else {
            DIAG("[MODE] restore NO window for base=\(step.base) — layout not applied")
            return
        }
        // nil layout means a pane died, so the saved geometry no longer fits its
        // pane count and tmux would reject it — even out instead.
        let layout = step.layout ?? "tiled"
        let resp = await tmuxService.send(.selectLayout(window: win, layout: layout))
        DIAG("[MODE] restore select-layout win=\(win) name=[\(step.name)] layout=[\(layout)] err=\(resp.isError) out=[\(resp.output.trimmingCharacters(in: .whitespacesAndNewlines))]")
    }

    // MARK: - Window sizing authority

    static let sizeOwnerOption = "@bento_size_owner"

    /// This client's tmux client name (its tty). Cached per attach — it changes
    /// every time we re-attach, which is exactly why ownership has to be
    /// re-claimed on attach rather than assumed.
    func currentClientName() async -> String? {
        if let cached = myTmuxClientName { return cached }
        let resp = await tmuxService.send(.displayMessage(format: "#{client_name}", target: nil))
        guard !resp.isError else { return nil }
        let name = resp.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        myTmuxClientName = name
        return name
    }

    private func attachedClientNames() async -> Set<String> {
        let resp = await tmuxService.send(.listClients)
        guard !resp.isError else { return [] }
        // `#{client_name}:#{client_session}` — the name may itself contain no
        // colon (it's a tty path), so split off the trailing session field.
        return Set(resp.output
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard let cut = line.lastIndex(of: ":") else { return nil }
                let name = String(line[line.startIndex..<cut])
                return name.isEmpty ? nil : name
            })
    }

    /// Adopt the sizing policy that is already on the server, and reconcile
    /// ownership. Runs on every attach INSTEAD of writing a local preference:
    /// re-asserting one is what let each device silently undo the other's
    /// choice (an iPad reconnect issued `window-size latest` every ~50s and
    /// wiped a pin made on the Mac).
    ///
    /// Reconciliation has exactly three outcomes:
    ///   - the recorded owner is still attached → adopt, and don't touch it;
    ///   - the owner is gone but WE are the device that claimed it → re-claim
    ///     under our new client name (our name changes on every re-attach);
    ///   - the owner is gone and isn't us → release to `latest`, so a device
    ///     that walked away can never hold the session hostage.
    func adoptSizingPolicy() async {
        guard usingTmux else { return }
        myTmuxClientName = nil
        let me = await currentClientName()

        let raw = await readWindowOption("window-size") ?? ""
        var mode = TerminalSizingMode.fromTmuxWindowSize(raw) ?? .tracking
        var owner = TmuxSizingOwner(encoded: await readSessionOption(Self.sizeOwnerOption) ?? "")

        if mode == .thisDevice {
            let attached = await attachedClientNames()
            let ownerPresent = owner.map { attached.contains($0.client) } ?? false
            if !ownerPresent {
                if claimedSizeOwnership, let me {
                    let claim = TmuxSizingOwner(client: me, label: BentoDeviceLabel.current)
                    owner = claim
                    _ = await tmuxService.send(
                        .setSessionOption(name: Self.sizeOwnerOption, value: claim.encoded))
                    dlog("sizing: re-claimed ownership as \(me)")
                } else {
                    dlog("sizing: owner \(owner?.client ?? "none") is gone — releasing to latest")
                    owner = nil
                    mode = .tracking
                    _ = await tmuxService.send(.setSessionOption(name: Self.sizeOwnerOption, value: ""))
                    _ = await tmuxService.send(
                        .setWindowOption(name: "window-size", value: TerminalSizingMode.tracking.tmuxWindowSize))
                }
            }
        } else if claimedSizeOwnership {
            // Someone moved the session off manual; our claim is stale.
            claimedSizeOwnership = false
        }

        sizingMode = mode
        sizingOwner = owner
        if let session = activeTmuxSessionName { TerminalSizingMode.store(mode, for: session) }
        // The owner re-asserts its grid on attach: it may have rotated or
        // changed font size while detached, and under `manual` nothing else
        // would ever correct the window.
        if mode == .thisDevice, sizingOwnerIsMe {
            await pushOwnedWindowSize()
        }
    }

    /// Put the session's sizing policy into tmux, so the choice survives this
    /// client going away and holds against other attached clients. All three
    /// cases are just tmux's own `window-size`; `.thisDevice` additionally
    /// records who claimed it, because `manual` alone says "nobody derives the
    /// size from clients" without saying whose size it is.
    @discardableResult
    public func applySizingMode(_ mode: TerminalSizingMode) async -> Bool {
        guard usingTmux else { return false }
        let resp = await tmuxService.send(
            .setWindowOption(name: "window-size", value: mode.tmuxWindowSize))
        if resp.isError {
            dlog("applySizingMode \(mode.rawValue): \(resp.output)")
            return false
        }
        switch mode {
        case .tracking, .smallest:
            claimedSizeOwnership = false
            sizingOwner = nil
            _ = await tmuxService.send(.setSessionOption(name: Self.sizeOwnerOption, value: ""))
        case .thisDevice:
            guard let me = await currentClientName() else {
                dlog("applySizingMode thisDevice: no client name — cannot claim ownership")
                return false
            }
            let claim = TmuxSizingOwner(client: me, label: BentoDeviceLabel.current)
            claimedSizeOwnership = true
            sizingOwner = claim
            _ = await tmuxService.send(
                .setSessionOption(name: Self.sizeOwnerOption, value: claim.encoded))
            await pushOwnedWindowSize()
        }
        return true
    }

    /// Resize the window to this device's grid. Only meaningful under `manual`
    /// — under any client-derived policy tmux recomputes the size immediately
    /// and this is a no-op (the original "Fit Session to This Window" bug).
    func pushOwnedWindowSize() async {
        guard let window = windows.first(where: { $0.id == activeWindowID }) ?? windows.first
        else { return }
        // Prefer the grid this device last measured; fall back to the window's
        // current size so claiming ownership never resizes anything by itself
        // (that is what a plain freeze should do).
        var size = lastTmuxClientSize
        if size == nil { size = await currentWindowSize(window.id) }
        guard let size else {
            dlog("pushOwnedWindowSize: no size to apply")
            return
        }
        let resp = await tmuxService.send(
            .resizeWindow(window: window.id, width: size.cols, height: size.rows))
        if resp.isError { dlog("pushOwnedWindowSize: \(resp.output)") }
    }

    /// tmux told us a client detached (`%client-detached`). If it was the one
    /// owning the size, release the session back to `latest` so the remaining
    /// devices are not left clamped to a device that is no longer here. This is
    /// the whole reason ownership is keyed by tmux client name: no heartbeat,
    /// no polling, and no way to leak an owner.
    func handleClientDetached(_ client: String) {
        guard sizingMode == .thisDevice, let owner = sizingOwner, owner.client == client else { return }
        // It can be OUR OWN previous client: a reconnect gets a new tty, and
        // tmux may only reap the old one after we're back. That is this device
        // still owning the size, not the owner walking away — re-claim under
        // the new name instead of handing the session to whoever is left.
        if claimedSizeOwnership {
            dlog("sizing: our previous client \(client) detached — re-claiming")
            Task { [weak self] in
                guard let self, let me = await self.currentClientName() else { return }
                let claim = TmuxSizingOwner(client: me, label: BentoDeviceLabel.current)
                self.sizingOwner = claim
                _ = await self.tmuxService.send(
                    .setSessionOption(name: Self.sizeOwnerOption, value: claim.encoded))
            }
            return
        }
        dlog("sizing: owner \(client) detached — releasing to latest")
        sizingOwner = nil
        claimedSizeOwnership = false
        sizingMode = .tracking
        if let session = activeTmuxSessionName {
            TerminalSizingMode.store(.tracking, for: session)
        }
        Task { [weak self] in
            guard let self else { return }
            _ = await self.tmuxService.send(.setSessionOption(name: Self.sizeOwnerOption, value: ""))
            _ = await self.tmuxService.send(
                .setWindowOption(name: "window-size", value: TerminalSizingMode.tracking.tmuxWindowSize))
            self.resetTmuxClientToDeviceSize()
        }
    }

    private func readWindowOption(_ name: String) async -> String? {
        let resp = await tmuxService.send(.showWindowOption(name: name))
        guard !resp.isError else { return nil }
        let value = resp.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func currentWindowSize(_ windowID: TmuxWindowID) async -> (cols: Int, rows: Int)? {
        let resp = await tmuxService.send(
            .displayMessage(format: "#{window_width}x#{window_height}", target: nil))
        guard !resp.isError else { return nil }
        let parts = resp.output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "x")
        guard parts.count == 2, let cols = Int(parts[0]), let rows = Int(parts[1]) else { return nil }
        return (cols, rows)
    }

    /// Apply one of tmux's named layouts (`even-horizontal`, `main-vertical`,
    /// `tiled`, …) to a window. Bento's own tiling reads the result back from
    /// `%layout-change`, so this is tmux rearranging its own window rather than
    /// Bento imposing geometry — a layout the user sets from a tmux command
    /// line lands exactly the same way.
    @discardableResult
    public func applyWindowLayout(_ windowID: TmuxWindowID, layout: String) async -> Bool {
        guard usingTmux else { return false }
        let resp = await tmuxService.send(.selectLayout(window: windowID, layout: layout))
        if resp.isError {
            dlog("applyWindowLayout \(layout) failed: \(resp.output)")
            return false
        }
        await refreshPanes()
        return true
    }

    /// Move a pane out of this session into `target`. The pane's process and
    /// scrollback travel untouched — pane IDs are server-global. The LANDING
    /// respects the target's mode (see `moveToSession`): a Parallel target
    /// absorbs it into its current window, a Focus target gets a new window,
    /// an unsettled target returns `.needsLandingChoice` so the UI can ask.
    /// Creates the target session when it doesn't exist yet ("New Session…"
    /// funnels through here), and kills the fresh session's placeholder
    /// shell window afterwards so the target holds exactly the moved pane.
    ///
    /// Moving the session's LAST pane is the hero merge scenario (two
    /// wind-down sessions, one agent each), and it would destroy the source
    /// session under this client — so the client FOLLOWS: switch-client to
    /// the target first, then move. The source dies quietly behind us and
    /// the view is already where the pane lands. Otherwise the client stays
    /// put and only stops streaming the departed pane (%layout-change /
    /// %window-close retire the surface through the external-change path).
    @discardableResult
    func movePane(_ paneID: TmuxPaneID, toSession target: String,
                  landing: MoveLanding = .auto) async -> MoveResult {
        // No `-n`, same reason as spreadToList: an explicit name is what turns
        // tmux's automatic-rename off, and a frozen title is worse than a
        // generic live one.
        return await moveToSession(
            target, isLast: sessionPanes.count <= 1, landing: landing,
            kind: "movePane \(paneID)",
            join: { await self.tmuxService.send(.joinPaneToSession(source: paneID, session: $0)) },
            asWindow: { await self.tmuxService.send(
                .breakPane(source: paneID, targetSession: $0)) })
    }

    /// Move a whole window into another session: the Focus/List window row's
    /// counterpart of `movePane`, with the same landing rules — a Focus
    /// window IS one pane, so a Parallel target absorbs that pane into its
    /// current window. A multi-pane window (external/mixed structures only)
    /// always travels intact as a window — joining would need a layout
    /// rebuild in the target, so its landing is never asked about.
    @discardableResult
    func moveWindow(_ windowID: TmuxWindowID, toSession target: String,
                    landing: MoveLanding = .auto) async -> MoveResult {
        let winPanes = panes(in: windowID)
        let soleID = winPanes.count == 1 ? winPanes.first?.id : nil
        return await moveToSession(
            target, isLast: windows.count <= 1,
            landing: soleID == nil ? .newWindow : landing,
            kind: "moveWindow \(windowID)",
            join: { session in
                guard let soleID else { fatalError("join without a sole pane") }
                return await self.tmuxService.send(
                    .joinPaneToSession(source: soleID, session: session))
            },
            asWindow: { await self.tmuxService.send(.moveWindow(id: windowID, targetSession: $0)) })
    }

    /// Shared plumbing for the two moves: create-if-missing, resolve the
    /// landing from the target's shape, follow when the source would die,
    /// run the move, clean a fresh target's placeholder, resync.
    ///
    /// Landing resolution (`.auto`): a fresh-created target always takes the
    /// window path (its placeholder is killed after, leaving exactly the
    /// moved content). An existing target is probed server-side — Parallel
    /// shape → `join` into its current window, Focus shape → `asWindow`,
    /// unsettled (degenerate with no remembered mode, or a mixed external
    /// structure) → return `.needsLandingChoice` WITHOUT moving anything so
    /// the UI can ask and call again with an explicit landing. A join the
    /// target genuinely can't fit (pane too small even after re-tiling)
    /// falls back to the window path rather than failing.
    private func moveToSession(_ target: String,
                               isLast: Bool,
                               landing: MoveLanding,
                               kind: String,
                               join: (String) async -> TmuxCommandResponse,
                               asWindow: (String) async -> TmuxCommandResponse) async -> MoveResult {
        let name = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard usingTmux, !name.isEmpty, name != activeTmuxSessionName else { return .failed }

        let created: Bool
        switch await ensureSessionExists(name) {
        case .failed: return .failed
        case .created: created = true
        case .existed: created = false
        }

        var resolved = landing
        if created {
            resolved = .newWindow
        } else if landing == .auto {
            switch await probeSessionShape(name) {
            case .tiled: resolved = .joinCurrentWindow
            case .list: resolved = .newWindow
            case .unsettled: return .needsLandingChoice
            }
        }

        // Source about to die → follow BEFORE the move, while this client
        // still has a session under it. (Commands can target any session on
        // the server; only output streaming is bound to the attached one.)
        if isLast {
            let resp = await tmuxService.send(.switchClient(session: name))
            if resp.isError {
                dlog("\(kind): switch-client \(name) failed: \(resp.output)")
                return .failed
            }
        }

        var landedAsJoin = false
        if resolved == .joinCurrentWindow {
            var resp = await join(name)
            if resp.isError {
                // Same failure mode as mergeToTiled: the active pane may be
                // too small to split. Even the window out and retry once.
                _ = await tmuxService.send(.selectLayoutTarget(target: "\(name):", layout: "tiled"))
                resp = await join(name)
            }
            landedAsJoin = !resp.isError
            if resp.isError {
                dlog("\(kind): join → \(name) refused (\(resp.output)) — landing as window")
            }
        }
        if !landedAsJoin {
            let resp = await asWindow(name)
            if resp.isError {
                dlog("\(kind): move → \(name) failed: \(resp.output)")
                return .failed
            }
        }
        // A fresh session was born with a placeholder shell window; now that
        // the real content has landed beside it, drop it (`^` = the lowest
        // index). Only for sessions WE just created — never prune existing.
        if created {
            _ = await tmuxService.send(.killWindowTarget("\(name):^"))
        }
        DIAG("[MODE] \(kind) → session '\(name)' landing=\(landedAsJoin ? "join" : "window") follow=\(isLast) created=\(created)")

        await refreshWindows()
        await refreshPanes()
        await refreshTmuxSessions()   // warm the list for the next menu open
        return .moved
    }

    /// The target session's shape, probed server-side (we're not attached to
    /// it, but commands reach any session): the same reading
    /// `recomputeSessionMode` does locally — structure decides, and only the
    /// degenerate 1×1 falls back to the remembered `@bento_mode`.
    private enum TargetShape { case tiled, list, unsettled }
    private func probeSessionShape(_ name: String) async -> TargetShape {
        let resp = await tmuxService.send(.listPanes(target: name, sessionWide: true))
        guard !resp.isError else { return .unsettled }
        var byWindow: [TmuxWindowID: Int] = [:]
        for pane in TmuxParsers.parsePaneList(resp.output) {
            guard let win = pane.windowID else { continue }
            byWindow[win, default: 0] += 1
        }
        guard !byWindow.isEmpty else { return .unsettled }   // parse noise
        if byWindow.count == 1 {
            if (byWindow.values.first ?? 0) > 1 { return .tiled }
            // Degenerate 1×1: only an explicit remembered choice decides.
            switch await readSessionOption(Self.modeOption, target: name) {
            case TmuxSessionMode.tiled.rawValue: return .tiled
            case TmuxSessionMode.list.rawValue: return .list
            default: return .unsettled
            }
        }
        return byWindow.values.contains { $0 > 1 } ? .unsettled : .list
    }

    private enum EnsureSession { case existed, created, failed }

    /// Create `name` server-side when the cached session list doesn't know
    /// it. Tolerates a stale cache: "duplicate session" means the target
    /// exists after all, which is exactly what the move needs.
    private func ensureSessionExists(_ name: String) async -> EnsureSession {
        guard !availableTmuxSessions.contains(name) else { return .existed }
        let resp = await tmuxService.send(.newSession(name: name))
        if resp.isError {
            // A duplicate just means the cache was stale — treat as existing.
            return resp.output.contains("duplicate session") ? .existed : .failed
        }
        return .created
    }

    /// Read a session option's value; nil when unset/empty. `show-options -qv`
    /// prints the bare value (quoted only if it contains spaces — strip that).
    /// `target` reads another session's option (nil = the attached session).
    private func readSessionOption(_ name: String, target: String? = nil) async -> String? {
        let resp = await tmuxService.send(.showSessionOption(target: target, name: name))
        guard !resp.isError else { return nil }
        var value = resp.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }
}
