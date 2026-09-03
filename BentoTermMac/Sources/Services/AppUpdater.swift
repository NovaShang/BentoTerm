import Combine
import Sparkle
import SwiftUI

/// Auto-update, sourced from this repo's own GitHub releases.
///
/// **Why Sparkle and not fifty lines of URLSession.** Downloading a zip is the
/// easy half. The half that bites is everything after: replacing a bundle the
/// user is currently running, keeping Gatekeeper satisfied when the replacement
/// lands, coping with an app the user can't write to, and relaunching without
/// leaving two copies or none. Sparkle has been getting that wrong and then
/// right since 2006.
///
/// **What makes the channel safe** is not HTTPS — it's the EdDSA signature on
/// every archive, checked against `SUPublicEDKey` in Info.plist. A hijacked
/// release page serves an update Sparkle refuses to install.
///
/// It checks on a schedule and it never installs on its own: this app is
/// holding live panes. tmux sessions survive a relaunch (their server's parent
/// is launchd, not us) but anything running in a plain local pane does not, so
/// WHEN to restart is the user's call, always.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    /// False in a debug build, where there is no updater at all — see `init`.
    @Published private(set) var canCheck = false

    private let controller: SPUStandardUpdaterController?

    private init() {
        #if DEBUG
        // A build running out of DerivedData has nothing to update TO, and an
        // updater here would offer to replace your own working copy with the
        // last release. Deliberately not "start it and turn the schedule off":
        // that switch is a UserDefault in the same domain the release app
        // reads, so a debug run would quietly disable checking for the real
        // install too. Testing the update flow means a Release build.
        controller = nil
        #else
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        controller?.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheck)
        #endif
    }

    func checkForUpdates() { controller?.updater.checkForUpdates() }

    /// The scheduled check. Seeded from `SUEnableAutomaticChecks` and stored by
    /// Sparkle from then on, so this is the live value, not the default.
    var checksAutomatically: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Nil until the first check completes — including forever, in a debug
    /// build. The UI says "Never" rather than hiding the row: "when did it last
    /// look?" is the question this section exists to answer.
    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }
}

/// The App menu's "Check for Updates…", right under About.
///
/// Its own view because the item has to disable itself while a check is already
/// running, and `canCheckForUpdates` is a property that changes underneath the
/// menu rather than a value the menu can be built from once.
struct CheckForUpdatesMenuItem: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheck)
    }
}
