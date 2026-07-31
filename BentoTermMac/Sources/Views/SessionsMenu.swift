import SwiftUI
import AppKit
import BentoTerminalCore

/// The session list behind the terminal toolbar's Sessions button, hosted there
/// as a real NSMenu via `NSHostingMenu`: clicking a session's first level (its
/// `primaryAction`) attaches/opens it, while the disclosure arrow reveals its
/// windows + Rename + Kill.
///
/// This used to be shared with a menu-bar dropdown; the toolbar is now its only
/// home, which is the right one — the sessions you can act on belong next to the
/// window showing one of them, not in a global menu with no context.
struct SessionsMenuView: View {
    @ObservedObject var app: AppDelegate

    /// Sessions open on an ssh host. They are listed SEPARATELY and carry no
    /// actions beyond "focus", because every action in this menu is a
    /// `TmuxCLI` call against the local server — the whole reason
    /// `LocalTmuxSessionName` exists is that those must never be pointed at a
    /// session on another machine. A remote session's Rename and Kill live in
    /// its own window's toolbar, where they go over its own control channel.
    private var remoteOpen: [TmuxSessionID] {
        BentoTerminalWindow.openSessionIDs.filter { !$0.isLocal }
    }

    var body: some View {
        if app.tmuxSessions.isEmpty && remoteOpen.isEmpty {
            Button("No sessions") {}.disabled(true)
        }
        if !remoteOpen.isEmpty {
            Section("Remote") {
                ForEach(remoteOpen, id: \.key) { id in
                    Button {
                        BentoTerminalWindow.focusOrOpen(id)
                    } label: {
                        Label(id.displayName, systemImage: "network")
                    }
                }
            }
            Divider()
        }
        ForEach(app.tmuxSessions) { s in
            Menu {
                let windows = app.tmuxWindows[s.name] ?? []
                if !windows.isEmpty {
                    Section("Windows") {
                        ForEach(windows) { w in
                            Button {
                                Task { try? await TmuxCLI.attach(session: s.name, window: w.index) }
                            } label: {
                                Label(
                                    "\(w.index): \(w.name)\(w.paneCount > 1 ? "  ·  \(w.paneCount) panes" : "")",
                                    systemImage: w.active ? "circle.fill" : "circle"
                                )
                            }
                        }
                    }
                    Divider()
                }
                Button("Rename session…") {
                    if let newName = promptRename(current: s.name.rawValue) {
                        Task {
                            try? await TmuxCLI.rename(session: s.name, to: newName)
                            await app.refresh()
                        }
                    }
                }
                Divider()
                Button("Kill session", role: .destructive) {
                    // Confirm here specifically. Everywhere else in Bento
                    // quitting or closing is a DETACH — the session survives —
                    // so this is the one action in the whole app that actually
                    // destroys running processes, and it sits in a global menu
                    // with no session in front of you to make that concrete.
                    guard confirmKill(session: s.name.rawValue) else { return }
                    Task {
                        try? await TmuxCLI.kill(session: s.name)
                        await app.refresh()
                    }
                }
            } label: {
                // Keyed by IDENTITY, not name: an open session on an ssh host
                // that happens to share a name with a local one must not tick
                // this row's box — the two are different sessions and this menu
                // only ever acts on the local server's.
                let isOpen = BentoTerminalWindow.openSessionKeys.contains(s.name.id.key)
                Label(
                    "\(s.name.rawValue)  ·  \(relativeActivity(s.lastActivity))",
                    // ✓ = already open as a Bento tab (clicking focuses it, not a
                    // duplicate); otherwise the tmux attached/detached eye.
                    systemImage: isOpen ? "checkmark.circle.fill"
                        : (s.attached ? "eye.fill" : "eye.slash")
                )
            } primaryAction: {
                // Already open → just bring its tab forward; don't open a second.
                if BentoTerminalWindow.openSessionKeys.contains(s.name.id.key) {
                    BentoTerminalWindow.focusOrOpen(s.name.id)
                } else {
                    Task { try? await TmuxCLI.attach(session: s.name) }
                }
            }
        }
    }
}

/// relativeActivity returns a macOS-conventional "5m ago" / "just now"
/// string. RelativeDateTimeFormatter isn't `Sendable` in Swift 6, so we
/// allocate one per call (cheap — under 0.1ms per call in practice).
/// Used by the toolbar's Sessions menu.
func relativeActivity(_ date: Date) -> String {
    if date == .distantPast { return "—" }
    let now = Date()
    if now.timeIntervalSince(date) < 60 { return "just now" }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f.localizedString(for: date, relativeTo: now)
}

/// promptRename pops a small modal NSAlert with just a text field. We
/// suppress the default app-icon badge so the dialog stays compact.
/// Used by the toolbar's Sessions menu.
@MainActor
func promptRename(current: String) -> String? {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "Rename “\(current)”"
    alert.informativeText = ""
    // Suppress the default Bento icon on the left — a rename prompt doesn't
    // need a branded badge.
    alert.icon = NSImage(size: NSSize(width: 1, height: 1))
    alert.addButton(withTitle: "Rename")
    alert.addButton(withTitle: "Cancel")

    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    field.stringValue = current
    field.selectText(nil)
    alert.accessoryView = field
    alert.window.initialFirstResponder = field

    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != current else { return nil }
    return trimmed
}

/// A blocking confirm for the only irreversible action the Sessions menu offers.
@MainActor
func confirmKill(session: String) -> Bool {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "Kill “\(session)”?"
    alert.informativeText = "Everything running in it stops. Closing a window or quitting BentoTerm only detaches — this does not."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Kill Session")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
}
