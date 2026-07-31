import AppKit
import BentoTerminalCore
import Foundation
import SwiftUI

/// AppDelegate owns the background polling timer that refreshes the tmux
/// session list.
///
/// The poll is not cosmetic and must not be mistaken for leftover menu-bar
/// machinery: `refresh()` feeds `BentoTerminalWindow.setServerSessions(...)`,
/// which backs the window's tab strip AND the filter `openMainWindow()` uses to
/// decide which remembered sessions still exist. Without it, sessions that died
/// on the server get "reopened" as fresh empty ones.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published var tmuxSessions: [TmuxSession] = []
    /// Windows per session, fetched alongside the session list so the
    /// menu's submenu can render without a per-open async fetch (NSMenu
    /// would already be on screen by the time tmux replied).
    @Published var tmuxWindows: [String: [TmuxWindow]] = [:]

    private var pollTimer: Timer?
    /// KVO token for `NSApp.effectiveAppearance` — drives follow-system light/dark.
    private var appearanceObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftUI has built NSApp.mainMenu by now; take ⌘W back (see below).
        reclaimClosePaneShortcut()

        // Apply the saved light/dark preference before any window appears, and
        // keep it in sync when the user changes it or (in follow-system mode) the
        // OS appearance flips.
        applyAppearanceMode()
        NotificationCenter.default.addObserver(
            self, selector: #selector(appearanceModeChanged),
            name: .appearanceModeChanged, object: nil)
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.syncSystemAppearance() }
        }

        // Wire the terminal toolbar's app-target actions (the New Agent wizard
        // and the Settings scene) into the core window code via its hooks.
        BentoTerminalWindow.onNewAgentSession = {
            Windows.show(.wizard)
        }
        BentoTerminalWindow.onOpenSettings = { [weak self] in
            self?.openSettings()
        }
        // Kill a session reliably via a one-shot `tmux kill-session`, then refresh
        // so the strip reflects it immediately (don't wait for the 5s poll).
        BentoTerminalWindow.killSessionCLI = { [weak self] name in
            Task { @MainActor in
                try? await TmuxCLI.kill(session: name)
                await self?.refresh()
            }
        }
        RemovedFeatureCleanup.purgeTelemetryDefaults()

        Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            self.startPolling()
            // Test hook: open a specific secondary window directly
            // (BENTO_OPEN_WINDOW=wizard|plain|settings|firstRun), for
            // screenshot-driven verification without UI scripting. This one
            // DOES suppress the terminal window — the point of the hook is to
            // get a clean screenshot of exactly one window.
            if let name = ProcessInfo.processInfo.environment["BENTO_OPEN_WINDOW"] {
                switch name {
                case "wizard": Windows.show(.wizard)
                case "plain": BentoTerminalWindow.newWindowNoTmux()
                case "settings": self.openSettings()
                default: Windows.show(.firstRun)
                }
                return
            }
            // Always open the terminal window on launch — including a launch at
            // login. An app with a Dock icon that starts with zero windows just
            // looks broken; there is no menu-bar item to explain where it went.
            BentoTerminalWindow.openMainWindow()
            // First launch → the onboarding wizard owns the stage: environment
            // checklist, first workspace, first voice command. It comes up IN
            // FRONT OF the terminal window rather than instead of it, so
            // dismissing it leaves the user somewhere. BENTO_FORCE_FIRST_RUN=1
            // re-triggers it for testing without clearing defaults.
            let firstRunPending = !UserDefaults.standard.bool(forKey: FirstRunWindow.completedKey)
                || ProcessInfo.processInfo.environment["BENTO_FORCE_FIRST_RUN"] == "1"
            if firstRunPending {
                Windows.show(.firstRun)
            }
        }
    }

    /// No confirmation here (see the note further down) — this exists only to
    /// mark the quit BEFORE any window closes, so the reopen list records the
    /// set that was open instead of watching it drain one tab at a time.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        BentoTerminalWindow.isTerminating = true
        return .terminateNow
    }

    /// Clicking the Dock icon (or re-launching the .app) with no windows → open
    /// the terminal window with the last session, creating the default session if
    /// there was none. With windows already up, do nothing beyond the default
    /// unhide/activate: a Dock click is "show me the app", not "give me another
    /// window", and the app now gets one of these on every Dock click.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return true }
        BentoTerminalWindow.openMainWindow()
        return true
    }

    // MARK: - Appearance (light / dark / follow-system)

    /// Pin (or release, for follow-system) the app's appearance from the user's
    /// preference. Setting `NSApp.appearance` flips every AppKit/SwiftUI semantic
    /// color for free; the ghostty pane chrome recolors via `.terminalThemeChanged`.
    private func applyAppearanceMode() {
        switch ThemeStore.shared.appearanceMode {
        case .system: NSApp.appearance = nil
        case .light:  NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        syncSystemAppearance()
    }

    @objc private func appearanceModeChanged() { applyAppearanceMode() }

    /// Push the OS's resolved light/dark into the shared store (only changes the
    /// effective theme while in follow-system mode).
    private func syncSystemAppearance() {
        ThemeStore.shared.updateSystemIsDark(ThemeStore.detectSystemIsDark())
    }

    /// Open the Settings scene, for the terminal toolbar's ⚙.
    ///
    /// This fires the App menu's own Settings… item rather than sending
    /// `showSettingsWindow:` down the responder chain. That selector is what the
    /// documentation points you at, and it does nothing here: SwiftUI backs its
    /// Settings item with a private `menuAction:` on a callback object, not with
    /// the AppKit selector, so `NSApp.sendAction` finds no responder and fails
    /// silently. The item is found by its ⌘, key equivalent so a localized title
    /// can't break it.
    ///
    /// (Under the old MenuBarExtra build this bridge was even more indirect —
    /// the only handler was an `onReceive` on the menu-bar label view, which is
    /// why deleting that label would have made the ⚙ a silent no-op.)
    func openSettings() {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
              let idx = appMenu.items.firstIndex(where: {
                  $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command
              })
        else { return }
        NSApp.activate(ignoringOtherApps: true)
        appMenu.performActionForItem(at: idx)
    }

    /// Give ⌘W back to Shell → Close Pane.
    ///
    /// SwiftUI synthesises a File → Close (`performClose:`, ⌘W) for us, and when
    /// two menu items want the same key equivalent it silently strips the one
    /// declared in `.commands` — so "Close Pane" came up with no shortcut at all
    /// and ⌘W closed the whole window instead of the focused pane. Panes are the
    /// thing you close constantly here; the window is ⌘⇧W, exactly as Terminal
    /// splits ⌘W / ⌘⇧W between tab and window.
    ///
    /// This has to be AppKit surgery: the group that generates Close isn't one
    /// of the `CommandGroupPlacement`s you can replace.
    private func reclaimClosePaneShortcut() {
        guard let mainMenu = NSApp.mainMenu else { return }
        for top in mainMenu.items {
            guard let sub = top.submenu else { continue }
            for item in sub.items where item.action == #selector(NSWindow.performClose(_:)) {
                item.keyEquivalent = ""
                item.keyEquivalentModifierMask = []
            }
            for item in sub.items where item.title == "Close Pane" {
                item.keyEquivalent = "w"
                item.keyEquivalentModifierMask = .command
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // User is looking at the app now — clear the awaiting Dock badge.
        MacAwaitingNotifier.shared.clearBadge()
    }

    /// Closing the last window does NOT quit — Terminal.app behavior, chosen
    /// deliberately. The app stays in the Dock; clicking its icon or ⌘N brings a
    /// window back with the last session. Quitting is an explicit ⌘Q, and it is
    /// only ever a detach: the tmux sessions outlive it either way.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // There is deliberately NO `applicationShouldTerminate` confirmation, and we
    // deliberately do not call libghostty's `ghostty_surface_needs_confirm_quit`
    // / `ghostty_app_needs_confirm_quit`.
    //
    // Those exist for a terminal that OWNS its processes: quitting kills them, so
    // it has to ask. Bento is a tmux client. Quitting is a detach — the session,
    // its windows, its panes and everything running in them survive on the
    // server, and `tmux attach` (or reopening Bento) brings them right back.
    // Prompting "there are processes still running" would teach the user to fear
    // an action that is lossless, which is worse than not prompting at all.
    //
    // The only surfaces this would be honest for are the non-tmux ones (New →
    // Other), and they are not worth a modal on the way out. Revisit only if
    // non-tmux panes become a real part of the product.

    /// Backs the native tab bar's `+` button: open a brand-new tmux session as a
    /// tab. The responder chain reaches the app delegate for our session windows
    /// (which have no NSWindowController), and implementing this is also what
    /// makes the `+` button appear on the tab bar in the first place.
    @objc func newWindowForTab(_ sender: Any?) {
        BentoTerminalWindow.newSessionTab()
    }


    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
    }

    func refresh() async {
        let sessions = await TmuxCLI.listSessions()
        tmuxSessions = sessions
        // Drive the terminal window's tab strip with the full session list.
        BentoTerminalWindow.setServerSessions(sessions.map(\.name))
        // Fan-out the per-session window queries concurrently. Each call
        // is a single `tmux list-windows` shell-out (a few ms), so even
        // with many sessions this finishes well under the 5s poll period.
        var fresh: [String: [TmuxWindow]] = [:]
        await withTaskGroup(of: (String, [TmuxWindow]).self) { group in
            for s in sessions {
                group.addTask { (s.name, await TmuxCLI.listWindows(session: s.name)) }
            }
            for await (name, wins) in group {
                fresh[name] = wins
            }
        }
        tmuxWindows = fresh
    }

}
