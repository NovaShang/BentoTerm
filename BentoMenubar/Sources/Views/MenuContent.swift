import SwiftUI
import AppKit
import BentoTerminalCore

/// MenuContent is the children of a MenuBarExtra with `.menuBarExtraStyle(.menu)`.
/// In that mode SwiftUI bridges children to a real NSMenu, so we can only use
/// Button / Text / Toggle / Menu / Divider / Section — NO custom HStack or
/// VStack at the top level. Icons come from SF Symbols via `Label`.
struct MenuContent: View {
    @EnvironmentObject var bento: BentoCLI
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var app: AppDelegate

    var body: some View {
        // This menu is the face of the RESIDENT half — it exists because the
        // background service does, and it covers what that service owns:
        // whether it's running, who is paired with it, and how to shut it all
        // down. Anything about a session belongs to the window that has it;
        // windows are an ordinary Mac app (⌘N / ⌘W / ⌘Q, native tabs, a Window
        // menu), and Bento recedes to this icon when the last one closes.
        //
        // It used to also list every session with Rename and Kill, plus three
        // ways to create things. All of that now lives in the window, where
        // there is a session in front of you to act on — a global menu offering
        // "Kill session" is a destructive action with no context, which is
        // exactly how a session got killed by the titlebar menu this replaced.
        // First item: the one thing nothing else can do. An accessory app has
        // no Dock icon, so with every window closed this is the way back in.
        Button(action: { BentoTerminalWindow.openMainWindow() }) {
            Label("Open BentoTerm", systemImage: "macwindow")
        }
        .keyboardShortcut("o")

        Divider()

        Button(action: {}) {
            Label(statusLine, systemImage: statusSymbol)
        }
        .disabled(true)

        if let id = app.status?.daemonID {
            Button(action: {}) {
                Label("daemon \(id.prefix(8))…", systemImage: "terminal")
            }
            .disabled(true)
        }

        // Daemon down → a one-click fix, not a wall of disabled items (design
        // doc §4.2). Pairing and device management need it; local terminals don't.
        if app.status == nil {
            Button(action: {
                Task {
                    try? await bento.startDaemon(relay: nil)
                    await app.refresh()
                }
            }) {
                Label("Start background service", systemImage: "play.circle")
            }
            Button(action: {}) {
                Label("Needed to pair and reach your phone", systemImage: "info.circle")
            }
            .disabled(true)
        }

        // The counterpart to Start: the service outlives the GUI on purpose,
        // so there has to be a deliberate way to stop it. Quitting no longer
        // does it by accident.
        if app.status != nil {
            Button(action: {
                Task {
                    try? await bento.stopDaemon()
                    await app.refresh()
                }
            }) {
                Label("Stop background service", systemImage: "stop.circle")
            }
        }


        Divider()

        Button(action: { Windows.show(.pair, env: bento) }) {
            Label("Pair new iPhone…", systemImage: "iphone.and.arrow.right.outward")
        }
        .keyboardShortcut("p")
        .disabled(app.status == nil)

        Button(action: { Windows.show(.devices, env: bento) }) {
            Label("Paired devices…", systemImage: "lock.iphone")
        }
        .disabled(app.status == nil)

        if !app.tmuxSessions.isEmpty {
            Divider()
            Section("Sessions · click to open") {
                SessionsMenuView(app: app)
            }
        }

        Divider()

        Button(action: {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }) {
            Label("Settings…", systemImage: "gearshape")
        }
        .keyboardShortcut(",")

        Divider()

        Button(action: { NSApp.terminate(nil) }) {
            Label("Quit Bento", systemImage: "power")
        }
        .keyboardShortcut("q")
    }

    private var statusLine: String {
        guard let s = app.status else { return "Daemon not running" }
        if s.relayConnected {
            return "Connected · \(s.pairedDevices) device\(s.pairedDevices == 1 ? "" : "s")"
        }
        return "Daemon up · relay offline"
    }

    private var statusSymbol: String {
        guard let s = app.status else { return "xmark.circle" }
        return s.relayConnected ? "wifi" : "wifi.exclamationmark"
    }
}

/// The session list, shared by the menubar dropdown AND the terminal toolbar's
/// Sessions button (hosted there via `NSHostingMenu`) so both behave identically:
/// clicking a session's first level (its `primaryAction`) attaches/opens it,
/// while the disclosure arrow reveals its windows + Rename + Kill.
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
/// Internal so the terminal toolbar's Sessions menu can format identically.
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
/// Internal so the terminal toolbar's Sessions menu can reuse the same prompt.
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

/// A blocking confirm for the only irreversible action the menubar offers.
@MainActor
func confirmKill(session: String) -> Bool {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "Kill “\(session)”?"
    alert.informativeText = "Everything running in it stops. Closing a window or quitting Bento only detaches — this does not."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Kill Session")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
}
