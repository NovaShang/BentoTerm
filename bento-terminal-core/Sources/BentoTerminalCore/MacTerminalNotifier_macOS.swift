#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import UserNotifications

/// Surfaces "a pane is awaiting input" on macOS while a terminal window is open
/// (reusing the shared `StateDetectionService` via the VM's
/// `TerminalEnvironment` callbacks). Two signals:
///   - a `UNUserNotificationCenter` banner on the rising edge (0 → >0 awaiting)
///     for a session — so you get pinged when you're in another app;
///   - the Dock badge = total awaiting panes across open terminal sessions.
///     This is now a first-class signal: BentoTerm is an ordinary app with a
///     persistent Dock tile, so the count is visible even with every window
///     closed (it used to be best-effort — an LSUIElement app has no tile).
///     `clearBadge()` on activation keeps it from going stale.
///
/// This mirrors the iOS path (which drives a Live Activity off the same
/// callbacks) — same detection, platform-appropriate surfacing.
@MainActor
public final class MacAwaitingNotifier {
    public static let shared = MacAwaitingNotifier()

    private var perSession: [String: Int] = [:]
    private var authorized = false
    private var didRequestAuth = false

    private init() {}

    /// Called from `TerminalEnvironment.onSessionUpdate` each poll.
    public func update(sessionKey: String, awaiting: Int, prompt: String) {
        let previous = perSession[sessionKey] ?? 0
        perSession[sessionKey] = awaiting

        // Rising edge for this session → notify (only when the user isn't
        // already looking at the app).
        if awaiting > previous, !NSApp.isActive {
            notify(prompt: prompt.isEmpty ? "A pane is awaiting input." : prompt)
        }
        refreshBadge()
    }

    /// Drop a session's contribution (e.g. its window closed).
    public func clear(sessionKey: String) {
        perSession[sessionKey] = nil
        refreshBadge()
    }

    private var totalAwaiting: Int { perSession.values.reduce(0, +) }

    private func refreshBadge() {
        let total = totalAwaiting
        NSApp.dockTile.badgeLabel = total > 0 ? String(total) : nil
    }

    private func notify(prompt: String) {
        ensureAuth()
        let content = UNMutableNotificationContent()
        content.title = "Bento — input needed"
        content.body = String(prompt.prefix(120))
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    private func ensureAuth() {
        guard !didRequestAuth else { return }
        didRequestAuth = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] ok, _ in
            Task { @MainActor in self?.authorized = ok }
        }
    }

    /// Clear the Dock badge (e.g. when the user activates the app).
    public func clearBadge() {
        NSApp.dockTile.badgeLabel = nil
    }
}
#endif
