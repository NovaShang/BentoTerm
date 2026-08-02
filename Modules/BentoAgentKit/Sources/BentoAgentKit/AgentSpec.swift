import Foundation

/// AgentPreset is the menu of "well-known" coding agents the wizard offers.
/// Mirrors BentoTermMac/Sources/Services/TmuxCLI.swift — keep both in sync.
public enum AgentPreset: String, CaseIterable, Identifiable {
    case claudeCode = "Claude Code"
    case opencode = "OpenCode"
    case codex = "Codex"
    case gemini = "Gemini CLI"
    case cursorAgent = "Cursor Agent"
    case copilot = "Copilot CLI"
    case amp = "Amp"
    case openclaw = "OpenClaw TUI"
    case hermes = "Hermes"
    case antigravity = "Antigravity"
    case none = "No agent (shell only)"
    case custom = "Custom command…"

    public var id: String { rawValue }

    /// nil = user-supplied (custom). Empty string = no agent, plain shell pane.
    public var command: String? {
        switch self {
        case .claudeCode:  return "claude"
        case .opencode:    return "opencode"
        case .codex:       return "codex"
        case .gemini:      return "gemini"
        case .cursorAgent: return "cursor-agent"
        case .copilot:     return "copilot"
        case .amp:         return "amp"
        case .openclaw:    return "openclaw tui"
        case .hermes:      return "hermes"
        case .antigravity: return "agy"
        case .none:        return ""
        case .custom:      return nil
        }
    }
}

/// How to install an agent: the official one-liner, whether it rides on
/// Node/npm (a real prerequisite for novices — the curl installers don't),
/// and the docs page for when the one-liner isn't enough.
public struct AgentInstall: Sendable {
    public let command: String
    public let requiresNode: Bool
    public let docsURL: String
}

public extension AgentPreset {
    /// Official install one-liner per agent, verified against each agent's
    /// docs 2026-07-07. nil = nothing to install (shell / custom).
    /// curl-based installers are preferred where the vendor offers one —
    /// zero dependencies, which matters for the first-run wizard's audience.
    var install: AgentInstall? {
        switch self {
        case .claudeCode:
            return AgentInstall(command: "curl -fsSL https://claude.ai/install.sh | bash",
                                requiresNode: false,
                                docsURL: "https://code.claude.com/docs/en/setup")
        case .codex:
            return AgentInstall(command: "curl -fsSL https://chatgpt.com/codex/install.sh | sh",
                                requiresNode: false,
                                docsURL: "https://developers.openai.com/codex/cli")
        case .gemini:
            return AgentInstall(command: "npm install -g @google/gemini-cli",
                                requiresNode: true,
                                docsURL: "https://geminicli.com/docs/get-started/installation/")
        case .opencode:
            return AgentInstall(command: "curl -fsSL https://opencode.ai/install | bash",
                                requiresNode: false,
                                docsURL: "https://opencode.ai/docs/")
        case .cursorAgent:
            return AgentInstall(command: "curl https://cursor.com/install -fsS | bash",
                                requiresNode: false,
                                docsURL: "https://cursor.com/docs/cli/installation")
        case .copilot:
            return AgentInstall(command: "npm install -g @github/copilot",
                                requiresNode: true,
                                docsURL: "https://docs.github.com/copilot/how-tos/set-up/install-copilot-cli")
        case .amp:
            return AgentInstall(command: "curl -fsSL https://ampcode.com/install.sh | bash",
                                requiresNode: false,
                                docsURL: "https://ampcode.com/manual")
        case .openclaw:
            return AgentInstall(command: "curl -fsSL https://openclaw.ai/install.sh | bash",
                                requiresNode: false,
                                docsURL: "https://docs.openclaw.ai/install")
        case .hermes:
            return AgentInstall(command: "curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash",
                                requiresNode: false,
                                docsURL: "https://hermes-agent.nousresearch.com/docs/getting-started/installation")
        case .antigravity:
            return AgentInstall(command: "curl -fsSL https://antigravity.google/cli/install.sh | bash",
                                requiresNode: false,
                                docsURL: "https://antigravity.google/docs/cli-install")
        case .none, .custom:
            return nil
        }
    }

    /// Whether this preset represents a real installable agent (for the
    /// first-run wizard's chooser).
    var isInstallableAgent: Bool { install != nil }
}

/// TmuxLayout is one of the canonical pane arrangements exposed as a visual
/// picker. Each maps to a (paneCount, tmuxLayoutName) pair.
public enum TmuxLayout: String, CaseIterable, Identifiable {
    case solo
    case sideBySide
    case topBottom
    case threeColumns
    case mainPlusStack
    case quadTile

    public var id: String { rawValue }

    public var paneCount: Int {
        switch self {
        case .solo: return 1
        case .sideBySide, .topBottom: return 2
        case .threeColumns, .mainPlusStack: return 3
        case .quadTile: return 4
        }
    }

    /// Argument to `tmux select-layout`. Nil means single pane (no select-layout needed).
    public var tmuxLayoutName: String? {
        switch self {
        case .solo: return nil
        case .sideBySide, .threeColumns: return "even-horizontal"
        case .topBottom: return "even-vertical"
        case .mainPlusStack: return "main-vertical"
        case .quadTile: return "tiled"
        }
    }

    public var symbol: String {
        switch self {
        case .solo: return "rectangle"
        case .sideBySide: return "rectangle.split.2x1"
        case .topBottom: return "rectangle.split.1x2"
        case .threeColumns: return "rectangle.split.3x1"
        case .mainPlusStack: return "sidebar.right"
        case .quadTile: return "square.grid.2x2"
        }
    }

    public var displayName: String {
        switch self {
        case .solo: return "Solo"
        case .sideBySide: return "Side by side"
        case .topBottom: return "Top / bottom"
        case .threeColumns: return "3 columns"
        case .mainPlusStack: return "Main + stack"
        case .quadTile: return "2 × 2 tile"
        }
    }
}

/// AgentSpec is the user input from the wizard.
public struct AgentSpec: Hashable {
    public var sessionName: String
    public var workingDir: String
    public var agentCommand: String   // resolved command (may be empty for shell-only)
    public var layout: TmuxLayout

    public init(sessionName: String, workingDir: String, agentCommand: String, layout: TmuxLayout) {
        self.sessionName = sessionName
        self.workingDir = workingDir
        self.agentCommand = agentCommand
        self.layout = layout
    }
}

// A spec used to render a `setupScript` — a `tmux new-session -d …;
// split-window …` line typed into the remote login shell a second before
// attaching. It was removed, not moved: that write raced the freshly spawned
// pty and, when it lost, dropped `-c <dir>` silently so the agent started in
// the wrong folder. The session is now seeded on the `tmux -CC` launch line
// itself (`TmuxControlMode.launchCommand`) and the extra panes are added over
// control mode, where every command has a response we can log. The tilde
// quoting rule that lived here now lives in `TmuxShellQuote`, with its
// regression tests in swift-tmux's `LaunchCommandTests`.
