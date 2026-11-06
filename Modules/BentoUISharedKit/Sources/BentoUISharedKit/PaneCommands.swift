import Foundation
import BentoSessionKit

/// Every pane action the two apps offer, with the words and symbols each
/// surface shows for it, and the rules for when it is offered.
///
/// Five surfaces used to spell these out by hand: the Mac pane menu (title-bar
/// ⌄ and right-click), the Mac command palette, the Mac toolbar's New ⌄ menu,
/// the iOS pane menu, and the iOS ⋯ menu. They had already drifted — "Zoom" on
/// the Mac is "Maximize" on iOS and "Toggle Zoom" in the palette; Close Pane is
/// an `xmark` in one place and an `xmark.square` in another. The drift is
/// reproduced here deliberately (whether the platforms should match is a
/// product decision not taken yet); what changes is that it is now one table,
/// so making them match is an edit to this file.
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
    case swapUp
    case swapDown
    case exitCopyMode
    case closePane
    case nextPane
    case previousPane
    /// A tmux window: a plain one in Parallel, a duplicate of the current pane
    /// in Focus (the palette's row).
    case newTmuxWindow
    /// A tmux window seeded with the current pane's folder and command, in
    /// either mode (the New menu's row — same title, different action).
    case newTmuxWindowDuplicate

    public enum Surface: Sendable {
        /// Mac: the title bar's ⌄ and the surface's right-click menu.
        case macPaneMenu
        /// Mac: ⌘K / omnibox commands.
        case macPalette
        /// Mac: the toolbar's `New ⌄` menu.
        case macNewMenu
        /// iOS: a pane's title-bar menu.
        case iosPaneMenu
        /// iOS: the session's ⋯ menu.
        case iosOverflowMenu
    }

    public enum Role: Sendable { case normal, destructive }

    /// The row's title on `surface`. `zoomed` only matters for `.zoom`.
    public func title(on surface: Surface, zoomed: Bool = false) -> String {
        switch self {
        case .find: return "Find…"
        case .splitRight: return "Split Right (-h)"
        case .splitDown: return "Split Down (-v)"
        case .splitDuplicate:
            switch surface {
            case .macPalette, .macNewMenu: return "Split Pane"
            default: return "Split — Duplicate Current"
            }
        case .splitPathCommand: return "Split — Path & Command…"
        case .zoom:
            switch surface {
            case .macPalette: return "Toggle Zoom"
            case .iosPaneMenu, .iosOverflowMenu: return zoomed ? "Restore" : "Maximize"
            default: return zoomed ? "Unzoom" : "Zoom"
            }
        case .swapUp: return "Swap Up"
        case .swapDown: return "Swap Down"
        case .exitCopyMode: return "Exit tmux copy-mode"
        case .closePane: return "Close Pane"
        case .nextPane: return "Select Next Pane"
        case .previousPane: return "Select Previous Pane"
        case .newTmuxWindow, .newTmuxWindowDuplicate: return "New tmux Window"
        }
    }

    /// The SF Symbol on `surface`, or nil for a row drawn without one.
    public func symbol(on surface: Surface, zoomed: Bool = false) -> String? {
        switch self {
        case .find: return "magnifyingglass"
        case .splitRight: return "rectangle.split.2x1"
        case .splitDown: return "rectangle.split.1x2"
        case .splitDuplicate:
            return surface == .macNewMenu ? "square.split.2x1" : "plus.square.on.square"
        case .splitPathCommand: return "terminal"
        case .zoom:
            if surface == .macPalette { return "arrow.up.left.and.arrow.down.right" }
            return zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        case .swapUp: return "arrow.up.square"
        case .swapDown: return "arrow.down.square"
        case .exitCopyMode: return "arrow.uturn.backward"
        case .closePane: return surface == .macPalette ? "xmark.square" : "xmark"
        case .nextPane: return "arrow.right.square"
        case .previousPane: return "arrow.left.square"
        case .newTmuxWindow: return "plus.rectangle.on.folder"
        case .newTmuxWindowDuplicate: return "macwindow"
        }
    }

    public func role(on surface: Surface) -> Role {
        (self == .closePane && surface == .iosPaneMenu) ? .destructive : .normal
    }

    /// Hover text, where the surface has any (the Mac New menu).
    public func tip(on surface: Surface) -> String? {
        guard surface == .macNewMenu else { return nil }
        switch self {
        case .newTmuxWindowDuplicate:
            return "A tmux window in this session, with the current pane's folder and command."
        case .splitDuplicate:
            return "Split the current pane, inheriting its folder and command."
        default: return nil
        }
    }

    /// Stable id for palette rows (`cmd:<id>`), kept from before the catalog
    /// so palette recents still match.
    public var paletteID: String {
        switch self {
        case .splitRight: return "splitRight"
        case .splitDown: return "splitDown"
        case .splitDuplicate: return "duplicate"
        case .closePane: return "closePane"
        case .zoom: return "zoom"
        case .nextPane: return "nextPane"
        case .previousPane: return "prevPane"
        case .newTmuxWindow: return "newTmuxWindow"
        default: return rawValue
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
        rows += [.command(.zoom), .separator,
                 .command(.swapUp), .command(.swapDown), .separator,
                 .moveToSession, .separator,
                 .command(.closePane)]
        return rows
    }

    /// Mac `New ⌄` rows that need a session to create inside; dropped on a
    /// launcher (no session) rather than disabled. Picking a folder and command
    /// is the pane menu's (splits) and the Focus sidebar's (windows) — New ⌄
    /// is the quick path.
    public static func macNewMenuSessionRows(hasSession: Bool) -> [PaneMenuEntry] {
        guard hasSession else { return [] }
        return [.separator, .command(.newTmuxWindowDuplicate), .command(.splitDuplicate),
                .recentAgents]
    }

    /// Mac palette's pane commands, after the layout rows. (The palette's
    /// window-level commands — new Mac window, session size, preview panel —
    /// are the Mac's own.)
    public static let macPalette: [PaneCommand] = [
        .splitRight, .splitDown, .splitDuplicate, .closePane, .zoom,
        .nextPane, .previousPane, .newTmuxWindow,
    ]

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
                ? [.command(.splitRight), .command(.splitDown)] : []
        case .copyMode: return c.inCopyMode ? [.command(.exitCopyMode)] : []
        case .structure: return c.isTmuxPane ? [.moveToSession, .command(.closePane)] : []
        }
    }

    /// iOS ⋯ menu "Split" section — Parallel only, the two seeded splits
    /// mirroring Focus's window creation.
    public static func iosOverflowSplit(_ c: PaneMenuContext) -> [PaneCommand] {
        c.sessionMode == .tiled
            ? [.splitRight, .splitDown, .splitDuplicate, .splitPathCommand] : []
    }

    /// iOS ⋯ menu "Layout" section: only when there is more than one pane to
    /// arrange.
    public static func iosOverflowShowsLayouts(_ c: PaneMenuContext) -> Bool {
        c.sessionMode == .tiled && c.paneCount > 1
    }
}
