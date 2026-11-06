import Foundation

/// AgentPreset is the menu of "well-known" coding agents the wizard offers.
/// This is the canonical copy — the Mac app's TmuxCLI.swift references it.
public enum AgentPreset: String, CaseIterable, Identifiable, Sendable {
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

public extension AgentPreset {
    /// The preset behind the agent id a hook wrote into `@bento_agent`, or
    /// nil when we have no launch command we can stand behind.
    ///
    /// The id is whatever the user's hook config says, so the common spellings
    /// all map. An id we can't run returns nil rather than a guess: this feeds
    /// a recents row whose whole promise is that clicking it starts the agent
    /// again, and a command that isn't real opens a pane that exits on sight.
    static func forAgentID(_ id: String) -> AgentPreset? {
        switch id.lowercased() {
        case "claude", "claude-code":   return .claudeCode
        case "codex":                   return .codex
        case "opencode":                return .opencode
        case "gemini":                  return .gemini
        case "cursor-agent", "cursor":  return .cursorAgent
        case "copilot":                 return .copilot
        case "amp":                     return .amp
        case "hermes":                  return .hermes
        case "antigravity", "agy":      return .antigravity
        default:                        return nil
        }
    }

    /// The command to run, when there is one worth remembering. `.none` and
    /// `.custom` are excluded — an empty string is a shell, and nil is
    /// whatever the user typed, neither of which names an agent.
    var launchCommand: String? {
        guard let command, !command.isEmpty else { return nil }
        return command
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

/// AgentSpec is the user input from the wizard.
public struct AgentSpec: Hashable {
    public var sessionName: String
    public var workingDir: String
    public var agentCommand: String   // resolved command (may be empty for shell-only)

    public init(sessionName: String, workingDir: String, agentCommand: String) {
        self.sessionName = sessionName
        self.workingDir = workingDir
        self.agentCommand = agentCommand
    }
}

// The session is seeded on the `tmux -CC` launch line
// (`TmuxControlMode.launchCommand`) and opens as one pane; more panes are a
// split away once the user is in it.
