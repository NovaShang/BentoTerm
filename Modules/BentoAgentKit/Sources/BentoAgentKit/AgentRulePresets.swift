import Foundation

// Built-in agent rule sets for every recognized agent (the schema + engine
// live in AgentStatusRules.swift). One authoring discipline for all sets; the
// evidence source differs:
//   * Claude's rules are authored from first-hand `capture-pane` evidence
//     (verified on live sessions).
//   * The other agents' UI invariants (which strings each agent shows while
//     working / when a permission form is up) are cross-referenced from the
//     public detection manifests of herdr (github.com/ogulcancelik/herdr,
//     AGPL-3.0) — used as FACTUAL reference about third-party agent UIs, and
//     re-expressed here in our own schema/structure/priorities. The matched
//     strings are the agents' own interface text, not herdr's expression.
//   * Per-set comments mark calibration status; "pending live calibration"
//     means not yet verified against our own capture-pane pipeline — treat
//     mismatches as calibration bugs, not user error.
//
// Priority conventions (claudeCode is the reference): title signals ~1100–1050,
// transient-overlay skips ~1000, strong on-screen blocker forms ~900, weak
// blockers ~600, working hints ~500–100, idle markers lowest.

extension AgentRuleSet {

    // MARK: - Registry

    /// Every built-in rule set the detector should know about. Order matters
    /// only for identity resolution ties (first match wins); keep the
    /// best-calibrated sets first.
    static let builtIns: [AgentRuleSet] = [
        .claudeCode, .codex, .gemini, .opencode, .hermes,
        .antigravity, .cursorAgent, .copilot, .amp, .cline,
    ]

    /// Claude Code. Verified on a live session 2026-06-21:
    ///   * working → title prefix is an animated braille spinner (U+2800–28FF);
    ///     the footer shows `esc to interrupt`, a live status line `· Inferring…`.
    ///   * idle    → title prefix is `✳` (U+2733); an empty `❯` input box sits
    ///     between two `───` rules; footer shows `shift+tab to cycle` etc.
    ///   * blocked → a permission/selection form: `Do you want to proceed?` with
    ///     numbered `1. Yes` / `2. No` options, or `enter to select`/`esc to
    ///     cancel`. Blocked/overlay evidence cross-referenced against herdr's
    ///     field-tested claude manifest (see this file's header); final
    ///     first-hand calibration of the bash-permission form still open.
    static let claudeCode = AgentRuleSet(
        id: "claude-code",
        commandPatterns: ["claude"],
        titleIdentity: [],
        rules: [
            // Working: animated braille spinner in the title. Highest confidence.
            DetectRule(id: "title_working_spinner", status: .working, priority: 1100,
                       region: .oscTitle,
                       clause: .regex("^\\s*[\\x{2800}-\\x{28FF}]")),

            // Working corroboration when the title isn't a spinner: the live
            // footer/status line only appears while generating.
            DetectRule(id: "footer_working", status: .working, priority: 1050,
                       region: .bottomNonEmptyLines(4),
                       clause: .containsAny(["esc to interrupt"])),

            // Transcript viewer (ctrl+o) — a scrolling overlay, not a state
            // change. Skip so browsing history can't flip the pane state.
            DetectRule(id: "transcript_viewer", status: nil, priority: 1000,
                       region: .bottomNonEmptyLines(3),
                       clause: .all([
                           .contains(["showing detailed transcript"]),
                           .any([
                               .contains(["ctrl+o", "to toggle"]),
                               .contains(["ctrl+e", "show all"]),
                               .contains(["ctrl+e", "collapse"]),
                               .containsAny(["↑↓ scroll", "? for shortcuts"]),
                           ]),
                       ])),

            // Model picker (/model) — a transient menu, not a blocker.
            DetectRule(id: "model_picker", status: nil, priority: 950,
                       region: .wholeSnapshot,
                       clause: .all([
                           .contains(["select model", "enter to set as default", "esc to cancel"]),
                           .not(.containsAny(["do you want to proceed?", "enter to select"])),
                       ])),

            // Blocked: the bash-command permission form, corroborated by its
            // distinctive chrome (tab to amend / ctrl+e to explain) plus the
            // numbered yes/no option lines.
            DetectRule(id: "bash_permission_prompt", status: .blocked, priority: 910,
                       region: .wholeSnapshot,
                       clause: .all([
                           .contains(["do you want to proceed?"]),
                           .containsAny(["bash command", "bash(", "contains expansion",
                                         "tab to amend", "ctrl+e to explain"]),
                           .any([
                               .lineRegex("^\\s*❯?\\s*1\\.\\s*yes\\b"),
                               .lineRegex("^\\s*2\\.\\s*no\\b"),
                           ]),
                       ])),

            // Blocked: an actual permission form on screen. Scoped to
            // the bottom of the screen so prose in the conversation above can't
            // false-trigger it.
            DetectRule(id: "permission_prompt", status: .blocked, priority: 900,
                       region: .bottomNonEmptyLines(18),
                       clause: .all([
                           .containsAny(["do you want to proceed?", "do you want to make this edit",
                                         "do you want to create", "would you like to proceed"]),
                           .any([
                               .lineRegex("(?i)^\\s*❯?\\s*1\\.\\s*yes"),
                               .lineRegex("(?i)^\\s*2\\.\\s*no"),
                               .containsAny(["esc to cancel", "enter to confirm"]),
                           ]),
                       ])),

            // Blocked: a selection form (navigation + select/cancel controls).
            DetectRule(id: "selection_form", status: .blocked, priority: 880,
                       region: .afterLastHorizontalRule,
                       clause: .all([
                           .contains(["esc to cancel"]),
                           .containsAny(["enter to select", "enter to confirm"]),
                           .containsAny(["to navigate", "↑/↓", "↑↓", "arrow keys"]),
                       ])),

            // Idle: the empty input box is showing (a lone `❯`) and none of the
            // blocker controls are present — high-confidence "your turn".
            DetectRule(id: "idle_prompt_box", status: .idle, priority: 800,
                       region: .promptBoxBody,
                       clause: .all([
                           .lineRegex("^\\s*❯"),
                           .not(.containsAny(["do you want to", "esc to cancel",
                                              "enter to select", "to navigate"])),
                       ])),

            // Blocked, low-confidence catch-all: permission chrome that leaked
            // past the structured forms above. The `not` guard (an empty live
            // `❯` prompt anywhere) keeps ordinary conversation prose about
            // permissions from false-triggering once the turn has ended.
            DetectRule(id: "legacy_permission_catchall", status: .blocked, priority: 300,
                       region: .wholeSnapshot,
                       clause: .all([
                           .containsAny(["waiting for permission", "tab to amend",
                                         "ctrl+e to explain", "review your answers",
                                         "do you want to allow this connection?"]),
                           .not(.regex("(?m)^\\s*❯\\s*$")),
                       ])),

            // Idle: the `✳` at-rest marker in the title (lowest priority — a
            // visible blocker form above always wins).
            DetectRule(id: "title_idle_marker", status: .idle, priority: 250,
                       region: .oscTitle,
                       clause: .regex("^\\s*\\x{2733}")),
        ]
    )

    /// OpenAI Codex CLI. Full three-state: OSC title carries both a braille
    /// spinner (working) and an explicit "Action Required" (blocked); the
    /// prompt marker is a `›` line, so form rules scope below the last one.
    static let codex = AgentRuleSet(
        id: "codex",
        commandPatterns: ["codex"],
        titleIdentity: [],
        rules: [
            DetectRule(id: "title_blocked", status: .blocked, priority: 1100,
                       region: .oscTitle,
                       clause: .contains(["Action Required"])),
            DetectRule(id: "title_working_spinner", status: .working, priority: 1050,
                       region: .oscTitle,
                       clause: .regex("^[\\x{2800}-\\x{28FF}] ")),
            // Transcript viewer overlay — scrolling history, not a state change.
            DetectRule(id: "transcript_viewer", status: nil, priority: 1000,
                       region: .afterLastPromptMarker,
                       clause: .all([
                           .contains(["↑/↓ to scroll", "pgup/pgdn to", "home/end to jump", "q to quit"]),
                           .any([.contains(["esc to edit prev"]), .contains(["esc/← to edit prev"])]),
                       ])),
            DetectRule(id: "strong_blocker_form", status: .blocked, priority: 900,
                       region: .afterLastPromptMarker,
                       clause: .containsAny([
                           "press enter to confirm or esc to cancel",
                           "enter to submit answer",
                           "enter to submit all",
                           "allow command?",
                       ])),
            DetectRule(id: "weak_blocker", status: .blocked, priority: 600,
                       region: .wholeSnapshot,
                       clause: .any([
                           .containsAny(["[y/n]", "yes (y)"]),
                           .all([.contains(["do you want to"]),
                                 .any([.contains(["yes"]), .contains(["❯"])])]),
                           .all([.contains(["would you like to"]),
                                 .any([.contains(["yes"]), .contains(["❯"])])]),
                       ])),
            // Idle: a non-empty title that is neither spinner nor blocked.
            DetectRule(id: "title_idle", status: .idle, priority: 100,
                       region: .oscTitle,
                       clause: .all([
                           .regex("\\S"),
                           .not(.regex("^[\\x{2800}-\\x{28FF}]")),
                           .not(.contains(["Action Required"])),
                       ])),
        ]
    )

    /// Google Gemini CLI. Live-calibrated 2026-07-07: gemini is a Node app, so
    /// `pane_current_command` reports "node" — command identity never matches
    /// and the TITLE is the identity ("◇  Ready (dir)" at rest). The same
    /// node-not-binary trap likely applies to the other JS CLIs (copilot,
    /// cline, cursor-agent, amp) — their identities are pending the same
    /// calibration.
    static let gemini = AgentRuleSet(
        id: "gemini",
        commandPatterns: ["gemini"],
        titleIdentity: ["^◇\\s"],
        rules: [
            DetectRule(id: "apply_or_allow_form", status: .blocked, priority: 900,
                       region: .wholeSnapshot,
                       clause: .any([
                           .contains(["│ Apply this change"]),
                           .contains(["│ Allow execution"]),
                           .all([.contains(["yes"]),
                                 .containsAny(["waiting for user confirmation",
                                               "│ Do you want to proceed",
                                               "do you want to proceed?"])]),
                           .lineRegex("^\\s*❯.*(yes|allow)"),
                       ])),
            // First-run ToS / auth pickers (live capture 2026-07-07): a boxed
            // selection list with "(Use Enter to select)" — waiting on you.
            DetectRule(id: "selection_picker", status: .blocked, priority: 850,
                       region: .wholeSnapshot,
                       clause: .contains(["(Use Enter to select)"])),
            DetectRule(id: "cancel_hint_working", status: .working, priority: 100,
                       region: .wholeSnapshot,
                       clause: .contains(["esc to cancel"])),
            // Title "◇  Ready …" is gemini's at-rest marker (live capture).
            DetectRule(id: "title_ready_idle", status: .idle, priority: 90,
                       region: .oscTitle,
                       clause: .regex("^◇\\s+Ready")),
        ]
    )

    /// OpenCode. (Pending live calibration.)
    static let opencode = AgentRuleSet(
        id: "opencode",
        commandPatterns: ["opencode"],
        titleIdentity: [],
        rules: [
            DetectRule(id: "permission_required", status: .blocked, priority: 900,
                       region: .wholeSnapshot,
                       clause: .any([
                           .contains(["△ Permission required"]),
                           .all([
                               .contains(["esc dismiss"]),
                               .containsAny(["enter confirm", "enter submit", "enter toggle"]),
                               .containsAny(["↑↓ select", "⇆ tab"]),
                           ]),
                       ])),
            DetectRule(id: "interrupt_hint_working", status: .working, priority: 110,
                       region: .wholeSnapshot,
                       clause: .any([
                           .containsAny(["esc to interrupt", "ctrl+c to interrupt",
                                         "press esc to interrupt"]),
                           // No leading `.*`: `firstMatch` already searches the
                           // whole line, but the wildcard makes ICU retry from
                           // every offset with a backtracking `.*` — quadratic
                           // in line length. `capture-pane -J` joins wrapped
                           // lines, so one streamed paragraph is a single very
                           // long line and a poll costs hundreds of ms on the
                           // main thread. Anchoring on the literal lets ICU
                           // skip straight to "opencode".
                           .lineRegex("opencode.*esc (again to )?interrupt"),
                       ])),
            DetectRule(id: "progress_bar_working", status: .working, priority: 100,
                       region: .wholeSnapshot,
                       clause: .regex("(■|⬝){4,}")),
        ]
    )

    /// Hermes Agent. (Pending live calibration.)
    static let hermes = AgentRuleSet(
        id: "hermes",
        commandPatterns: ["hermes"],
        titleIdentity: [],
        rules: [
            DetectRule(id: "dangerous_command_approval", status: .blocked, priority: 900,
                       region: .wholeSnapshot,
                       clause: .all([
                           .any([
                               .contains(["dangerous command"]),
                               .contains(["allow once", "allow for this session", "deny"]),
                           ]),
                           .containsAny(["enter to confirm", "↑/↓ to select", "show full command"]),
                       ])),
            DetectRule(id: "interrupt_status_working", status: .working, priority: 100,
                       region: .wholeSnapshot,
                       clause: .containsAny(["msg=interrupt", "ctrl+c cancel"])),
        ]
    )

    /// Antigravity (`agy`). (Pending live calibration.)
    static let antigravity = AgentRuleSet(
        id: "antigravity",
        commandPatterns: ["agy", "antigravity"],
        titleIdentity: [],
        rules: [
            DetectRule(id: "permission_prompt", status: .blocked, priority: 900,
                       region: .wholeSnapshot,
                       clause: .all([
                           .contains(["requesting permission for:"]),
                           .any([
                               .contains(["do you want to proceed?"]),
                               .contains(["tab amend", "edit command"]),
                           ]),
                       ])),
            // A braille spinner followed by a gerund ("⠸ Thinking…").
            DetectRule(id: "spinner_working", status: .working, priority: 100,
                       region: .wholeSnapshot,
                       clause: .lineRegex("^\\s*[\\x{2800}-\\x{28FF}]+\\s+\\w+ing\\b")),
            DetectRule(id: "background_tasks_working", status: .working, priority: 90,
                       region: .bottomNonEmptyLines(5),
                       clause: .lineRegex("·\\s*[1-9][0-9]*\\s+task")),
        ]
    )

    /// Cursor Agent CLI. (Pending live calibration.)
    static let cursorAgent = AgentRuleSet(
        id: "cursor-agent",
        commandPatterns: ["cursor-agent", "cursor"],
        titleIdentity: [],
        rules: [
            DetectRule(id: "write_file_approval", status: .blocked, priority: 920,
                       region: .bottomNonEmptyLines(8),
                       clause: .all([
                           .contains(["write to this file?", "proceed (y)"]),
                           .containsAny(["reject & propose changes", "esc or n or p", "add write("]),
                       ])),
            DetectRule(id: "approval_prompt", status: .blocked, priority: 900,
                       region: .wholeSnapshot,
                       clause: .any([
                           .all([
                               .contains(["waiting for approval", "run this command?"]),
                               .containsAny(["run (once) (y)", "skip (esc or n)"]),
                           ]),
                           .containsAny(["(y) (enter)", "keep (n)", "skip (esc or n)"]),
                           .lineRegex("^\\s*allow .*\\(y\\)"),
                           .lineRegex("^\\s*(run |.*\\(y\\).*(allow|run \\(once\\)|→ run))"),
                       ])),
            DetectRule(id: "stop_hint_working", status: .working, priority: 100,
                       region: .bottomNonEmptyLines(6),
                       clause: .contains(["ctrl+c to stop"])),
            DetectRule(id: "background_tasks_working", status: .working, priority: 95,
                       region: .bottomNonEmptyLines(5),
                       clause: .lineRegex("\\b[1-9][0-9]*\\s+background\\s+tasks?\\b")),
            DetectRule(id: "spinner_working", status: .working, priority: 90,
                       region: .bottomNonEmptyLines(8),
                       clause: .lineRegex("^\\s*(⬡|⬢|[\\x{2800}-\\x{28FF}]+)\\s+\\w+ing\\b")),
        ]
    )

    /// GitHub Copilot CLI. Working and blocked share "esc to cancel" — the
    /// blocked form is distinguished by an enter-to-select/confirm control and
    /// simply outranks the working hint. (Pending live calibration.)
    static let copilot = AgentRuleSet(
        id: "copilot",
        commandPatterns: ["copilot"],
        titleIdentity: [],
        rules: [
            DetectRule(id: "selection_blocker", status: .blocked, priority: 900,
                       region: .wholeSnapshot,
                       clause: .all([
                           .containsAny(["esc to cancel", "esc cancel"]),
                           .containsAny(["enter to select", "enter to confirm",
                                         "enter to submit", "enter accept"]),
                       ])),
            DetectRule(id: "cancel_hint_working", status: .working, priority: 100,
                       region: .wholeSnapshot,
                       clause: .containsAny(["esc to cancel", "esc cancel",
                                             "esc again to cancel", "esc interrupt"])),
        ]
    )

    /// Sourcegraph Amp. (Pending live calibration.)
    static let amp = AgentRuleSet(
        id: "amp",
        commandPatterns: ["amp"],
        titleIdentity: [],
        rules: [
            DetectRule(id: "approval_footer", status: .blocked, priority: 900,
                       region: .wholeSnapshot,
                       clause: .any([
                           .containsAny(["waiting for approval", "invoke tool",
                                         "run this command?", "allow editing file:",
                                         "allow creating file:", "confirm tool call"]),
                           .all([
                               .contains(["approve"]),
                               .containsAny(["allow all for this session",
                                             "allow all for every session",
                                             "allow file for every session",
                                             "deny with feedback"]),
                           ]),
                       ])),
            DetectRule(id: "cancel_hint_working", status: .working, priority: 100,
                       region: .wholeSnapshot,
                       clause: .contains(["esc to cancel"])),
        ]
    )

    /// Cline CLI. Only the permission form is distinctive; working/idle fall
    /// back to output-activity detection (better than herdr's "always working"
    /// default, which never reads idle). (Pending live calibration.)
    static let cline = AgentRuleSet(
        id: "cline",
        commandPatterns: ["cline"],
        titleIdentity: [],
        rules: [
            DetectRule(id: "tool_permission", status: .blocked, priority: 900,
                       region: .wholeSnapshot,
                       clause: .any([
                           .contains(["let cline use this tool"]),
                           .all([.containsAny(["[act mode]", "[plan mode]"]),
                                 .containsAny(["execute command?", "use this tool?"]),
                                 .contains(["yes"])]),
                       ])),
        ]
    )
}
