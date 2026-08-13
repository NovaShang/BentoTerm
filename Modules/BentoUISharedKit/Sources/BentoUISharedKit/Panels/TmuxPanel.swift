import SwiftUI

/// What the app resolved about tmux, for the panel to state as fact.
///
/// The panel doesn't resolve anything itself: which tmux gets used is decided
/// by the Mac app's `TmuxResolver` (and on iOS by whatever host you connected
/// to), and this is that decision flattened into something displayable.
public struct TmuxFacts: Equatable, Sendable {
    public enum Source: String, Sendable { case system, bundled, override }

    public var source: Source
    public var version: String
    public var path: String
    /// Set when a tmux server is already running from a DIFFERENT tmux than the
    /// one we use — the one case on this page that has to interrupt the user.
    public var conflictingSystemVersion: String?

    public init(source: Source, version: String, path: String,
                conflictingSystemVersion: String? = nil) {
        self.source = source
        self.version = version
        self.path = path
        self.conflictingSystemVersion = conflictingSystemVersion
    }
}

/// tmux's own documentation, for the reader who wants the model — sessions,
/// windows, panes, attaching, `~/.tmux.conf`. None of that is on the panel.
///
/// It points at the tmux project, not at a page of ours: what is behind this
/// link is tmux itself, and sending someone to our retelling of it when the
/// real thing exists is the wrong kind of ownership.
public enum TmuxLearnMore {
    public static let url = URL(string: "https://github.com/tmux/tmux/wiki")!
}

/// ③ tmux — three sentences, one picture, one link.
///
/// **This page is nearly all explanation and that is the point.** Plenty of
/// professional developers have never used tmux, and everything Bento does
/// sits on it: unless someone says so, "I closed the window and the agent kept
/// running" reads as a bug, and Parallel / Focus read as two view skins you
/// flip between for fun.
///
/// **But one paragraph, not a lecture.** No server / session / window / pane
/// hierarchy, no `break-pane`, no multi-client attach — all of it true, all of
/// it moved behind `Learn more about tmux`. Someone who wants the model will
/// click; someone who doesn't shouldn't be held up by it in their first minute.
///
/// There is deliberately no "which tmux" picker. It would be a knob over a
/// decision with one right answer (`TmuxResolver`: a good enough system tmux
/// wins, otherwise the bundled copy) — anyone who wants a different tmux
/// changes their tmux.
///
/// Nor a default-session-name field. It named the session the Dock icon opens
/// when there is no previous one to restore, which is a thing that happens
/// once and never means anything afterwards; `default_session_name` keeps its
/// "bento" default in code and simply stopped being a question anyone is
/// asked. That leaves this panel with no settings at all outside Advanced,
/// which is correct — the page is here to explain, not to configure.
public struct TmuxPanel<Extra: View>: View {
    private let context: PanelContext
    private let facts: TmuxFacts?
    private let extra: Extra

    public init(context: PanelContext, facts: TmuxFacts? = nil,
                @ViewBuilder extra: () -> Extra = { EmptyView() }) {
        self.context = context
        self.facts = facts
        self.extra = extra()
    }

    public var body: some View {
        PanelBody(context, hasSetupControls: false) {
                PanelLead("Your agents run in tmux, so they keep working when Bento is not running.")
                ParallelFocusFigure()
                PanelProse("Switching between the two moves the panes themselves — nothing restarts.")
                PanelProse("Drag a pane by its title bar to rearrange them.")
                PanelProse("Already use tmux? Bento attaches to the sessions you already have.")
                Link(destination: TmuxLearnMore.url) {
                    HStack(spacing: 3) {
                        Text("Learn more about tmux")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: 13))
                }
                // Without this the link picks up the window's initial focus and
                // wears a focus ring, which reads as a mis-drawn button.
                .focusEffectDisabled()
        } controls: {
            if let facts, let old = facts.conflictingSystemVersion {
                Section {
                    PanelWarning("""
                        Your tmux is \(old) — too old for control mode (3.2+ required), so Bento \
                        uses its own \(facts.version). Different versions are different servers, \
                        so Bento won't see sessions your tmux started.
                        """) {
                        Link("How to upgrade", destination: URL(string: "https://github.com/tmux/tmux/wiki/Installing")!)
                    }
                }
            }

            AdvancedBlock(context) {
                if let facts {
                    LabeledContent("tmux") {
                        Text(factsLine(facts))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
                extraAdvanced
            }

            extra
        }
    }

    /// A fact, not a control. It lives behind Advanced because when everything
    /// is fine nobody needs to read it; when it isn't, the warning above hoists
    /// itself onto the page.
    private func factsLine(_ facts: TmuxFacts) -> String {
        switch facts.source {
        case .system:
            return "\(facts.version) — yours, at \(facts.path)"
        case .bundled:
            return "\(facts.version) — the copy Bento ships"
        case .override:
            return "\(facts.version) — set by BENTO_TMUX"
        }
    }

    @ViewBuilder
    private var extraAdvanced: some View {
        #if os(macOS)
        Picker("New session opens in", selection: newSessionPlacement) {
            Text("Follow system").tag("system")
            Text("Tab").tag("tab")
            Text("Window").tag("window")
        }
        PanelNote("""
            macOS already has a system-wide answer for tabs vs. windows \
            (System Settings → Desktop & Dock → “Prefer tabs when opening documents”), \
            which Bento follows by default.
            """)
        #endif
    }

    #if os(macOS)
    @AppStorage("mac_new_session_placement") private var placement = "system"
    private var newSessionPlacement: Binding<String> { $placement }
    #endif
}
