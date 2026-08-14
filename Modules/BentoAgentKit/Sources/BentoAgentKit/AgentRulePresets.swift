import Foundation

// Built-in agent rule sets for every recognized agent (the schema + engine
// live in AgentStatusRules.swift). One authoring discipline for all sets; the
// evidence source differs:
//   * Claude, Codex, OpenCode and Gemini are authored from first-hand
//     `capture-pane` evidence on live sessions. Codex and OpenCode were
//     calibrated 2026-08-13 and their captures are checked in as test
//     fixtures (BentoAgentKitTests/Fixtures) — see LiveCaptureTests.
//   * The other agents' UI invariants (which strings each agent shows while
//     working / when a permission form is up) are cross-referenced from the
//     public detection manifests of herdr (github.com/ogulcancelik/herdr,
//     AGPL-3.0) — used as FACTUAL reference about third-party agent UIs, and
//     re-expressed here in our own schema/structure/priorities. The matched
//     strings are the agents' own interface text, not herdr's expression.
//     Last synced against herdr @ 9351b05 (2026-08-14 manifests).
//   * Per-set comments mark calibration status; "pending live calibration"
//     means not yet verified against our own capture-pane pipeline — treat
//     mismatches as calibration bugs, not user error.
//
// The lesson from the 2026-08-13 calibration, worth repeating before editing
// anything here: BOTH failures were invisible to the hand-written tests.
// codex's rules had never run at all (it reports as `node`, so identity never
// matched), and opencode's working footer says "esc interrupt", not the
// "esc to interrupt" the rules assumed. A rule set is a claim about another
// program's UI — capture the screen before believing it.
//
// Priority conventions (claudeCode is the reference): title signals ~1100–1050,
// transient-overlay skips ~1000, strong on-screen blocker forms ~900, weak
// blockers ~600, working hints ~500–100, idle markers lowest.
//
// Rules the user adds in Settings are given priority `customRulePriority`
// (above every built-in), so "my agent shows THIS when it's waiting" wins
// without the user having to reason about the ladder above.

extension AgentRuleSet {

    /// Where a user-authored rule sits in the ladder: above everything
    /// built-in, with room left over. Built-ins have already reached 1300
    /// (grok's title rules), so this is deliberately far clear of the top —
    /// `testCustomRulePriorityIsAboveEveryBuiltIn` fails if a preset ever
    /// catches up.
    public static let customRulePriority = 2000

    // MARK: - Registry

    /// Every built-in rule set the detector should know about. Order matters
    /// only for identity resolution ties (first match wins); keep the
    /// best-calibrated sets first.
    static let builtIns: [AgentRuleSet] = [
        .claudeCode, .codex, .gemini, .opencode, .hermes,
        .antigravity, .cursorAgent, .copilot, .amp, .cline,
        .droid, .qwen, .grok, .kimi,
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
        titleIdentity: ["Claude Code"],
        rules: [
            // Working: animated spinner in the title. Highest confidence.
            // Braille is the spinner up to Claude Code 2.1.227; the quartered
            // circles are the one 2.1.228 switched to (herdr manifest
            // 2026-08-13). Matching both means the newer build doesn't read as
            // permanently idle.
            DetectRule(id: "title_working_spinner", status: .working, priority: 1100,
                       region: .oscTitle,
                       clause: .regex("^\\s*[\\x{2800}-\\x{28FF}\\x{25D0}-\\x{25D3}]")),

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

            // The `/btw` side-channel overlay sits over a turn that is still
            // running — its own "esc to close" hint replaces the usual working
            // footer, so without this the pane reads idle mid-turn.
            DetectRule(id: "btw_overlay_working", status: .working, priority: 975,
                       region: .bottomNonEmptyLines(5),
                       clause: .all([
                           .lineRegex("^\\s*/btw(?:\\s|$)"),
                           .lineRegex("esc to close\\s*$"),
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
            // false-trigger it. The numbered-option variants come from herdr's
            // generic_permission_prompt — Claude renumbers the options when a
            // form offers "yes, and don't ask again".
            DetectRule(id: "permission_prompt", status: .blocked, priority: 900,
                       region: .bottomNonEmptyLines(18),
                       clause: .all([
                           .containsAny(["do you want to proceed?", "do you want to make this edit",
                                         "do you want to create", "would you like to proceed"]),
                           .any([
                               .lineRegex("(?i)^\\s*❯?\\s*1\\.\\s*yes"),
                               .lineRegex("(?i)^\\s*2\\.\\s*yes"),
                               .lineRegex("(?i)^\\s*2\\.\\s*no"),
                               .lineRegex("(?i)^\\s*3\\.\\s*no"),
                               .containsAny(["esc to cancel", "enter to confirm"]),
                           ]),
                       ])),

            // Blocked: the dynamic-workflow confirmation, which has no numbered
            // options and no ❯ box to key off.
            DetectRule(id: "dynamic_workflow_prompt", status: .blocked, priority: 890,
                       region: .wholeSnapshot,
                       clause: .contains(["run a dynamic workflow?", "esc to cancel"])),

            // Blocked: a selection form (navigation + select/cancel controls).
            DetectRule(id: "selection_form", status: .blocked, priority: 880,
                       region: .afterLastHorizontalRule,
                       clause: .all([
                           .contains(["esc to cancel"]),
                           .containsAny(["enter to select", "enter to confirm"]),
                           .containsAny(["to navigate", "↑/↓", "↑↓", "arrow keys", "tab/arrow"]),
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
                                         "skip interview and plan immediately",
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

    /// OpenAI Codex CLI. Live-calibrated against codex-cli 0.147.0 on
    /// 2026-08-13 (fixtures: Tests/Fixtures/codex-*).
    ///
    /// **Identity was the whole bug.** Homebrew's codex is `node
    /// /opt/homebrew/bin/codex`, so `pane_current_command` is `node` and the
    /// old `commandPatterns: ["codex"]` NEVER matched — every rule below was
    /// dead code and codex panes fell through to activity detection. Codex is
    /// therefore identified three ways, in the order they become available:
    ///   * the launch screen's banner (`screenIdentity`) — covers the fresh
    ///     pane and the trust prompt, before any turn has run;
    ///   * the title, the moment a turn starts (spinner) or blocks
    ///     ("Action Required");
    ///   * and thereafter the sticky identity the detector remembers per pane.
    ///
    /// Observed title states: idle `work` (the cwd basename — nothing to match
    /// on), working `⠴ work`, blocked `[ ! ] Action Required | work`. The
    /// spinner runs for the whole turn (measured at 2 Hz for 11s of streaming),
    /// so the title is the reliable working signal — this codex prints no
    /// persistent footer, and its `• Working (…esc to interrupt)` line is
    /// visible only for the first second or two of a turn.
    static let codex = AgentRuleSet(
        id: "codex",
        commandPatterns: ["codex"],
        titleIdentity: ["Action Required", "(?:^|\\s)[\\x{2800}-\\x{28FF}](?:\\s|$)"],
        // The banner covers a fresh pane; the composer placeholder covers
        // attaching to a session whose banner has long scrolled away, which is
        // what you get every time the app reconnects to a running codex.
        screenIdentity: ["OpenAI Codex", "Welcome to Codex",
                         "Find and fix a bug in @filename"],
        rules: [
            DetectRule(id: "title_blocked", status: .blocked, priority: 1100,
                       region: .oscTitle,
                       clause: .contains(["Action Required"])),
            // Not anchored at ^: 0.147 prefixes the title with markers (the
            // blocked title is `[ ! ] Action Required | work`), so the spinner
            // is not always the first character.
            DetectRule(id: "title_working_spinner", status: .working, priority: 1050,
                       region: .oscTitle,
                       clause: .regex("(?:^|\\s)[\\x{2800}-\\x{28FF}](?:\\s|$)")),
            // Transcript viewer overlay — scrolling history, not a state change.
            DetectRule(id: "transcript_viewer", status: nil, priority: 1000,
                       region: .afterLastPromptMarker,
                       clause: .all([
                           .contains(["↑/↓ to scroll", "pgup/pgdn to", "home/end to jump", "q to quit"]),
                           .any([.contains(["esc to edit prev"]), .contains(["esc/← to edit prev"])]),
                       ])),
            // The first-run "Do you trust the contents of this directory?"
            // gate. A fresh pane that opens straight into this is blocked, not
            // idle — and it is the one blocked state that shows up before codex
            // has ever set a spinner title, so it carries the launch banner
            // with it (that's what identifies the pane at all).
            DetectRule(id: "trust_directory", status: .blocked, priority: 950,
                       region: .topNonEmptyLines(24),
                       clause: .all([
                           .contains(["do you trust the contents of this directory?"]),
                           .containsAny(["you are in", "1. yes, continue", "press enter to continue"]),
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
            // The live status line, shown for the first seconds of a turn
            // before streamed text pushes it off. Corroborates working when the
            // title poll happens to land between spinner frames.
            DetectRule(id: "screen_working_fallback", status: .working, priority: 500,
                       region: .bottomNonEmptyLines(3),
                       clause: .all([
                           .lineRegex("^\\s*[•◦]\\s+Working \\("),
                           .not(.contains(["conversation interrupted"])),
                       ])),
            // Idle: a non-empty title that is neither spinner nor blocked.
            DetectRule(id: "title_idle", status: .idle, priority: 100,
                       region: .oscTitle,
                       clause: .all([
                           .regex("\\S"),
                           .not(.regex("(?:^|\\s)[\\x{2800}-\\x{28FF}](?:\\s|$)")),
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

    /// OpenCode. Live-calibrated against opencode 1.18.5 on 2026-08-13
    /// (fixtures: Tests/Fixtures/opencode-*).
    ///
    /// Identity holds by command (`pane_current_command` is `opencode.exe`,
    /// which still contains "opencode"). What did NOT hold was the footer
    /// wording taken from herdr's 2026-06 manifest: this build writes
    /// **`esc interrupt`**, not "esc to interrupt", so the only thing keeping
    /// working detection alive was the progress-bar rule. Idle had no rule at
    /// all and fell through to activity detection, which is why a finished
    /// opencode pane never announced itself.
    ///
    /// Titles are `OpenCode` before the first turn and `OC | <session summary>`
    /// after it — identity, not state, so they are used only for identity.
    static let opencode = AgentRuleSet(
        id: "opencode",
        commandPatterns: ["opencode"],
        titleIdentity: ["^OpenCode\\b", "^OC \\| "],
        rules: [
            DetectRule(id: "permission_required", status: .blocked, priority: 900,
                       region: .wholeSnapshot,
                       clause: .any([
                           .contains(["△ Permission required"]),
                           // 1.18.5's footer for the same form: no "esc
                           // dismiss", so the older shape stays as its own
                           // alternative rather than being tightened into it.
                           .all([
                               .containsAny(["allow once", "allow always"]),
                               .contains(["reject"]),
                               .containsAny(["enter confirm", "⇆ select", "↑↓ select"]),
                           ]),
                           .all([
                               .contains(["esc dismiss"]),
                               .containsAny(["enter confirm", "enter submit", "enter toggle"]),
                               .containsAny(["↑↓ select", "⇆ tab"]),
                           ]),
                       ])),
            DetectRule(id: "interrupt_hint_working", status: .working, priority: 110,
                       region: .wholeSnapshot,
                       clause: .any([
                           .containsAny(["esc interrupt", "esc to interrupt",
                                         "ctrl+c to interrupt", "press esc to interrupt"]),
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
            // Idle: the composer footer with no work markers in it. `ctrl+p
            // commands` is on screen in every state, so the guards are what
            // make it mean idle — and the blocked form replaces that footer
            // entirely (it reads `ctrl+f fullscreen ⇆ select enter confirm`),
            // so a waiting pane can't land here even before priority applies.
            DetectRule(id: "composer_idle", status: .idle, priority: 90,
                       region: .bottomNonEmptyLines(4),
                       clause: .all([
                           .contains(["ctrl+p"]),
                           .not(.containsAny(["esc interrupt", "esc to interrupt"])),
                           .not(.regex("(■|⬝){4,}")),
                       ])),
        ]
    )

    /// Hermes Agent. Now three-state: herdr's 2026-07-24 manifest documents an
    /// OSC title that carries the state as a leading glyph (⚠ blocked, ⏳
    /// working, ✓ idle), which is a far better signal than the screen rules we
    /// had. The variation-selector allowance is theirs too — a terminal may
    /// deliver the emoji or the text presentation of the same glyph.
    /// (Pending live calibration.)
    static let hermes = AgentRuleSet(
        id: "hermes",
        commandPatterns: ["hermes"],
        titleIdentity: [],
        rules: [
            DetectRule(id: "title_blocked", status: .blocked, priority: 1100,
                       region: .oscTitle,
                       clause: .regex("^\\x{26A0}[\\x{FE0E}\\x{FE0F}]?(?:\\s|$)")),
            DetectRule(id: "title_working", status: .working, priority: 1050,
                       region: .oscTitle,
                       clause: .regex("^\\x{23F3}[\\x{FE0E}\\x{FE0F}]?(?:\\s|$)")),
            DetectRule(id: "dangerous_command_approval", status: .blocked, priority: 900,
                       region: .bottomNonEmptyLines(14),
                       clause: .all([
                           .any([
                               .containsAny(["dangerous", "approval"]),
                               .contains(["allow once", "deny"]),
                               .lineRegex("(?i)^\\s*[▸>]?\\s*1\\.\\s*allow"),
                           ]),
                           .containsAny(["enter confirm", "enter to confirm",
                                         "↑/↓ to select", "show full command"]),
                       ])),
            // Hermes asks questions as well as permissions — a clarification
            // dialog is just as blocked as an approval form.
            DetectRule(id: "clarification_prompt", status: .blocked, priority: 890,
                       region: .bottomNonEmptyLines(14),
                       clause: .all([
                           .any([
                               .containsAny(["hermes needs your", "type your answer"]),
                               .lineRegex("^\\s*ask\\s+\\S"),
                           ]),
                           .containsAny(["enter confirm", "enter to confirm", "enter send",
                                         "press enter", "↑/↓ select", "↑/↓ to select",
                                         "other (type"]),
                       ])),
            DetectRule(id: "credential_prompt", status: .blocked, priority: 880,
                       region: .bottomNonEmptyLines(14),
                       clause: .containsAny(["sudo password", "skill setup"])),
            DetectRule(id: "interrupt_status_working", status: .working, priority: 500,
                       region: .bottomNonEmptyLines(5),
                       clause: .containsAny(["msg=interrupt", "ctrl+c to interrupt",
                                             "ctrl+c cancel"])),
            DetectRule(id: "title_idle", status: .idle, priority: 100,
                       region: .oscTitle,
                       clause: .regex("^\\x{2713}[\\x{FE0E}\\x{FE0F}]?(?:\\s|$)")),
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
                           .lineRegex("(?i)^\\s*allow .*\\(y\\)"),
                           // Split out of one combined alternation whose middle
                           // branch was `.*\(y\).*` — anchored, but still
                           // backtracking across a joined 25KB line.
                           .lineRegex("(?i)^\\s*(?:→\\s*)?run .*\\(y\\)"),
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

    /// Sourcegraph Amp. Three-state as of herdr's 2026-07-09 manifest: the OSC
    /// title carries "Plugin confirmation needed", a working spinner, and a
    /// ` - amp - ` idle marker that doubles as identity (amp is a Node CLI, so
    /// `pane_current_command` may well be `node`). (Pending live calibration.)
    static let amp = AgentRuleSet(
        id: "amp",
        commandPatterns: ["amp"],
        titleIdentity: [" - amp - ", "Plugin confirmation needed"],
        rules: [
            DetectRule(id: "title_blocked", status: .blocked, priority: 1100,
                       region: .oscTitle,
                       clause: .contains(["Plugin confirmation needed"])),
            DetectRule(id: "title_working_spinner", status: .working, priority: 1050,
                       region: .oscTitle,
                       clause: .regex("^[\\x{2800}-\\x{28FF}] ")),
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
            // Amp's boxed status footer: `╰ ⠙ thinking ─────`.
            DetectRule(id: "status_footer_working", status: .working, priority: 200,
                       region: .bottomNonEmptyLines(5),
                       clause: .lineRegex("(?i)^\\s*╰\\s+\\S+\\s+(thinking|streaming|running tools|waiting)\\s+─")),
            DetectRule(id: "cancel_hint_working", status: .working, priority: 100,
                       region: .wholeSnapshot,
                       clause: .contains(["esc to cancel"])),
            DetectRule(id: "title_idle", status: .idle, priority: 50,
                       region: .oscTitle,
                       clause: .all([
                           .contains([" - amp - "]),
                           .not(.regex("^[\\x{2800}-\\x{28FF}] ")),
                           .not(.contains(["Plugin confirmation needed"])),
                       ])),
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

    // MARK: - Agents added 2026-08-13 (herdr manifests, pending live calibration)
    //
    // Same discipline as the sets above: the strings are each agent's own
    // interface text, re-expressed in our schema. None has been through our own
    // capture-pane pipeline yet, so treat a mismatch as a calibration bug.

    /// Factory `droid`.
    static let droid = AgentRuleSet(
        id: "droid",
        commandPatterns: ["droid"],
        titleIdentity: [],
        rules: [
            DetectRule(id: "execute_selection_blocker", status: .blocked, priority: 900,
                       region: .wholeSnapshot,
                       clause: .all([
                           .contains(["enter to select", "esc to cancel"]),
                           .containsAny(["↑↓ to navigate", "use ↑↓ to navigate"]),
                           .containsAny(["> yes, allow", "> no, cancel"]),
                       ])),
            DetectRule(id: "selection_menu_blocker", status: .blocked, priority: 890,
                       region: .bottomNonEmptyLines(8),
                       clause: .all([
                           .contains(["enter select", "esc cancel"]),
                           .containsAny(["↑/↓ navigate", "↑↓ navigate"]),
                       ])),
            DetectRule(id: "spinner_stop_working", status: .working, priority: 110,
                       region: .wholeSnapshot,
                       clause: .all([
                           .contains(["esc to stop"]),
                           .lineRegex("^\\s*[\\x{2800}-\\x{28FF}]"),
                       ])),
            DetectRule(id: "stop_hint_working", status: .working, priority: 100,
                       region: .wholeSnapshot,
                       clause: .contains(["esc to stop"])),
        ]
    )

    /// Qwen Code. Its composer stays on screen during a turn, so the input box
    /// is not idle evidence on its own — idle is the composer's placeholder
    /// text, and only after every working/blocked rule has declined.
    static let qwen = AgentRuleSet(
        id: "qwen",
        commandPatterns: ["qwen"],
        titleIdentity: [],
        rules: [
            DetectRule(id: "waiting_for_confirmation", status: .blocked, priority: 1000,
                       region: .bottomNonEmptyLines(20),
                       clause: .contains(["waiting for user confirmation"])),
            DetectRule(id: "tool_confirmation", status: .blocked, priority: 990,
                       region: .bottomNonEmptyLines(20),
                       clause: .all([
                           .contains(["yes, allow once"]),
                           .containsAny(["apply this change?", "allow execution of:",
                                         "allow execution of mcp tool", "do you want to proceed?",
                                         "shell command execution"]),
                       ])),
            DetectRule(id: "question_dialog", status: .blocked, priority: 980,
                       region: .bottomNonEmptyLines(20),
                       clause: .all([
                           .contains(["enter: select", "esc: cancel"]),
                           .lineRegex("^\\s*[❯›]\\s*1\\.\\s+"),
                       ])),
            DetectRule(id: "folder_trust_dialog", status: .blocked, priority: 970,
                       region: .bottomNonEmptyLines(20),
                       clause: .contains(["do you trust this folder?", "trust folder ("])),
            DetectRule(id: "cancel_hint_working", status: .working, priority: 900,
                       region: .bottomNonEmptyLines(8),
                       clause: .lineRegex("^\\s*(?:[\\x{2800}-\\x{28FF}]|\\.{1,2})\\s+.*esc to cancel\\)\\s*$")),
            DetectRule(id: "narrow_cancel_hint_working", status: .working, priority: 890,
                       region: .bottomNonEmptyLines(8),
                       clause: .lineRegex("(?i)^\\s*\\(esc to cancel\\)\\s*$")),
            DetectRule(id: "composer_idle", status: .idle, priority: 100,
                       region: .bottomNonEmptyLines(30),
                       clause: .containsAny(["type your message", "@path/to/file"])),
        ]
    )

    /// Grok Build. Titles are the primary signal (idle is `grok` or
    /// `<session> - grok`), which is also what identifies the pane — grok is a
    /// Node CLI. Its splash screen draws a logo out of braille characters, so
    /// working rules key on the `[stop]` chip rather than on a bare spinner.
    static let grok = AgentRuleSet(
        id: "grok",
        commandPatterns: ["grok"],
        titleIdentity: ["(?:^| - )grok$"],
        rules: [
            DetectRule(id: "title_blocked", status: .blocked, priority: 1300,
                       region: .oscTitle,
                       clause: .contains(["Action Required"])),
            DetectRule(id: "option_dialog_blocked", status: .blocked, priority: 1200,
                       region: .wholeSnapshot,
                       clause: .lineRegex("^\\s*┃\\s+[0-9a-z]+\\s+\\([●○]\\)\\s")),
            DetectRule(id: "permission_hints_blocked", status: .blocked, priority: 1190,
                       region: .bottomNonEmptyLines(2),
                       clause: .contains([":select", "ctrl+o:yolo", "ctrl+c:cancel"])),
            DetectRule(id: "question_dialog_hints_blocked", status: .blocked, priority: 1185,
                       region: .bottomNonEmptyLines(2),
                       clause: .contains(["tab:scrollback", "shift+x:dismiss"])),
            DetectRule(id: "permission_scope_selector", status: .blocked, priority: 1180,
                       region: .wholeSnapshot,
                       clause: .all([
                           .contains(["yes, proceed", "no, reject"]),
                           .containsAny(["use ← → to choose permission whitelist scope", "←/→:scope"]),
                       ])),
            DetectRule(id: "background_work_chip_working", status: .working, priority: 1170,
                       region: .topNonEmptyLines(1),
                       clause: .lineRegex("[⋅:⸬⁙.·]\\s+[1-9][0-9]*\\s+│")),
            DetectRule(id: "title_idle", status: .idle, priority: 1100,
                       region: .oscTitle,
                       clause: .all([
                           .regex("(?:^| - )grok$"),
                           .not(.regex("[\\x{2800}-\\x{28FF}]")),
                       ])),
            // Any other non-empty grok title is a turn in progress.
            DetectRule(id: "title_working", status: .working, priority: 1000,
                       region: .oscTitle,
                       clause: .regex("\\S")),
            DetectRule(id: "spinner_status_working", status: .working, priority: 200,
                       region: .wholeSnapshot,
                       clause: .lineRegex("^\\s*[\\x{2801}-\\x{28FF}]\\s.*\\[stop\\]\\s*$")),
            DetectRule(id: "esc_cancel_hints_working", status: .working, priority: 190,
                       region: .bottomNonEmptyLines(2),
                       clause: .contains(["esc:cancel", "ctrl+.:shortcuts"])),
            DetectRule(id: "prompt_hints_idle", status: .idle, priority: 100,
                       region: .bottomNonEmptyLines(2),
                       clause: .all([
                           .contains(["ctrl+.:shortcuts"]),
                           .not(.containsAny(["esc:cancel", "ctrl+c:cancel"])),
                       ])),
        ]
    )

    /// Kimi Code.
    static let kimi = AgentRuleSet(
        id: "kimi",
        commandPatterns: ["kimi"],
        titleIdentity: [],
        rules: [
            DetectRule(id: "approval_panel", status: .blocked, priority: 900,
                       region: .wholeSnapshot,
                       clause: .all([
                           .contains(["↵ confirm"]),
                           .any([
                               .containsAny(["run this command?", "write this file?",
                                             "apply these edits?", "stop this task?",
                                             "ready to build with this plan?"]),
                               .lineRegex("(?i)^\\s*▶?\\s*approve .*\\?$"),
                           ]),
                           .contains([" choose"]),
                           .containsAny(["approve", "reject", "revise"]),
                       ])),
            DetectRule(id: "question_panel", status: .blocked, priority: 890,
                       region: .wholeSnapshot,
                       clause: .all([
                           .contains(["↑↓ select", "esc cancel"]),
                           .containsAny(["↵ choose", "↵ toggle", "↵ save"]),
                       ])),
            DetectRule(id: "legacy_approval_panel", status: .blocked, priority: 880,
                       region: .wholeSnapshot,
                       clause: .all([
                           .contains(["requesting approval", "reject"]),
                           .containsAny(["approve once", "approve for this session"]),
                           .containsAny(["1/2/3/4 choose", "↵ confirm"]),
                       ])),
            DetectRule(id: "background_agent_status_working", status: .working, priority: 120,
                       region: .bottomNonEmptyLines(3),
                       clause: .lineRegex("(?i)\\bkimi[-\\w.]*\\s+thinking\\b.*\\[[1-9][0-9]*\\s+agents?\\s+running\\]")),
            DetectRule(id: "moon_spinner_working", status: .working, priority: 100,
                       region: .wholeSnapshot,
                       clause: .lineRegex("^\\s*[\\x{1F311}-\\x{1F318}]\\s*$")),
            DetectRule(id: "braille_spinner_working", status: .working, priority: 90,
                       region: .wholeSnapshot,
                       clause: .lineRegex("(?i)^\\s*[\\x{2800}-\\x{28FF}]+\\s*(thinking\\.\\.\\.|working\\.\\.\\.|using )")),
        ]
    )
}
