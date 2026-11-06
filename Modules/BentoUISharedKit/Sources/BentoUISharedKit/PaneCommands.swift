import Foundation
import BentoSessionKit

/// Every pane action the two apps offer, with the words and symbols each
/// surface shows for it, and the rules for when it is offered.
///
/// Three surfaces render them: the Mac pane menu (title-bar ⌄ and right-click),
/// the Mac toolbar's New ⌄ menu, and the iOS pane menu. They used to be
/// spelled out by hand and had drifted (iOS said "Maximize" for Zoom); one
/// table is what keeps them from drifting again. Where a surface still words a
/// row differently — a New-menu "Split Pane" — it is chosen here, in the open.
///
/// Performing a command stays with each platform: the Mac routes through the
/// responder chain to the focused pane host (`BentoPaneAction`), iOS through
/// its container's callbacks. This holds what is shared — identity, words,
/// symbols, availability and order.
public enum PaneCommand: String, CaseIterable, Sendable {
    case find
    case splitRight
    case splitDown
    case splitDuplicate
    case splitPathCommand
    case zoom
    case exitCopyMode
    case closePane
    /// ⌘N in Parallel: one more pane, split along the active pane's longer
    /// side (the New menu's first row).
    case newPane
    /// ⌘N in Focus: one more tmux window (the same row, in Focus).
    case newTmuxWindow

    public enum Surface: Sendable {
        /// Mac: the title bar's ⌄ and the surface's right-click menu.
        case macPaneMenu
        /// Mac: the toolbar's `New ⌄` menu.
        case macNewMenu
        /// iOS: a pane's title-bar menu.
        case iosPaneMenu
    }

    public enum Role: Sendable { case normal, destructive }

    /// The row's title on `surface`. `zoomed` only matters for `.zoom`.
    public func title(on surface: Surface, zoomed: Bool = false) -> String {
        switch self {
        case .find: return "Find…"
        case .splitRight: return "Split Right (-h)"
        case .splitDown: return "Split Down (-v)"
        case .splitDuplicate: return "Split — Duplicate Current"
        case .splitPathCommand: return "Split — Path & Command…"
        case .zoom: return zoomed ? "Unzoom" : "Zoom"
        case .exitCopyMode: return "Exit tmux copy-mode"
        case .closePane: return "Close Pane"
        case .newPane: return "New Pane"
        case .newTmuxWindow: return "New tmux Window"
        }
    }

    /// The SF Symbol on `surface`, or nil for a row drawn without one.
    public func symbol(on surface: Surface, zoomed: Bool = false) -> String? {
        switch self {
        case .find: return "magnifyingglass"
        case .splitRight: return "rectangle.split.2x1"
        case .splitDown: return "rectangle.split.1x2"
        case .splitDuplicate: return "plus.square.on.square"
        case .splitPathCommand: return "terminal"
        case .zoom:
            return zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        case .exitCopyMode: return "arrow.uturn.backward"
        case .closePane: return "xmark"
        case .newPane: return "square.split.2x1"
        case .newTmuxWindow: return "macwindow"
        }
    }

    public func role(on surface: Surface) -> Role {
        (self == .closePane && surface == .iosPaneMenu) ? .destructive : .normal
    }

    /// Hover text, where the surface has any (the Mac New menu).
    public func tip(on surface: Surface) -> String? {
        guard surface == .macNewMenu else { return nil }
        switch self {
        case .newPane:
            return "Split the current pane along its longer side."
        case .newTmuxWindow:
            return "A new tmux window in this session."
        default: return nil
        }
    }
}

/// What the menus need to know about the pane and session at open time.
public struct PaneMenuContext: Equatable, Sendable {
    /// A tmux pane — a plain shell's single pane has no tmux structure.
    public var isTmuxPane: Bool
    public var sessionMode: TmuxSessionMode
    public var zoomed: Bool
    /// tmux has the pane in copy-mode (entered by some other client).
    public var inCopyMode: Bool
    public var paneCount: Int
    /// The iOS host's own veto on split rows (e.g. the device can't fit one).
    public var showsSplitActions: Bool

    public init(isTmuxPane: Bool = true, sessionMode: TmuxSessionMode, zoomed: Bool = false,
                inCopyMode: Bool = false, paneCount: Int = 1, showsSplitActions: Bool = true) {
        self.isTmuxPane = isTmuxPane
        self.sessionMode = sessionMode
        self.zoomed = zoomed
        self.inCopyMode = inCopyMode
        self.paneCount = paneCount
        self.showsSplitActions = showsSplitActions
    }

    /// Splits are Parallel's creation path; Focus (one pane per window)
    /// creates windows instead, so no surface offers a split there.
    public var offersSplits: Bool { sessionMode != .list }
}

/// One row of a pane menu. Commands come from `PaneCommand`; the others are
/// rows each platform builds itself because what they hold is platform state
/// (remembered launches, the session list, the clipboard) or a submenu.
public enum PaneMenuEntry: Equatable, Sendable {
    case command(PaneCommand)
    case separator
    /// "Recent Agents" header + rows; omitted entirely (with its separator)
    /// when nothing is remembered — the platform drops it.
    case recentAgents
    /// tmux's named layouts (a submenu on the Mac).
    case layouts
    /// "Move to Session" submenu, filled lazily at open.
    case moveToSession
    /// iOS: paste from the clipboard into the pane.
    case paste
}

/// Which rows each surface shows, in order. Conditions that depend on state
/// are evaluated from a `PaneMenuContext`; the iOS sections are asked again at
/// every open (`UIDeferredMenuElement.uncached`), the Mac menu is rebuilt per
/// open.
public enum PaneMenuLayout {

    /// Mac pane menu: title-bar ⌄ and right-click.
    public static func macPaneMenu(_ c: PaneMenuContext) -> [PaneMenuEntry] {
        var rows: [PaneMenuEntry] = []
        if c.offersSplits {
            rows += [.command(.splitRight), .command(.splitDown), .separator,
                     .command(.splitDuplicate), .command(.splitPathCommand),
                     .recentAgents,
                     .separator, .layouts, .separator]
        }
        // No Swap Up/Down rows: ⌥⌘↑/↓ and dragging the title bar reorder
        // panes, and two rows for a one-step nudge was the menu's longest
        // stretch of things nobody reached for.
        rows += [.command(.zoom), .separator,
                 .moveToSession, .separator,
                 .command(.closePane)]
        return rows
    }

    /// Mac ＋ menu rows that need a tmux session to create inside: one more of
    /// what the session is made of (a pane in Parallel, a tmux window in
    /// Focus — what ⌘N does), then the remembered agents. Dropped on a plain
    /// terminal rather than disabled. The session-level rows (agent, session,
    /// plain terminal, SSH) are the Mac's own and follow these.
    public static func macNewMenuSessionRows(_ c: PaneMenuContext) -> [PaneMenuEntry] {
        guard c.isTmuxPane else { return [] }
        return [.command(c.sessionMode == .list ? .newTmuxWindow : .newPane), .recentAgents]
    }

    /// iOS pane menu, as its five sections. `find` and `paste` are always
    /// there — they are about the terminal, which a plain shell has too; the
    /// rest is tmux structure.
    public enum IOSSection: CaseIterable, Sendable {
        case find, zoom, paste, split, copyMode, structure
    }

    public static func iosPaneMenu(_ section: IOSSection, _ c: PaneMenuContext) -> [PaneMenuEntry] {
        switch section {
        case .find: return [.command(.find)]
        case .paste: return [.paste]
        case .zoom: return c.isTmuxPane ? [.command(.zoom)] : []
        case .split:
            return c.isTmuxPane && c.showsSplitActions
                ? [.command(.splitRight), .command(.splitDown), .command(.splitPathCommand)] : []
        case .copyMode: return c.inCopyMode ? [.command(.exitCopyMode)] : []
        case .structure: return c.isTmuxPane ? [.moveToSession, .command(.closePane)] : []
        }
    }

    /// iOS ⋯ menu "Layout" section: only when there is more than one pane to
    /// arrange.
    public static func iosOverflowShowsLayouts(_ c: PaneMenuContext) -> Bool {
        c.sessionMode == .tiled && c.paneCount > 1
    }
}
