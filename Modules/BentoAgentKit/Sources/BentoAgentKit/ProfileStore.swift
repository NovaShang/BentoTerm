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
            // delete the broken data. Stamp the backup only once — otherwise a
            // store that keeps failing to decode appends a
            // state_profiles_broken_* key on every launch, accumulating forever.
            let hasBackup = UserDefaults.standard.dictionaryRepresentation().keys
                .contains { $0.hasPrefix("\(storageKey)_broken_") }
            if !hasBackup {
                let stamp = Int(Date().timeIntervalSince1970)
                UserDefaults.standard.set(data, forKey: "\(storageKey)_broken_\(stamp)")
                profileLog.error("Failed to decode state_profiles: \(String(describing: error)). Backed up under state_profiles_broken_\(stamp)")
            }
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
        // boundary existed) pick them up. This is the delivery path for every
        // rule fix we ship, so it runs by default — EXCEPT on profiles the user
        // has edited in Settings, which say so with `agentRulesCustomized`.
        // Other user-editable fields (name/outputPatterns/titlePatterns/
        // quickKeys) are left as stored either way.
        let presetByID = Dictionary(Self.defaultProfiles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for i in profiles.indices where profiles[i].isBuiltIn && !profiles[i].agentRulesCustomized {
            guard let preset = presetByID[profiles[i].id] else { continue }
            // Adopt preset detection logic (idempotent: only writes when
            // different), while carrying over the one switch that isn't logic:
            // "detect this agent at all". Turning an agent off is a standing
            // preference, not an edit to its rules, so it must survive a
            // refresh that improves them.
            var refreshed = preset.agentRules
            if let stored = profiles[i].agentRules {
                refreshed?.isEnabled = stored.isEnabled
            }
            if !sameRules(profiles[i].agentRules, refreshed) {
                profiles[i].agentRules = refreshed
                changed = true
            }
            if profiles[i].promptBoundary != preset.promptBoundary {
                profiles[i].promptBoundary = preset.promptBoundary
                changed = true
            }
        }
        if changed { save() }
    }

    /// Run the built-in refresh against the live store. Only for tests — it's
    /// the launch-time path, and what it must NOT do (overwrite an edit, drop
    /// the off switch) is worth asserting directly.
    func applyBuiltInRefreshForTesting() { mergeMissingBuiltIns() }

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

    // MARK: - Detection rule editing (Settings)

    /// Store an edited rule set and mark the profile as customized, so the
    /// built-in refresh stops overwriting it. Every rules editor goes through
    /// here — forgetting the flag is how a user's edit silently disappears on
    /// the next launch.
    public func updateRules(_ rules: AgentRuleSet, for profileID: String) {
        guard let i = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        profiles[i].agentRules = rules
        profiles[i].agentRulesCustomized = true
        save()
    }

    /// Turn detection for one agent on or off. Deliberately NOT an edit: the
    /// preference is carried across preset refreshes (see mergeMissingBuiltIns),
    /// so switching an agent off doesn't also freeze it on today's rules.
    public func setDetectionEnabled(_ enabled: Bool, for profileID: String) {
        guard let i = profiles.firstIndex(where: { $0.id == profileID }),
              var rules = profiles[i].agentRules, rules.isEnabled != enabled
        else { return }
        rules.isEnabled = enabled
        profiles[i].agentRules = rules
        save()
    }

    /// Drop the user's edits for one agent and take the shipped rules back.
    public func resetRules(for profileID: String) {
        guard let i = profiles.firstIndex(where: { $0.id == profileID }),
              let preset = Self.defaultProfiles.first(where: { $0.id == profileID })
        else { return }
        profiles[i].agentRules = preset.agentRules
        profiles[i].agentRulesCustomized = false
        save()
    }

    /// True when this profile's shipped rules differ from what's stored.
    public func hasPresetRules(for profileID: String) -> Bool {
        Self.defaultProfiles.contains { $0.id == profileID && $0.agentRules != nil }
    }

    // MARK: - Built-in Presets

    // Command-specific profiles are listed before the catch-all `genericShell`;
    // detection also enforces this precedence independent of order (see
    // StateDetectionService.detectState), so a merged-in profile can't be
    // shadowed by the generic one.
    public static let defaultProfiles: [StateProfile] = [
        claudeCode, codex, gemini, opencode, hermes, antigravity,
        cursorAgent, copilot, amp, cline, droid, qwen, grok, kimi,
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
        // AgentRulePresets). Drives working/idle/blocked from a clean snapshot.
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

    public static let droid = StateProfile(
        id: "droid",
        name: "Droid",
        outputPatterns: ["Yes, allow", "esc to stop"],
        commandPattern: "droid",
        quickKeys: agentQuickKeys,
        isBuiltIn: true,
        agentRules: .droid
    )

    public static let qwen = StateProfile(
        id: "qwen",
        name: "Qwen Code",
        outputPatterns: ["Waiting for user confirmation", "Yes, allow once"],
        commandPattern: "qwen",
        quickKeys: agentQuickKeys,
        isBuiltIn: true,
        agentRules: .qwen
    )

    public static let grok = StateProfile(
        id: "grok",
        name: "Grok",
        outputPatterns: ["Yes, proceed", "No, reject"],
        commandPattern: "grok",
        quickKeys: agentQuickKeys,
        isBuiltIn: true,
        agentRules: .grok
    )

    public static let kimi = StateProfile(
        id: "kimi",
        name: "Kimi Code",
        outputPatterns: ["Requesting approval", "Approve once"],
        commandPattern: "kimi",
        quickKeys: agentQuickKeys,
        isBuiltIn: true,
        agentRules: .kimi
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
