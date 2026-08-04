import Foundation

/// How a new window/pane's program reaches tmux. Two creation seeds need two
/// different escapings, and conflating them silently kills the pane:
///
///   • `.shell` — a user-typed command line ("Path & Command…"). Shell-quoted
///     so tmux runs it via `/bin/sh -c`, i.e. pipes, `&&`, and globs behave as
///     the user typed them.
///   • `.tmuxSyntax` — a value ALREADY in tmux's own command syntax, the
///     canonical source being `#{pane_start_command}` ("Duplicate Current" in
///     both List and Tiled). tmux stringifies a pane's argv with its own
///     quoting — `sleep 300` comes back as `"sleep 300"` — so it must be
///     spliced back VERBATIM. Wrapping that in our single quotes (as generic
///     arg-escaping would) makes the double-quotes literal; tmux then tries to
///     exec a program named `sleep 300`, exec fails, and the freshly-opened
///     window vanishes the instant it appears.
public enum SpawnCommand: Sendable, Equatable {
    /// A user-typed command line — shell-quoted, run through `/bin/sh -c`.
    case shell(String)
    /// A value already in tmux command syntax (e.g. `#{pane_start_command}`)
    /// — spliced onto the wire verbatim.
    case tmuxSyntax(String)
}

/// Type-safe builder for tmux commands sent over control mode (`tmux -CC`).
/// Convert to a wire string via `commandString`; the control-mode service
/// appends the trailing newline.
public enum TmuxCommand: Sendable {
    // Session
    case newSession(name: String? = nil, groupWith: String? = nil)
    case listSessions

    // Window
    /// `path`/`command` seed the new window's working directory and program
    /// (List mode's "duplicate current" / "specify path+command" creation).
    case newWindow(target: String? = nil, name: String? = nil, path: String? = nil, command: SpawnCommand? = nil)
    case listWindows(target: String? = nil)
    case selectWindow(id: TmuxWindowID)
    case renameWindow(id: TmuxWindowID, name: String)
    case killWindow(id: TmuxWindowID)
    /// Kill a window addressed by a raw tmux target (e.g. `sess:^` — the
    /// session's lowest-index window, the placeholder a fresh `new-session`
    /// spawns before a moved pane lands next to it).
    case killWindowTarget(String)
    /// Rename the client's currently-attached session (no `-t` → current).
    case renameSession(name: String)

    // Pane
    /// `path` overrides the inherited working directory; `command` runs a
    /// program instead of a shell (Tiled's creation parity with List).
    case splitWindow(target: TmuxPaneID? = nil, horizontal: Bool, path: String? = nil, command: SpawnCommand? = nil)
    case selectPane(id: TmuxPaneID)
    /// Set a pane's title (`pane_title`), what the UI shows in the pane title bar
    /// and List rows. Note: a foreground TUI can overwrite this via OSC.
    case setPaneTitle(id: TmuxPaneID, title: String)
    /// `sessionWide` lists every pane in the session (`-s`), not just the
    /// current window's — the cross-window model's primary listing.
    case listPanes(target: String? = nil, allWindows: Bool = false, sessionWide: Bool = false)
    /// Break a pane out into its own window (`break-pane -d`): the pane and its
    /// process move unchanged; `-d` keeps the client's current window. The
    /// tiled→list structure op. `targetSession` lands the window in ANOTHER
    /// session (`-t 'name:'` — the empty window part means "next free index");
    /// pane IDs are server-global, so the pane keeps its identity across the
    /// move, but this client stops streaming it once it leaves the session.
    case breakPane(source: TmuxPaneID, name: String? = nil, targetSession: String? = nil)
    /// Move a whole (single-pane) window's pane into the target pane's window
    /// (`join-pane -d`), splitting after the target. The list→tiled structure
    /// op: chain with each pane targeting the previous to rebuild exact order.
    case joinPane(source: TmuxPaneID, target: TmuxPaneID)
    /// Re-split `target` and move `source` into the new half (`move-pane`):
    /// the drop-zone drag's edge landing. Same operation as join-pane but
    /// legal WITHIN one window (join-pane refuses "can't join a pane to its
    /// own window", and Tiled mode is exactly one window — move-pane exists
    /// for this, tmux ≥3.1). `horizontal` picks the split axis like
    /// split-window (-h = side by side, -v = stacked); `before` (-b) docks
    /// the moved pane on the left/top instead of the right/bottom. No -d:
    /// the pane the user dragged lands focused.
    case movePane(source: TmuxPaneID, target: TmuxPaneID, horizontal: Bool, before: Bool)
    /// Move a whole window into ANOTHER session (`move-window -d -t 'name:'`
    /// — the empty window part means "next free index"). Layout, panes, and
    /// window name travel intact; `-d` leaves it unselected at the destination.
    case moveWindow(id: TmuxWindowID, targetSession: String)
    /// Join a pane into ANOTHER session's current window, splitting its
    /// active pane (`join-pane -d -s %5 -t 'name:'`) — the Parallel landing
    /// of a cross-session move. A source session left empty dies (verified).
    case joinPaneToSession(source: TmuxPaneID, session: String)
    /// select-layout by raw target (e.g. `sess:` = that session's current
    /// window) — reclaims space before retrying a refused cross-session join.
    case selectLayoutTarget(target: String, layout: String)
    /// Set a session-scoped (user) option, e.g. `@bento_orig_layout`. Server-side
    /// storage that survives client disconnects and app restarts.
    case setSessionOption(target: String? = nil, name: String, value: String)
    /// Set a WINDOW option (`set-option -w`), e.g. `window-size`. Window
    /// options are a separate namespace from session options — setting
    /// `window-size` without `-w` lands on the wrong table.
    case setWindowOption(window: TmuxWindowID? = nil, name: String, value: String)
    /// `resize-window -x/-y`. Only takes effect under `window-size manual`;
    /// under the default `latest` the size is recomputed from whichever client
    /// was used most recently and this is immediately undone.
    case resizeWindow(window: TmuxWindowID? = nil, width: Int, height: Int)
    /// Read a session-scoped option's value (`-qv`: value only, silent when unset).
    case showSessionOption(target: String? = nil, name: String)
    /// Read a WINDOW option's value (`show-options -wqv`), e.g. `window-size`.
    /// The sizing policy lives on the server, so this is how a client that just
    /// attached learns what another device already decided — reading it beats
    /// re-asserting a local preference, which is what let each attach clobber
    /// the other device's choice.
    case showWindowOption(window: TmuxWindowID? = nil, name: String)
    case killPane(id: TmuxPaneID)
    /// Swap a pane with the previous/next pane in the window (`swap-pane -U/-D`).
    case swapPaneUp(id: TmuxPaneID)
    case swapPaneDown(id: TmuxPaneID)
    /// Swap two specific panes (`swap-pane -s ... -t ...`); used by drag-to-swap.
    case swapPanes(source: TmuxPaneID, destination: TmuxPaneID)
    case killSession(name: String? = nil)
    /// Capture a pane's text. `lines == nil` captures only the live visible
    /// screen (no scrollback) — what status detection wants, since stale prompt
    /// text in scrollback must not trigger a false "blocked". A positive `lines`
    /// captures that many lines up from the bottom (incl. scrollback). `escapes`
    /// keeps SGR color codes (off by default → clean text for matching).
    case capturePane(id: TmuxPaneID, lines: Int? = 10, escapes: Bool = false)
    case resizePane(id: TmuxPaneID, width: Int, height: Int)
    case zoomPane(id: TmuxPaneID)
    /// Resize pane by N cells. `direction` is one of `"L"`, `"R"`, `"U"`, `"D"`.
    case resizePaneBy(id: TmuxPaneID, direction: String, amount: Int)

    // Input
    case sendKeys(pane: TmuxPaneID, keys: String, literal: Bool = true)

    /// Drive a pane that tmux has put in a mode (copy-mode). `send-keys -X`
    /// speaks copy-mode COMMANDS rather than keys, so it works whatever key
    /// table (vi / emacs) the user configured — sending a literal `q` or `Up`
    /// would depend on their bindings. `count` maps to `-N`, tmux's repeat.
    ///
    /// Bento does not implement copy-mode; this exists so a pane that entered it
    /// from OUTSIDE (another client, a script, the user's own binding) is not a
    /// frozen rectangle — it can still be scrolled and dismissed.
    case copyModeCommand(pane: TmuxPaneID, command: String, count: Int? = nil)

    /// Read a paste buffer's contents. The bridge behind `%paste-buffer-changed`:
    /// a program that copied via tmux (`load-buffer -w`) put its text HERE, and
    /// a control-mode client can only get it by asking.
    case showBuffer(name: String)

    // Info
    case displayMessage(format: String, target: TmuxPaneID? = nil)
    case listClients

    // Layout
    case selectLayout(window: TmuxWindowID, layout: String)

    // Client
    case refreshClient(width: Int, height: Int)
    /// Switch the attached control client to another session on the same server
    /// (tmux emits %session-changed, which re-syncs windows/panes).
    case switchClient(session: String)

    /// Build the tmux command string (without trailing newline).
    public var commandString: String {
        switch self {
        case .newSession(let name, let groupWith):
            var cmd = "new-session -d"
            if let group = groupWith {
                cmd += " -t \(escapeArg(group))"
            }
            if let name {
                cmd += " -s \(escapeArg(name))"
            }
            return cmd

        case .listSessions:
            return "list-sessions -F '#{session_id}:#{session_name}'"

        case .newWindow(let target, let name, let path, let command):
            var cmd = "new-window"
            if let target { cmd += " -t \(escapeArg(target))" }
            if let name { cmd += " -n \(escapeArg(name))" }
            if let path { cmd += " -c \(escapeArg(path))" }
            if let frag = spawnFragment(command) { cmd += " \(frag)" }
            return cmd

        case .listWindows(let target):
            // window_name is free text (titles like "host:~/dir" carry colons),
            // so it MUST be the last field — otherwise a colon in the name shifts
            // every later field and corrupts window_layout (which Bento saves for
            // the Tiled⇄List restore). The fixed fields (id/active/layout) have no
            // colons and come first; parseWindowList splits with maxSplits 3.
            var cmd = "list-windows -F '#{window_id}:#{window_index}:#{window_active}:#{window_layout}:#{window_name}'"
            if let target { cmd += " -t \(escapeArg(target))" }
            return cmd

        case .selectWindow(let id):
            return "select-window -t \(id)"

        case .renameWindow(let id, let name):
            return "rename-window -t \(id) \(escapeArg(name))"

        case .killWindow(let id):
            return "kill-window -t \(id)"

        case .killWindowTarget(let target):
            return "kill-window -t \(escapeArg(target))"

        case .renameSession(let name):
            return "rename-session \(escapeArg(name))"

        case .splitWindow(let target, let horizontal, let path, let command):
            var cmd = "split-window"
            cmd += horizontal ? " -h" : " -v"
            if let target { cmd += " -t \(target)" }
            // Default: inherit the source pane's working directory. tmux
            // expands the format against the target pane server-side, so we
            // don't have to query the cwd ourselves.
            cmd += " -c \(path.map(escapeArg) ?? "'#{pane_current_path}'")"
            if let frag = spawnFragment(command) { cmd += " \(frag)" }
            return cmd

        case .selectPane(let id):
            return "select-pane -t \(id)"

        case .setPaneTitle(let id, let title):
            return "select-pane -t \(id) -T \(escapeArg(title))"

        case .listPanes(let target, let allWindows, let sessionWide):
            // window_id sits just before pane_title: the title (last field) may
            // itself contain colons, so every fixed field must precede it.
            var cmd = "list-panes -F '#{pane_id}:#{pane_width}:#{pane_height}:#{pane_left}:#{pane_top}:#{pane_active}:#{window_zoomed_flag}:#{pane_current_command}:#{mouse_any_flag}:#{mouse_sgr_flag}:#{alternate_on}:#{window_active}:#{window_id}:#{pane_in_mode}:#{pane_title}'"
            if allWindows { cmd += " -a" }
            else if sessionWide {
                cmd += " -s"
                if let target { cmd += " -t \(escapeArg(target))" }
            } else if let target { cmd += " -t \(escapeArg(target))" }
            return cmd

        case .breakPane(let source, let name, let targetSession):
            var cmd = "break-pane -d -s \(source)"
            if let name { cmd += " -n \(escapeArg(name))" }
            if let targetSession { cmd += " -t \(escapeArg("\(targetSession):"))" }
            return cmd

        case .joinPane(let source, let target):
            return "join-pane -d -s \(source) -t \(target)"

        case .movePane(let source, let target, let horizontal, let before):
            var cmd = "move-pane"
            cmd += horizontal ? " -h" : " -v"
            if before { cmd += " -b" }
            return cmd + " -s \(source) -t \(target)"

        case .moveWindow(let id, let targetSession):
            return "move-window -d -s \(id) -t \(escapeArg("\(targetSession):"))"

        case .joinPaneToSession(let source, let session):
            return "join-pane -d -s \(source) -t \(escapeArg("\(session):"))"

        case .selectLayoutTarget(let target, let layout):
            return "select-layout -t \(escapeArg(target)) \(escapeArg(layout))"

        case .setSessionOption(let target, let name, let value):
            var cmd = "set-option"
            if let target { cmd += " -t \(escapeArg(target))" }
            return cmd + " \(name) \(escapeArg(value))"

        case .setWindowOption(let window, let name, let value):
            var cmd = "set-option -w"
            if let window { cmd += " -t \(window)" }
            return cmd + " \(name) \(escapeArg(value))"

        case .resizeWindow(let window, let width, let height):
            var cmd = "resize-window"
            if let window { cmd += " -t \(window)" }
            return cmd + " -x \(width) -y \(height)"

        case .showSessionOption(let target, let name):
            var cmd = "show-options -qv"
            if let target { cmd += " -t \(escapeArg(target))" }
            return cmd + " \(name)"

        case .showWindowOption(let window, let name):
            var cmd = "show-options -wqv"
            if let window { cmd += " -t \(window)" }
            return cmd + " \(name)"

        case .killPane(let id):
            return "kill-pane -t \(id)"

        case .swapPaneUp(let id):
            return "swap-pane -U -t \(id)"

        case .swapPaneDown(let id):
            return "swap-pane -D -t \(id)"

        case .swapPanes(let source, let destination):
            return "swap-pane -s \(source) -t \(destination)"

        case .killSession(let name):
            if let name { return "kill-session -t \(escapeArg(name))" }
            return "kill-session"

        case .capturePane(let id, let lines, let escapes):
            // -p: print to stdout, -J: join wrapped lines, -e: SGR colors,
            // -S: start line (negative = from bottom). No -S → visible screen only.
            var cmd = "capture-pane -t \(id) -p -J"
            if escapes { cmd += " -e" }
            if let lines { cmd += " -S -\(lines)" }
            return cmd

        case .resizePane(let id, let width, let height):
            return "resize-pane -t \(id) -x \(width) -y \(height)"

        case .zoomPane(let id):
            return "resize-pane -Z -t \(id)"

        case .resizePaneBy(let id, let direction, let amount):
            return "resize-pane -t \(id) -\(direction) \(amount)"

        case .sendKeys(let pane, let keys, let literal):
            var cmd = "send-keys -t \(pane)"
            if literal { cmd += " -l" }
            cmd += " \(escapeArg(keys))"
            return cmd

        case .copyModeCommand(let pane, let command, let count):
            var cmd = "send-keys -t \(pane) -X"
            if let count, count > 1 { cmd += " -N \(count)" }
            cmd += " \(escapeArg(command))"
            return cmd

        case .showBuffer(let name):
            return "show-buffer -b \(escapeArg(name))"

        case .displayMessage(let format, let target):
            var cmd = "display-message -p"
            if let target { cmd += " -t \(target)" }
            cmd += " \(escapeArg(format))"
            return cmd

        case .listClients:
            return "list-clients -F '#{client_name}:#{client_session}'"

        case .selectLayout(let window, let layout):
            return "select-layout -t \(window) \(escapeArg(layout))"

        case .refreshClient(let width, let height):
            return "refresh-client -C \(width),\(height)"

        case .switchClient(let session):
            return "switch-client -t \(escapeArg(session))"
        }
    }

    /// Wire form of a spawned program. A user-typed command is shell-quoted so
    /// tmux runs it through `/bin/sh -c`; a tmux-syntax value (already quoted by
    /// tmux, e.g. `#{pane_start_command}`) is spliced verbatim so its quoting
    /// round-trips instead of being nested. Empty → nil (plain shell).
    private func spawnFragment(_ command: SpawnCommand?) -> String? {
        switch command {
        case .none:
            return nil
        case .shell(let s):
            return s.isEmpty ? nil : escapeArg(s)
        case .tmuxSyntax(let s):
            return s.isEmpty ? nil : s
        }
    }

    private func escapeArg(_ arg: String) -> String {
        // tmux parses the control-mode command STRING itself (no shell tokenizes
        // it for us), so its command-syntax metacharacters MUST force quoting:
        //
        //   • `#` begins a COMMENT — an unquoted `#{…}` format (e.g.
        //     display-message -p #{pane_current_path}) is silently dropped and the
        //     command returns its default. That fed garbage (tmux's default status
        //     line) into "Duplicate Current" as the new pane's path+command, so it
        //     exited on spawn and the window vanished.
        //   • `{`/`}` open a brace command GROUP and `;` separates commands. A tmux
        //     window-layout string carries braces (a horizontal split serializes as
        //     `…{…}`), so an unquoted `set-option @bento_orig_layout …{…}` or
        //     `select-layout -t @0 …{…}` parses the braces as a command group and
        //     the WHOLE command fails with a `syntax error` — silently, over control
        //     mode. That broke the Parallel⇄Focus round-trip: the layout was never
        //     saved on spread and never applied on merge, so the window fell back to
        //     tmux's even auto-layout. (`[`/`]` from a vertical split aren't special
        //     to the parser, but we quote them too — quoting a value is always safe.)
        //
        // CLI args escape all this only because the shell tokenizes them first;
        // control mode does not. Quoting still lets display-message expand the
        // format (see the -F '#{…}' lists).
        let special: Set<Character> = [" ", "'", "\"", "\\", "#", "{", "}", "[", "]", ";"]
        if arg.contains(where: { special.contains($0) }) {
            let escaped = arg.replacingOccurrences(of: "'", with: "'\\''")
            return "'\(escaped)'"
        }
        return arg
    }
}
