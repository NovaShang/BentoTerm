import Foundation
import Combine
import os

private let profileLog = Logger(subsystem: "com.bento.terminalcore", category: "profiles")

/// Manages state profiles — built-in presets + user-customizable
@MainActor
public final class ProfileStore: ObservableObject {
    public static let shared = ProfileStore()

    @Published public var profiles: [StateProfile] = []

    private let storageKey = "state_profiles"

    private init() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            // First launch — seed with built-ins.
            profiles = Self.defaultProfiles
            save()
            return
        }
        do {
            profiles = try JSONDecoder().decode([StateProfile].self, from: data)
            mergeMissingBuiltIns()
        } catch {
            // Decode failed (corrupt or schema change the lenient init still
            // couldn't absorb). Preserve the raw bytes under a sibling key so
            // we can recover later, and seed with built-ins so the app keeps
            // working. Do NOT overwrite the original key, that would silently
            // delete the broken data.
            let stamp = Int(Date().timeIntervalSince1970)
            UserDefaults.standard.set(data, forKey: "\(storageKey)_broken_\(stamp)")
            profileLog.error("Failed to decode state_profiles: \(String(describing: error)). Backed up under state_profiles_broken_\(stamp)")
            profiles = Self.defaultProfiles
        }
    }

    /// Append any built-in profile whose id isn't already stored. Lets existing
    /// installs (which seeded an older built-in set into UserDefaults) pick up
    /// profiles added in later versions — e.g. Codex / Vim — without clobbering
    /// the user's own profiles or edits to existing built-ins.
    private func mergeMissingBuiltIns() {
        var changed = false
        let existing = Set(profiles.map(\.id))
        let missing = Self.defaultProfiles.filter { !existing.contains($0.id) }
        if !missing.isEmpty {
            profiles.append(contentsOf: missing)
            changed = true
        }
        // Refresh the PRESET-DRIVEN detection fields on existing built-ins so
        // installs that stored an older built-in (e.g. before the rich rules /
        // boundary existed) pick them up. These have no editor, so this can't
        // clobber a user edit; user-editable fields (name/outputPatterns/
        // titlePatterns/quickKeys) are left as stored.
        let presetByID = Dictionary(uniqueKeysWithValues: Self.defaultProfiles.map { ($0.id, $0) })
        for i in profiles.indices where profiles[i].isBuiltIn {
            guard let preset = presetByID[profiles[i].id] else { continue }
            // Adopt preset detection logic (idempotent: only writes when different).
            if !sameRules(profiles[i].agentRules, preset.agentRules) {
                profiles[i].agentRules = preset.agentRules
                changed = true
            }
            if profiles[i].promptBoundary != preset.promptBoundary {
                profiles[i].promptBoundary = preset.promptBoundary
                changed = true
            }
        }
        if changed { save() }
    }

    /// Cheap structural compare of two optional rule sets (encode + equate JSON).
    private func sameRules(_ a: AgentRuleSet?, _ b: AgentRuleSet?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?):
            let enc = JSONEncoder()
            return (try? enc.encode(x)) == (try? enc.encode(y))
        default: return false
        }
    }

    public func save() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    public func resetToDefaults() {
        profiles = Self.defaultProfiles
        save()
    }

    // MARK: - Built-in Presets

    // Command-specific profiles are listed before the catch-all `genericShell`;
    // detection also enforces this precedence independent of order (see
    // StateDetectionService.detectState), so a merged-in profile can't be
    // shadowed by the generic one.
    public static let defaultProfiles: [StateProfile] = [
        claudeCode, codex, gemini, opencode, hermes, antigravity,
        cursorAgent, copilot, amp, cline,
        gitInteractive, vim, genericShell,
    ]

    /// The default quick-reply keys for an agent permission form (approve /
    /// deny / confirm / dismiss). Individual agents can override.
    private static let agentQuickKeys: [QuickKey] = [
        QuickKey(id: "y", label: "Yes", keys: "y", isEnter: true),
        QuickKey(id: "n", label: "No", keys: "n", isEnter: true),
        QuickKey(id: "enter", label: "↵", keys: "", isEnter: true),
        QuickKey(id: "esc", label: "Esc", keys: "\u{1b}", isEnter: false),
    ]

    public static let claudeCode = StateProfile(
        id: "claude-code",
        name: "Claude Code",
        outputPatterns: [
            "Do you want to proceed\\?",
            "Allow .* to",
            "\\(y[/\\|]n\\)",
            "\\(Y[/\\|]n\\)",
            "Press Enter to",
            "Do you want to create",
            "Would you like",
            "Approve\\?",
            "approve this",
            "\\? \\(yes/no\\)",
            "Continue\\?",
            "Overwrite\\?",
        ],
        commandPattern: "claude",
        quickKeys: [
            QuickKey(id: "y", label: "Yes", keys: "y", isEnter: true),
            QuickKey(id: "n", label: "No", keys: "n", isEnter: true),
            QuickKey(id: "enter", label: "↵", keys: "", isEnter: true),
            QuickKey(id: "esc", label: "Esc", keys: "\u{1b}", isEnter: false),
        ],
        isBuiltIn: true,
        // Precise region/priority engine (preset data; was hardcoded in
        // AgentStatusRules). Drives working/idle/blocked from a clean snapshot.
        agentRules: .claudeCode,
        // A user-turn starts at a line `❯ ` (U+276F + ASCII space + content).
        // The live empty prompt is `❯`+NBSP, so requiring an ASCII space excludes it.
        promptBoundary: ["^\\s*\\x{276F}\\x{20}"]
    )

    public static let genericShell = StateProfile(
        id: "shell",
        name: "Shell",
        outputPatterns: [
            "\\[y/N\\]",
            "\\[Y/n\\]",
            "Continue\\?",
            "\\(yes/no\\)",
            "Are you sure",
            "Proceed\\?",
            "Overwrite .* \\?",
            "\\(y/n\\)",
        ],
        commandPattern: nil,
        quickKeys: [
            QuickKey(id: "y", label: "Y", keys: "y", isEnter: true),
            QuickKey(id: "n", label: "N", keys: "n", isEnter: true),
            QuickKey(id: "enter", label: "↵", keys: "", isEnter: true),
        ],
        isBuiltIn: true
    )

    public static let codex = StateProfile(
        id: "codex",
        name: "Codex",
        outputPatterns: [
            "Allow .* to",
            "Do you want to proceed\\?",
            "\\(y[/\\|]n\\)",
            "\\(Y[/\\|]n\\)",
            "Approve\\?",
            "Apply this (change|patch)\\?",
            "Run this command\\?",
            "Press Enter to",
            "Continue\\?",
        ],
        commandPattern: "codex",
        quickKeys: [
            QuickKey(id: "y", label: "Yes", keys: "y", isEnter: true),
            QuickKey(id: "n", label: "No", keys: "n", isEnter: true),
            QuickKey(id: "enter", label: "↵", keys: "", isEnter: true),
            QuickKey(id: "esc", label: "Esc", keys: "\u{1b}", isEnter: false),
        ],
        isBuiltIn: true,
        // Full three-state rules (title spinner / Action Required / prompt-
        // marker-scoped forms). Turn boundary: a `› ` user-input line.
        agentRules: .codex,
        promptBoundary: ["^\\s*\\x{203A}\\x{20}"]
    )

    // The profiles below carry the region/priority rule engine for their agent
    // (AgentRulePresets.swift — evidence cross-referenced from herdr manifests,
    // pending first-hand calibration). Legacy outputPatterns stay minimal: the
    // rich rules run first for recognized commands; the patterns are only the
    // fallback if identity fails.

    public static let gemini = StateProfile(
        id: "gemini",
        name: "Gemini CLI",
        outputPatterns: ["Apply this change", "Allow execution", "Do you want to proceed\\?"],
        commandPattern: "gemini",
        quickKeys: agentQuickKeys,
        isBuiltIn: true,
        agentRules: .gemini
    )

    public static let opencode = StateProfile(
        id: "opencode",
        name: "OpenCode",
        outputPatterns: ["Permission required"],
        commandPattern: "opencode",
        quickKeys: agentQuickKeys,
        isBuiltIn: true,
        agentRules: .opencode
    )

    public static let hermes = StateProfile(
        id: "hermes",
        name: "Hermes",
        outputPatterns: ["dangerous command", "allow once"],
        commandPattern: "hermes",
        quickKeys: agentQuickKeys,
        isBuiltIn: true,
        agentRules: .hermes
    )

    public static let antigravity = StateProfile(
        id: "antigravity",
        name: "Antigravity",
        outputPatterns: ["requesting permission for:"],
        commandPattern: "agy",
        quickKeys: agentQuickKeys,
        isBuiltIn: true,
        agentRules: .antigravity
    )

    public static let cursorAgent = StateProfile(
        id: "cursor-agent",
        name: "Cursor Agent",
        outputPatterns: ["waiting for approval", "Run this command\\?", "write to this file\\?"],
        commandPattern: "cursor-agent",
        quickKeys: agentQuickKeys,
        isBuiltIn: true,
        agentRules: .cursorAgent
    )

    public static let copilot = StateProfile(
        id: "copilot",
        name: "Copilot CLI",
        outputPatterns: [],
        commandPattern: "copilot",
        quickKeys: agentQuickKeys,
        isBuiltIn: true,
        agentRules: .copilot
    )

    public static let amp = StateProfile(
        id: "amp",
        name: "Amp",
        outputPatterns: ["waiting for approval", "Run this command\\?"],
        commandPattern: "amp",
        quickKeys: agentQuickKeys,
        isBuiltIn: true,
        agentRules: .amp
    )

    public static let cline = StateProfile(
        id: "cline",
        name: "Cline",
        outputPatterns: ["use this tool\\?", "Execute command\\?"],
        commandPattern: "cline",
        quickKeys: agentQuickKeys,
        isBuiltIn: true,
        agentRules: .cline
    )

    // commandPattern "vim" matches vim / nvim / gvim (substring). Vim is always
    // interactive, so only the explicit blocking prompts (swap-file, more-prompt,
    // y/n confirms) count as awaiting — ordinary editing stays "working".
    public static let vim = StateProfile(
        id: "vim",
        name: "Vim",
        outputPatterns: [
            "Press ENTER or type command to continue",
            "E325: ATTENTION",
            "Swap file .* already exists",
            "\\[O\\]pen Read-Only",
            "\\(R\\)ecover",
            "Save changes\\?",
            "overwrite existing file",
            "\\(y/n\\)",
            "\\[Y\\]es, \\(N\\)o",
        ],
        commandPattern: "vim",
        quickKeys: [
            QuickKey(id: "enter", label: "↵", keys: "", isEnter: true),
            QuickKey(id: "y", label: "y", keys: "y", isEnter: false),
            QuickKey(id: "n", label: "n", keys: "n", isEnter: false),
            QuickKey(id: "esc", label: "Esc", keys: "\u{1b}", isEnter: false),
        ],
        isBuiltIn: true
    )

    public static let gitInteractive = StateProfile(
        id: "git",
        name: "Git Interactive",
        outputPatterns: [
            "Stage this hunk",
            "Discard this hunk",
            "Apply this hunk",
            "Stash this hunk",
        ],
        commandPattern: "git",
        quickKeys: [
            QuickKey(id: "y", label: "y", keys: "y", isEnter: true),
            QuickKey(id: "n", label: "n", keys: "n", isEnter: true),
            QuickKey(id: "q", label: "q", keys: "q", isEnter: true),
            QuickKey(id: "a", label: "a", keys: "a", isEnter: true),
            QuickKey(id: "s", label: "s", keys: "s", isEnter: true),
        ],
        isBuiltIn: true
    )
}

/// Backward compatibility
@MainActor
public enum BuiltInProfiles {
    public static var all: [StateProfile] { ProfileStore.shared.profiles }
}
