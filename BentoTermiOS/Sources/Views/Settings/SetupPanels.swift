import SwiftUI
import BentoFoundationKit
import BentoGhosttyKit
import BentoUISharedKit

/// The iOS side of the five shared setup panels.
///
/// Same panels as the Mac, same order, same explanation — only the platform
/// extras differ, and this is the one place that decides where each of them
/// hangs, so the setup flow and Settings can't put the same row in two
/// different boxes.
///
/// The tmux panel is here in full. Its explanation is not Mac-specific in the
/// slightest: a phone user has *more* reason to know that sessions live on the
/// host and keep running, since that is the entire reason a phone client is
/// worth having. What iOS omits is only the fact line (which tmux is in use —
/// that belongs to whatever host you connect to) and the Mac's tab/window
/// preference.
struct IOSSetupPanel: View {
    let page: PanelPage
    let context: PanelContext

    @AppStorage("haptics_enabled") private var hapticsEnabled = true
    @AppStorage("path_preview_enabled") private var pathPreviewEnabled = true
    @State private var showTipsResetConfirm = false

    var body: some View {
        switch page {
        case .appearance:
            AppearancePanel(context: context,
                            defaultFontSize: 10,
                            preview: AnyView(GhosttyThemePreview())) {
                Toggle("Haptic Feedback", isOn: $hapticsEnabled)
                Toggle("Tap to Preview Files", isOn: $pathPreviewEnabled)
                PanelNote("Tap a file path in terminal output to peek at the file without leaving the session.")
            }
        case .speech:
            SpeechPanel(context: context)
        case .tmux:
            TmuxPanel(context: context)
        case .agents:
            AgentsPanel(context: context) {
                Section {
                    NavigationLink("State Detection Profiles") { ProfileListView() }
                } footer: {
                    PanelNote("Patterns that decide when a pane is waiting for input, and which quick keys to show.")
                }
            }
        case .finish:
            FinishPanel(context: context) {
                Section {
                    Button {
                        TipCenter.shared.resetAll(extraKeys: [GestureOnboardingOverlay.storageKey])
                        showTipsResetConfirm = true
                    } label: {
                        Label("Replay tips & gesture guide", systemImage: "arrow.counterclockwise")
                    }
                } header: {
                    Text("Help")
                } footer: {
                    PanelNote("Brings back every one-time hint — the gesture overlay, the color legend, the coaching toasts — at their natural moments.")
                }

                SettingsAboutSection(
                    icon: BentoAppIcon.image,
                    tagline: "A tmux-native terminal for iPhone & iPad.")

                Section {
                    NavigationLink {
                        AcknowledgementsView()
                    } label: {
                        Label("Acknowledgements", systemImage: "doc.text")
                    }
                } footer: {
                    PanelNote("BentoTerm redistributes MIT, Apache and SIL-licensed components — the terminal engine, the SSH stack, the bundled font — and each of those licenses requires its text to travel with the binary.")
                }
            }
            .alert("Tips reset", isPresented: $showTipsResetConfirm) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Every one-time hint will show again when you next reach it.")
            }
        }
    }

}

/// The app icon, for the welcome screen and the About row.
///
/// `UIImage(named: "AppIcon")` alone does NOT work on iOS: the catalogue holds
/// an *app icon set*, which is not addressable by name at runtime, so it
/// returns nil and the welcome screen renders with a hole where the icon goes.
/// The primary-icon file list in Info.plist is the way in. (The name lookup is
/// kept first so a plain imageset would still win if one is ever added.)
enum BentoAppIcon {
    static var image: Image? {
        if let ui = UIImage(named: "AppIcon") { return Image(uiImage: ui) }
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let name = files.last,
              let ui = UIImage(named: name)
        else { return nil }
        return Image(uiImage: ui)
    }
}

/// First-run setup on iOS: welcome, connect to a machine, then the five pages.
///
/// **The host step is why this runs at first launch.** On the Mac setup is
/// optional polish — the app works the moment it opens. On iOS nothing works
/// at all until there is a machine to ssh into, so the flow that a new user
/// sees has to contain that step, and it comes second: everything after it
/// (sessions surviving, agents on the host) describes something they can now
/// actually see, and someone who taps "Later" on a middle page still has a
/// working app.
struct SetupFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pageIndex = 0

    /// welcome + host + the five shared panels.
    private static let pageCount = PanelPage.allCases.count + 2
    private static let welcomeIndex = 0
    private static let hostIndex = 1

    /// nil on the two iOS-only pages at the front.
    private var page: PanelPage? {
        guard pageIndex >= Self.hostIndex + 1 else { return nil }
        return PanelPage.allCases[min(pageIndex - Self.hostIndex - 1, PanelPage.allCases.count - 1)]
    }

    var body: some View {
        NavigationStack {
            Group {
                if let page {
                    IOSSetupPanel(page: page, context: .onboarding)
                } else if pageIndex == Self.welcomeIndex {
                    WelcomeManifestoView(icon: BentoAppIcon.image)
                } else {
                    HostSetupPage()
                }
            }
            // ONE background for the whole flow, applied here rather than to
            // the panel inside it. With `bentoForm()` on only the panel pages,
            // the welcome and host pages fell back to the system background
            // while their forms kept the grouped one — so those two pages
            // showed a slab of a different colour behind the top half. Every
            // page now sits on the same shell colour the rest of the app uses,
            // with the form's own scroll background hidden.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .bentoForm()
            .navigationTitle(page?.title ?? (pageIndex == Self.hostIndex ? "Connect" : ""))
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { footer }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Back") { withAnimation { pageIndex -= 1 } }
                .disabled(pageIndex == 0)
            Spacer()
            PageDots(count: Self.pageCount, current: pageIndex)
            Spacer()
            Button(nextTitle) {
                if pageIndex == Self.pageCount - 1 {
                    dismiss()
                } else {
                    withAnimation { pageIndex += 1 }
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var nextTitle: String {
        if pageIndex == Self.pageCount - 1 { return "Done" }
        return pageIndex == Self.welcomeIndex ? "Get Started" : "Next"
    }
}

/// The one step on iOS that isn't optional: point Bento at a machine.
///
/// It does not block "Next". Someone may want to look through the rest first,
/// or add the host from the list later — a wizard that traps you on a form
/// with credentials you don't have to hand is worse than one you can walk past.
/// The page simply says so plainly, and shows what has been added.
struct HostSetupPage: View {
    @EnvironmentObject private var hostStore: HostStore
    @State private var showAddHost = false

    var body: some View {
        PanelBody(.onboarding, hasSetupControls: !hostStore.hosts.isEmpty) {
            PanelLead("Your agents need a machine to run on.")
            PanelProse("They run there, not on this phone — anything you can `ssh` into works: your Mac, a Linux box, a VM in a rack.")
            PanelProse("Nothing to install on it. It needs `sshd` and `tmux`, which it almost certainly already has.")
            PanelProse("If reaching it means a VPN, Tailscale or a jump host, set that up first — Bento connects the same way `ssh` does.")
            Button {
                showAddHost = true
            } label: {
                Label(hostStore.hosts.isEmpty ? "Add a Host" : "Add Another", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        } controls: {
            if !hostStore.hosts.isEmpty {
                Section {
                    ForEach(hostStore.hosts) { host in
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(host.name)
                                Text("\(host.username)@\(host.hostname)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: { Text("Hosts") }
            }
        }
        .sheet(isPresented: $showAddHost) {
            NavigationStack {
                HostEditView(mode: .add) { host in
                    hostStore.add(host)
                }
            }
        }
    }
}
