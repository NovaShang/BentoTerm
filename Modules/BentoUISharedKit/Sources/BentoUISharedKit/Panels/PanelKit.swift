import SwiftUI

/// The five setup panels and the two places they are rendered.
///
/// **One implementation, two hosts.** Each panel below is a complete `Form`
/// body that both apps render twice: once as a page of the first-run setup
/// flow, once as a section of Settings. That is not a coincidence to be
/// tidied up later — it is the design (`docs/onboarding-design.md` §0/§1):
/// onboarding exists to put the settings a professional would set anyway in
/// front of them in the first minute, so anything that belongs in one belongs
/// in the other. Settings' tabs are therefore the setup pages, same names,
/// same icons, same order — what you changed while being set up is where you
/// go back to change it again.
///
/// `PanelContext` is the ONLY thing that differs between the two hosts, and it
/// changes nothing but disclosure state: explanation is open while being set
/// up and folded away in Settings. No panel may branch on it for content.
public enum PanelContext: Sendable {
    case onboarding
    case settings
}

/// The five pages, in order. Owned here so the setup flow and the Settings
/// tab bar cannot disagree about what exists or what it is called.
public enum PanelPage: String, CaseIterable, Identifiable, Sendable {
    case appearance, speech, tmux, agents, finish

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .speech:     return "Speech"
        case .tmux:       return "tmux"
        case .agents:     return "Agents"
        case .finish:     return "Finish"
        }
    }

    /// Settings' tab for the last page isn't "Finish" — nothing is being
    /// finished there. Same panel, honest label in each host.
    public var settingsTitle: String {
        self == .finish ? "Privacy" : title
    }

    public var symbol: String {
        switch self {
        case .appearance: return "paintpalette"
        case .speech:     return "mic"
        case .tmux:       return "rectangle.split.2x2"
        case .agents:     return "circle.hexagongrid"
        case .finish:     return "hand.raised"
        }
    }
}

// MARK: - The two block kinds

/// A panel: explanation, then controls.
///
/// **The explanation is not a form row.** In the setup flow it sits on the
/// window background above the form — a `Form` wraps every Section in a grey
/// card, and prose in a grey card reads as fine print to skip past. Clearing
/// `listRowBackground` does not help: macOS's grouped form ignores it. So the
/// explanation is simply not in the form.
///
/// In Settings it is, folded behind one "How this works" row, because there the
/// controls are the point and the prose is reference.
///
/// A panel is allowed to have NO explanation — `AppearancePanel` passes the
/// live preview instead. Colors and fonts are pure taste with a terminal next
/// to them; a sentence saying changes apply immediately would be telling the
/// user what they can already see.
public struct PanelBody<Explain: View, Controls: View>: View {
    private let context: PanelContext
    private let hasSetupControls: Bool
    private let explain: Explain
    private let controls: Controls

    /// - Parameter hasSetupControls: false when every control on this panel is
    ///   Advanced, i.e. hidden during setup. Without it the page renders an
    ///   empty form that still claims the rest of the window, and the
    ///   explanation is left stranded against the top edge above a void.
    public init(
        _ context: PanelContext,
        hasSetupControls: Bool = true,
        @ViewBuilder explain: () -> Explain = { EmptyView() },
        @ViewBuilder controls: () -> Controls
    ) {
        self.context = context
        self.hasSetupControls = hasSetupControls
        self.explain = explain()
        self.controls = controls()
    }

    public var body: some View {
        switch context {
        case .onboarding:
            VStack(alignment: .leading, spacing: 0) {
                // Full width here, and the PROSE constrains itself (see
                // `PanelProse`): a preview or a figure wants the same width as
                // the form cards below it, while a paragraph does not.
                // Short lines with air between them, not paragraphs: this is
                // the first minute of an app, and a block of running text is
                // the thing people skip.
                VStack(alignment: .leading, spacing: 10) { explain }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, PanelMetrics.pageInset)
                    .padding(.bottom, hasSetupControls ? 18 : 0)
                if hasSetupControls {
                    Form { controls }
                        .bentoPanelForm()
                } else {
                    Spacer(minLength: 0)
                }
                // Said once, at the foot of the page, instead of an "Advanced"
                // row on every one of them.
                Text("Everything else is in Settings (⌘,).")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, PanelMetrics.pageInset)
                    .padding(.bottom, 10)
            }
        case .settings:
            Form {
                Section {
                    DisclosureGroup("How this works") {
                        VStack(alignment: .leading, spacing: 12) { explain }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    }
                }
                controls
            }
            .bentoPanelForm()
        }
    }
}

/// Settings that work fine left alone — that is the entry criterion, not
/// "rarely used". API keys, custom vocabulary, tab-vs-window.
///
/// **Settings only.** These do not appear in the setup flow at all.
///
/// **One per page.** Platform extras go in through the panel's `advanced`
/// slot, not in a second `AdvancedBlock` next to the panel — two disclosure
/// rows both labelled "Advanced", stacked, was the first thing anyone saw on
/// page one.
public struct AdvancedBlock<Content: View>: View {
    private let context: PanelContext
    private let content: Content
    @State private var expanded = false

    public init(_ context: PanelContext, @ViewBuilder content: () -> Content) {
        self.context = context
        self.content = content()
    }

    public var body: some View {
        switch context {
        case .onboarding:
            // Nothing. A first run should present the decisions worth making
            // now; a row promising more of them is itself one more thing to
            // read. `PanelBody` prints one line at the foot of the page saying
            // where the rest live, once, instead of five disclosure rows.
            EmptyView()
        case .settings:
            Section {
                DisclosureGroup("Advanced", isExpanded: $expanded) {
                    content
                }
            }
        }
    }
}

/// The page dots in the setup flow's footer.
public struct PageDots: View {
    private let count: Int
    private let current: Int

    public init(count: Int, current: Int) {
        self.count = count
        self.current = current
    }

    public var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(i == current ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: 7, height: 7)
                    .overlay(
                        Circle().strokeBorder(.separator.opacity(i == current ? 0 : 1), lineWidth: 0.5)
                    )
            }
        }
        .animation(.easeInOut(duration: 0.15), value: current)
    }
}

/// Shared measurements, so five panels and two hosts can't each pick their own.
public enum PanelMetrics {
    /// Prose stops here regardless of window width. A 640pt-wide window filled
    /// edge to edge with 13pt text is a wall; ~60 characters is a paragraph.
    public static let proseWidth: CGFloat = 520
    /// Left margin for content that sits on the page rather than in the form.
    /// Matches what the grouped form insets its cards by, so the explanation
    /// above and the first card below share one left edge.
    public static let pageInset: CGFloat = 20
}

// MARK: - Prose styling

/// A panel's lead sentence — the one thing the page is about.
public struct PanelLead: View {
    private let text: LocalizedStringKey

    public init(_ text: LocalizedStringKey) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.system(size: 16, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: PanelMetrics.proseWidth, alignment: .leading)
    }
}

/// Supporting prose. Markdown emphasis works (`LocalizedStringKey`).
public struct PanelProse: View {
    private let text: LocalizedStringKey

    public init(_ text: LocalizedStringKey) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: PanelMetrics.proseWidth, alignment: .leading)
    }
}

/// A footnote under a control — the sentence the control itself can't say.
public struct PanelNote: View {
    private let text: LocalizedStringKey

    public init(_ text: LocalizedStringKey) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A warning that earns its place on the page: something is wrong now and the
/// user will otherwise discover it as a mystery.
public struct PanelWarning<Actions: View>: View {
    private let text: LocalizedStringKey
    private let actions: Actions

    public init(_ text: LocalizedStringKey, @ViewBuilder actions: () -> Actions) {
        self.text = text
        self.actions = actions()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(text)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 8) { actions }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Form plumbing

extension View {
    /// The form chrome a panel wants in either host. Kept in one place so the
    /// setup flow and Settings can't drift into looking like different apps.
    public func bentoPanelForm() -> some View {
        #if os(macOS)
        return self.formStyle(.grouped)
        #else
        return self
        #endif
    }
}
