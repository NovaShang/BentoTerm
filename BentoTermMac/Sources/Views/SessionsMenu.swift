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

    var body: some View {
        if app.tmuxSessions.isEmpty {
            Button("No sessions") {}.disabled(true)
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
                    if let newName = promptRename(current: s.name) {
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
                    guard confirmKill(session: s.name) else { return }
                    Task {
                        try? await TmuxCLI.kill(session: s.name)
                        await app.refresh()
                    }
                }
            } label: {
                let isOpen = BentoTerminalWindow.openSessionKeys.contains(s.name)
                Label(
                    "\(s.name)  ·  \(relativeActivity(s.lastActivity))",
                    // ✓ = already open as a Bento tab (clicking focuses it, not a
                    // duplicate); otherwise the tmux attached/detached eye.
                    systemImage: isOpen ? "checkmark.circle.fill"
                        : (s.attached ? "eye.fill" : "eye.slash")
                )
            } primaryAction: {
                // Already open → just bring its tab forward; don't open a second.
                if BentoTerminalWindow.openSessionKeys.contains(s.name) {
                    BentoTerminalWindow.focusOrOpen(session: s.name)
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
