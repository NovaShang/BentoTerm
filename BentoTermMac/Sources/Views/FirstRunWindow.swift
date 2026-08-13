import SwiftUI
import AppKit
import BentoAgentKit
import BentoGhosttyKit
import BentoFoundationKit
import BentoUISharedKit

/// First-run setup: the five shared panels, paged.
///
/// **This is not a tour.** The previous version taught concepts — a phone/Mac
/// architecture diagram from the deleted relay era, an environment checklist,
/// a "start your first project in ~/Bento Projects" step — to an audience that
/// already uses a shell. It also had an "I'm a pro — skip the tour" button,
/// which was the design admitting the shape was wrong.
///
/// What replaced it: the settings a professional sets on any new terminal
/// anyway (colors, font, speech engine, session name), moved to the first
/// minute, with each page carrying the one thing about that area you can't see
/// from the controls. Same panels Settings renders, so nothing here is a
/// parallel implementation and nothing set here is hard to find later.
///
/// Page 0 is the welcome screen — the product's claim, before anything asks
/// the user to choose. The five panels follow.
///
/// Gate: `UserDefaults firstRunCompleted_v1`, forced with BENTO_FORCE_FIRST_RUN=1.
/// `BENTO_FIRST_RUN_STEP=0…5` jumps straight to a page (0 = welcome).
/// Closing the window at any point keeps whatever was changed — every control
/// writes through to the same store Settings uses, immediately.
struct FirstRunWindow: View {
    static let completedKey = "firstRunCompleted_v1"

    @Environment(\.dismiss) private var dismiss

    @State private var pageIndex: Int = ProcessInfo.processInfo
        .environment["BENTO_FIRST_RUN_STEP"].flatMap(Int.init) ?? 0

    /// Page count = welcome + the five panels.
    private static let pageCount = PanelPage.allCases.count + 1

    /// nil on the welcome page, which is not one of the panels.
    private var page: PanelPage? {
        guard pageIndex >= 1 else { return nil }
        return PanelPage.allCases[min(pageIndex - 1, PanelPage.allCases.count - 1)]
    }

    var body: some View {
        VStack(spacing: 0) {
            if let page {
                header(page)
                MacSetupPanel(page: page, context: .onboarding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                WelcomeManifestoView(icon: Image(nsImage: NSApp.applicationIconImage))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 640, height: 720)
        .task { TelemetryService.shared.record(.firstRunStarted) }
    }

    /// Just the title, on the window background. The first version put a small
    /// icon and a 17pt title above a hairline — the anatomy of a Settings tab,
    /// precisely the impression a first run must not give. The version after
    /// that added a subtitle under it, which said nothing the title didn't.
    ///
    /// The inset is the form's, not a rounder number: the title has to start on
    /// the same left edge as the cards under it.
    private func header(_ page: PanelPage) -> some View {
        Text(page.title)
            .font(.system(size: 26, weight: .bold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PanelMetrics.pageInset)
            .padding(.top, 20)
            .padding(.bottom, 16)
    }

    private var footer: some View {
        HStack {
            if pageIndex == 0 {
                // Not "skip the tour" — there is no tour. This is "I'll do the
                // rest later", and the pages are all in Settings either way.
                Button("Later") { finish(completed: false) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            } else {
                Button("Back") { withAnimation { pageIndex -= 1 } }
            }
            Spacer()
            PageDots(count: Self.pageCount, current: pageIndex)
            Spacer()
            if pageIndex == Self.pageCount - 1 {
                Button("Done") { finish(completed: true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                // The welcome page's button says what pressing it starts, not
                // just that there is a page after it.
                Button(pageIndex == 0 ? "Get Started" : "Next") {
                    withAnimation { pageIndex += 1 }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private func finish(completed: Bool) {
        TelemetryService.shared.record(completed ? .firstRunCompleted : .firstRunSkipped)
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        dismiss()
    }
}

/// The one place that maps a `PanelPage` onto its panel plus the Mac-only
/// settings that belong beside it. Both hosts (setup flow, Settings tabs) go
/// through here, so a Mac-only row can't end up in one and not the other.
struct MacSetupPanel: View {
    let page: PanelPage
    let context: PanelContext

    @AppStorage(BentoTerminalWindow.autoHideToolbarFullscreenKey) private var autoHideToolbar = true

    var body: some View {
        switch page {
        case .appearance:
            AppearancePanel(context: context, preview: AnyView(GhosttyThemePreview())) {
                Toggle("Auto-hide toolbar in full screen", isOn: $autoHideToolbar)
                PanelNote("""
                    Hides the toolbar and session tabs in full screen, revealing them when \
                    the pointer reaches the top. Takes effect the next time you enter full \
                    screen.
                    """)
            }
        case .speech:
            SpeechPanel(context: context)
        case .tmux:
            TmuxPanel(context: context, facts: TmuxResolver.facts())
        case .agents:
            AgentsPanel(context: context)
        case .finish:
            FinishPanel(context: context) {
                SettingsAboutSection(
                    icon: Image(nsImage: NSApp.applicationIconImage),
                    tagline: "A tmux-native terminal for the Mac.")
            }
        }
    }
}
