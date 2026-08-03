import SwiftUI
import UIKit
import BentoSessionKit
import BentoFoundationKit

@main
struct BentoApp: App {
    @StateObject private var hostStore = HostStore()
    @StateObject private var sessionManager = SessionManager.shared
    @StateObject private var themeStore = ThemeStore.shared
    @Environment(\.scenePhase) private var scenePhase

    /// SwiftUI scheme to force, from the appearance preference (nil = follow OS).
    private var preferredScheme: ColorScheme? {
        switch themeStore.appearanceMode {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    init() {
        BentoAppearance.install()
        Self.logBundledFonts()
        // Mirror the core package's dlog (reconnect loop, tmux protocol, voice
        // session — os_log only by default) into Documents/debug.log, so a
        // real-device incident is fully diagnosable from one file pull:
        //   xcrun devicectl device copy from --domain-type appDataContainer
        //     --domain-identifier com.bento.term.app --source Documents/debug.log …
        coreDlogFileSink = { DebugLogger.shared.log($0) }
        Self.purgePairingLeftovers()
    }

    /// One-shot cleanup for installs that predate the removal of the paired-host
    /// transport. The saved-host list is untouched — those were always plain SSH
    /// hosts and still decode — but the separate list of paired computers, the
    /// per-device private keys it minted, and its test-only endpoint override are
    /// now unreachable by any code path. Left in place they would be an
    /// invisible pile of credentials, so delete them rather than let them rot.
    private static func purgePairingLeftovers() {
        let defaults = UserDefaults.standard
        let doneKey = "purged_pairing_leftovers_v1"
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: docs.appendingPathComponent("relay-daemons.json"))
        let keys = KeychainService.shared.deletePrivateKeys(labelPrefix: "relay-device-")
        defaults.removeObject(forKey: "relayURL")
        if keys > 0 { dlog("purged \(keys) orphaned device key(s) from the removed pairing flow") }
    }

    private static func logBundledFonts() {
        let expected = ["JetBrainsMono-Regular", "MapleMono-NF-CN-Regular"]
        for name in expected {
            if UIFont(name: name, size: 14) != nil {
                NSLog("[Bento.fonts] OK loaded: %@", name)
            } else {
                NSLog("[Bento.fonts] MISSING: %@", name)
            }
        }
        let monoFamilies = UIFont.familyNames
            .filter { $0.localizedCaseInsensitiveContains("maple") || $0.localizedCaseInsensitiveContains("jetbrains") }
        NSLog("[Bento.fonts] matching families: %@", monoFamilies.joined(separator: ", "))
        for fam in monoFamilies {
            NSLog("[Bento.fonts]   %@ -> %@", fam, UIFont.fontNames(forFamilyName: fam).joined(separator: ", "))
        }
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack(path: $sessionManager.navigationPath) {
                HomeView()
                    // Depth = 1: the terminal is the only pushed destination.
                    // Everything else in the pre-session world is a sheet off
                    // Home (create, host editor, settings).
                    .navigationDestination(for: BentoRoute.self) { route in
                        switch route {
                        case .terminal(let key):
                            if let entry = sessionManager.activeSessions
                                .first(where: { $0.key == key }) {
                                TerminalWrapperView(viewModel: entry.viewModel)
                                    // The terminal supplies its own back item;
                                    // only the default button is hidden.
                                    .navigationBarBackButtonHidden()
                            }
                        }
                    }
            }
            .environmentObject(hostStore)
            .environmentObject(sessionManager)
            .preferredColorScheme(preferredScheme)
            .modifier(SystemAppearanceSync())
            .tint(Color.bentoEmerald)
            .onChange(of: scenePhase) { _, newPhase in
                sessionManager.handleScenePhaseChange(newPhase)
                // Opt-in telemetry lifecycle: count the active day on
                // foreground, flush the buffered batch on background.
                // Both are no-ops unless the user enabled the toggle.
                switch newPhase {
                case .active: TelemetryService.shared.appBecameActive()
                case .background: TelemetryService.shared.flush()
                default: break
                }
            }
            .onOpenURL { url in
                handleDeepLink(url)
            }
        }
    }

    /// Handles `bento://session/<hostID>` and `bento://app`.
    ///
    /// Same routing rule as everything else that enters a session: attached
    /// → push the terminal; known host but not attached → hand the create
    /// sheet a request (it re-enumerates live).
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "bento" else { return }
        let host = url.host ?? ""
        let path = url.pathComponents
        switch host {
        case "session":
            guard let idString = path.dropFirst().first,
                  let uuid = UUID(uuidString: idString) else { return }
            if let entry = sessionManager.activeSessions.first(where: { $0.key.hostID == uuid }) {
                sessionManager.navigationPath = [.terminal(entry.key)]
            } else if hostStore.hosts.contains(where: { $0.id == uuid }) {
                sessionManager.openRequest = OpenRequest(hostID: uuid)
            }
        case "app":
            sessionManager.navigationPath = []
        default:
            break
        }
    }
}

/// Mirrors the effective light/dark into the shared ThemeStore so the terminal
/// surface (not a UIColor-backed view) resolves the right theme slot. `colorScheme`
/// in a modifier is fully reactive, so this fires both on first appearance and on
/// every OS / preference flip.
private struct SystemAppearanceSync: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        content
            .onAppear { ThemeStore.shared.updateSystemIsDark(colorScheme == .dark) }
            .onChange(of: colorScheme) { _, scheme in
                ThemeStore.shared.updateSystemIsDark(scheme == .dark)
            }
    }
}
