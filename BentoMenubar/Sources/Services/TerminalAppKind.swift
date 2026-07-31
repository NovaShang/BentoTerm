import AppKit

/// TerminalAppKind enumerates the macOS terminals we can spawn a tmux
/// session into. Each one is opened via AppleScript (the only API that
/// reliably lets you both `create window` and `do script <cmd>` in one
/// hop) — except where the terminal's own `--args` / `-e` flags do the
/// same thing more cleanly.
///
/// iTerm2 deserves special treatment: when you hand it `tmux -CC ...`
/// it switches the attached session into its native multi-window
/// integration, where each tmux window is a real iTerm tab and each
/// pane is a real iTerm split. That's the experience the user is after.
enum TerminalAppKind: String, CaseIterable, Identifiable, Codable {
    /// Bento's own native libghostty terminal (in-app window, local pty +
    /// `tmux -CC`). The default — sessions open in our tiled terminal rather
    /// than bouncing out to a third-party app. The other cases remain so users
    /// who prefer iTerm2/Ghostty/etc. can still opt out.
    /// Raw value is a persisted UserDefaults key (`preferredTerminal`), not a
    /// label — it stays "Bento" even though the app is now called BentoTerm.
    case bento    = "Bento"
    case terminal = "Terminal"
    case iTerm    = "iTerm"
    case ghostty  = "Ghostty"
    case warp     = "Warp"

    var id: String { rawValue }

    /// Whether this is Bento's in-app native terminal (not an external app).
    var isNative: Bool { self == .bento }

    /// Bundle identifier used both for "is this installed?" checks and
    /// for the AppleScript `tell application id "…"` form.
    var bundleID: String {
        switch self {
        case .bento:    return Bundle.main.bundleIdentifier ?? "com.bento.term.menubar"
        case .terminal: return "com.apple.Terminal"
        case .iTerm:    return "com.googlecode.iterm2"
        case .ghostty:  return "com.mitchellh.ghostty"
        case .warp:     return "dev.warp.Warp-Stable"
        }
    }

    var displayName: String {
        switch self {
        case .bento:    return "BentoTerm (native)"
        case .terminal: return "Terminal"
        case .iTerm:    return "iTerm2"
        case .ghostty:  return "Ghostty"
        case .warp:     return "Warp"
        }
    }

    /// True if the app is installed on this Mac (any registered copy). The
    /// native Bento terminal is always available (it's us).
    var isInstalled: Bool {
        if isNative { return true }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// Whether this terminal natively understands tmux control mode
    /// (`tmux -CC`) and renders panes as first-class windows/tabs. Bento's
    /// own terminal is built on control mode; iTerm2 also integrates.
    var supportsTmuxControlMode: Bool {
        switch self {
        case .bento, .iTerm: return true
        default:             return false
        }
    }

    /// All terminals known to the app, in user-facing menu order (native first).
    static var allInstalled: [TerminalAppKind] {
        Self.allCases.filter(\.isInstalled)
    }

    /// User's currently-preferred terminal, falling back gracefully if
    /// the saved choice is no longer installed. Persists via
    /// UserDefaults under `preferredTerminal`. Default = Bento's native
    /// terminal.
    static var preferred: TerminalAppKind {
        get {
            let raw = UserDefaults.standard.string(forKey: "preferredTerminal") ?? ""
            if let kind = TerminalAppKind(rawValue: raw), kind.isInstalled {
                return kind
            }
            // Default to our own terminal; fall back through external apps only
            // if a saved preference points at one.
            return .bento
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "preferredTerminal")
        }
    }
}
