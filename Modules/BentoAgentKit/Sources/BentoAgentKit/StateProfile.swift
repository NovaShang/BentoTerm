import Foundation

/// A profile that defines how to detect a specific tool's awaiting-input state
public struct StateProfile: Identifiable, Codable {
    public var id: String
    public var name: String
    /// Regex patterns to match against the last N lines of output
    public var outputPatterns: [String]
    /// Regex patterns to match against the pane title (pane_title). Checked
    /// BEFORE output patterns (PRD §3.4 priority: Title 匹配 → 输出正则). Empty
    /// for the built-ins by default — a wrong title pattern causes false
    /// "awaiting" states, and detection reliability is the priority — but
    /// user/custom profiles can populate it.
    public var titlePatterns: [String]
    /// Command name pattern (matched against pane_current_command)
    public var commandPattern: String?
    /// Quick keys to show when this profile matches
    public var quickKeys: [QuickKey]
    /// Whether this is a built-in profile (can't be deleted)
    public var isBuiltIn: Bool = false
    /// Rich region/priority/AND-OR-NOT detection rules (the precise engine).
    /// nil for simple profiles that rely on `outputPatterns` activity detection.
    /// For built-ins this is refreshed from the code preset on load (see
    /// ProfileStore.mergeMissingBuiltIns) — detection logic stays preset-driven,
    /// user edits to name/outputPatterns/quickKeys persist.
    public var agentRules: AgentRuleSet?
    /// Line regexes that mark a USER-TURN START in the scrollback.
    /// e.g. Claude Code: a line starting `❯ `.
    public var promptBoundary: [String]

    public init(id: String, name: String, outputPatterns: [String],
                titlePatterns: [String] = [],
                commandPattern: String?, quickKeys: [QuickKey], isBuiltIn: Bool = false,
                agentRules: AgentRuleSet? = nil, promptBoundary: [String] = []) {
        self.id = id; self.name = name; self.outputPatterns = outputPatterns
        self.titlePatterns = titlePatterns
        self.commandPattern = commandPattern; self.quickKeys = quickKeys
        self.isBuiltIn = isBuiltIn
        self.agentRules = agentRules; self.promptBoundary = promptBoundary
    }

    // Lenient decoder — defaults all fields so adding new ones doesn't
    // invalidate stored profiles.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        self.name = (try? c.decode(String.self, forKey: .name)) ?? ""
        self.outputPatterns = (try? c.decode([String].self, forKey: .outputPatterns)) ?? []
        self.titlePatterns = (try? c.decode([String].self, forKey: .titlePatterns)) ?? []
        self.commandPattern = try? c.decodeIfPresent(String.self, forKey: .commandPattern)
        self.quickKeys = (try? c.decode([QuickKey].self, forKey: .quickKeys)) ?? []
        self.isBuiltIn = (try? c.decode(Bool.self, forKey: .isBuiltIn)) ?? false
        self.agentRules = try? c.decodeIfPresent(AgentRuleSet.self, forKey: .agentRules)
        self.promptBoundary = (try? c.decode([String].self, forKey: .promptBoundary)) ?? []
    }
}

public struct QuickKey: Identifiable, Codable {
    public var id: String
    public var label: String
    public var keys: String   // The string to send via send-keys
    public var isEnter: Bool  // Whether to also send Enter after

    public init(id: String, label: String, keys: String, isEnter: Bool) {
        self.id = id; self.label = label; self.keys = keys; self.isEnter = isEnter
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        self.label = (try? c.decode(String.self, forKey: .label)) ?? ""
        self.keys = (try? c.decode(String.self, forKey: .keys)) ?? ""
        self.isEnter = (try? c.decode(Bool.self, forKey: .isEnter)) ?? false
    }
}
