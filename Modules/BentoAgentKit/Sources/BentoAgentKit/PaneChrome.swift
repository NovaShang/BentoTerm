import Foundation
import BentoTmuxKit

/// The pane chrome's vocabulary — what a pane is CALLED, which glyph it wears,
/// and which accent tints its title band. One source of truth for every surface
/// that renders a pane: the macOS tiled host, the iOS pane strip, and the window
/// sidebar rows.
///
/// It lives here beside `PaneState` + `PaneState+Colors` because it is the same
/// kind of knowledge — how the detection domain's state becomes something the
/// user can read. While each view carried its own copy, they drifted: the iOS
/// strip showed the bare `pane_current_command`, derived once when the surface
/// bound, so a pane renamed with `select-pane -T` (or one whose foreground
/// command changed) kept a stale label the macOS chrome updated correctly.
public enum PaneChrome {

    /// The pane's label. `pane_title` is what this pane was NAMED — a rename, or
    /// whatever the program set — and `pane_current_command` is what's running
    /// in it right now. Show both when they say different things: the name alone
    /// loses the program, the command alone loses the rename.
    public static func title(for pane: Pane) -> String {
        let command = pane.currentCommand?.trimmingCharacters(in: .whitespaces) ?? ""
        let name = pane.title?.trimmingCharacters(in: .whitespaces) ?? ""
        if !name.isEmpty, name != command {
            return command.isEmpty ? name : "\(command) — \(name)"
        }
        return command.isEmpty ? "shell" : command
    }

    /// What a pane's chrome announces. `PaneState` plus the one display state
    /// that isn't a pane state: an agent that finished while you were looking
    /// elsewhere.
    public enum Status: Equatable, Sendable {
        case working
        case awaitingInput
        case doneUnseen
        case idle

        /// "Done, unseen" outranks the pane's own state — by the time the badge
        /// is set the program has settled back to idle, and "it finished while
        /// you were away" is the thing worth saying.
        public init(state: PaneState, agentFinishedUnseen: Bool) {
            if agentFinishedUnseen {
                self = .doneUnseen
                return
            }
            switch state {
            case .working:       self = .working
            case .awaitingInput: self = .awaitingInput
            case .idle:          self = .idle
            }
        }

        /// Leading glyph: working = play, awaiting = question, done = check,
        /// idle = a quiet hollow ring (same `.circle` family, empty = at rest).
        public var symbol: String {
            switch self {
            case .working:       return "play.circle.fill"
            case .awaitingInput: return "questionmark.circle.fill"
            case .doneUnseen:    return "checkmark.circle.fill"
            case .idle:          return "circle"
            }
        }

        /// Glyph color, from the canonical palette.
        public var glyphHex: UInt32 {
            switch self {
            case .working:       return PaneState.workingHex
            case .awaitingInput: return PaneState.awaitingHex
            case .doneUnseen:    return PaneState.doneUnseenHex
            case .idle:          return PaneState.idleHex
            }
        }

        /// Accent for the title band and its ink, or nil for neutral chrome.
        /// Idle is the only state with nothing to announce, so it alone goes
        /// neutral — the gray ring still marks it, quietly.
        public var accentHex: UInt32? {
            self == .idle ? nil : glyphHex
        }
    }

    /// A non-default MODE this pane is sitting in. Deliberately separate from
    /// `Status`: state is what the program is doing, a mode is something about
    /// the pane that changes how it responds to you. Mixing them into the
    /// leading glyph would overload one slot with two unrelated meanings, so
    /// modes get their own trailing slot and never borrow a state color.
    public enum ModeBadge: Equatable, Sendable {
        case none
        /// tmux has this pane in copy-mode (entered from outside Bento).
        case copyMode
        /// The user suppressed mouse reporting for this pane.
        case mouseReportingOff

        public var symbol: String? {
            switch self {
            case .none:              return nil
            case .copyMode:          return "doc.on.doc"
            case .mouseReportingOff: return "cursorarrow.slash"
            }
        }

        public var help: String? {
            switch self {
            case .none:              return nil
            case .copyMode:          return "tmux copy-mode — click to exit"
            case .mouseReportingOff: return "Mouse reporting off — click to turn back on"
            }
        }
    }
}
