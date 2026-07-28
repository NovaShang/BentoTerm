import Foundation

// MARK: - tmux ID Types

/// tmux session ID, e.g. "$0"
public struct TmuxSessionID: Hashable, Codable, CustomStringConvertible, Sendable {
    public let raw: Int
    public var description: String { "$\(raw)" }

    public init(_ raw: Int) { self.raw = raw }

    public init?(string: String) {
        guard string.hasPrefix("$"), let num = Int(string.dropFirst()) else { return nil }
        self.raw = num
    }
}

/// tmux window ID, e.g. "@5"
public struct TmuxWindowID: Hashable, Codable, CustomStringConvertible, Sendable {
    public let raw: Int
    public var description: String { "@\(raw)" }

    public init(_ raw: Int) { self.raw = raw }

    public init?(string: String) {
        guard string.hasPrefix("@"), let num = Int(string.dropFirst()) else { return nil }
        self.raw = num
    }
}

/// tmux pane ID, e.g. "%3"
public struct TmuxPaneID: Hashable, Codable, CustomStringConvertible, Sendable {
    public let raw: Int
    public var description: String { "%\(raw)" }

    public init(_ raw: Int) { self.raw = raw }

    public init?(string: String) {
        guard string.hasPrefix("%"), let num = Int(string.dropFirst()) else { return nil }
        self.raw = num
    }
}

// MARK: - Notifications

/// Parsed tmux control mode notifications.
public enum TmuxNotification: Sendable {
    case output(pane: TmuxPaneID, data: Data)
    case layoutChange(window: TmuxWindowID, layout: String)
    case windowAdd(window: TmuxWindowID)
    case windowClose(window: TmuxWindowID)
    case windowRenamed(window: TmuxWindowID, name: String)
    case sessionChanged(session: TmuxSessionID, name: String)
    case sessionRenamed(name: String)
    case paneModeChanged(pane: TmuxPaneID, mode: String)
    case exit(reason: String?)
}

/// A command response block from tmux. `output` is the joined text between
/// the `%begin` and `%end`/`%error` markers; `isError` is true when the block
/// terminated with `%error`.
public struct TmuxCommandResponse: Sendable {
    public let commandNumber: Int
    public let isError: Bool
    public let output: String

    public init(commandNumber: Int, isError: Bool, output: String) {
        self.commandNumber = commandNumber
        self.isError = isError
        self.output = output
    }
}

// MARK: - Models

public struct TmuxWindow: Identifiable, Sendable, Hashable {
    public let id: TmuxWindowID
    /// `#{window_index}` — the number tmux itself shows in `list-windows`,
    /// targets with `select-window -t <index>`, and restores order with via
    /// `move-window -t <index>`. Displayed as `index:name` so what the user
    /// reads in Bento matches what they read in tmux. `nil` only when parsed
    /// from a listing that predates the field.
    public var index: Int?
    public var name: String
    public var panes: [Pane]
    public var layout: String?
    /// Whether this is the session's current window (`#{window_active}`).
    public var isActive: Bool

    /// tmux's own `index:name` label. Falls back to the bare name when the
    /// index is unknown so callers never render a stray separator.
    public var indexedName: String {
        guard let index else { return name }
        return "\(index):\(name)"
    }

    public init(id: TmuxWindowID, index: Int? = nil, name: String, panes: [Pane], layout: String?, isActive: Bool = false) {
        self.id = id
        self.index = index
        self.name = name
        self.panes = panes
        self.layout = layout
        self.isActive = isActive
    }
}

public struct Pane: Identifiable, Sendable, Hashable {
    public let id: TmuxPaneID
    public var width: Int
    public var height: Int
    public var x: Int
    public var y: Int
    public var isActive: Bool
    /// True when this pane's window is zoomed (tmux `window_zoomed_flag`). The
    /// flag is per-window, so every pane in a zoomed window reports it; the
    /// zoomed pane itself is the active one.
    public var isZoomed: Bool
    public var currentCommand: String?
    public var title: String?
    /// The program in this pane has mouse reporting on (tmux `mouse_any_flag`).
    /// In `-CC` control mode tmux does NOT pass the program's mouse-enable
    /// sequence through to the client, so this flag is how we learn to forward
    /// mouse events to the pane instead of treating clicks as selection.
    public var mouseAny: Bool
    /// The pane requested SGR-encoded mouse reports (`mouse_sgr_flag`); otherwise
    /// use the legacy X10/normal byte encoding.
    public var mouseSGR: Bool
    /// The program is drawing on the alternate screen (tmux `alternate_on`) —
    /// a fullscreen TUI. Like the mouse flags, control mode swallows the
    /// program's `?1049h`, so tmux's flag is the only way to know. Scrollback
    /// features (turn navigation) are meaningless here: the TUI owns the screen
    /// and keeps its own history.
    public var alternateOn: Bool
    /// The window this pane belongs to (`window_id`). Populated by session-wide
    /// `list-panes -s`; nil when the listing was scoped to a single window.
    public var windowID: TmuxWindowID?
    /// True when this pane's window is the session's current window
    /// (`window_active`). Lets a session-wide listing carve out the current
    /// window's panes without relying on separately-refreshed window state.
    public var inActiveWindow: Bool
    /// tmux has this pane in a mode — copy-mode being the one that matters
    /// (`pane_in_mode`). A client can't tell from the output stream: tmux draws
    /// the mode's UI as ordinary pane content. While it's set, keys sent with
    /// `send-keys` are consumed by tmux's mode handler instead of reaching the
    /// program, and the pane will not scroll on its own.
    public var inMode: Bool

    public init(
        id: TmuxPaneID,
        width: Int,
        height: Int,
        x: Int,
        y: Int,
        isActive: Bool,
        isZoomed: Bool = false,
        currentCommand: String?,
        title: String?,
        mouseAny: Bool = false,
        mouseSGR: Bool = false,
        alternateOn: Bool = false,
        windowID: TmuxWindowID? = nil,
        inActiveWindow: Bool = true,
        inMode: Bool = false
    ) {
        self.id = id
        self.width = width
        self.height = height
        self.x = x
        self.y = y
        self.isActive = isActive
        self.isZoomed = isZoomed
        self.currentCommand = currentCommand
        self.title = title
        self.mouseAny = mouseAny
        self.mouseSGR = mouseSGR
        self.alternateOn = alternateOn
        self.windowID = windowID
        self.inActiveWindow = inActiveWindow
        self.inMode = inMode
    }
}
