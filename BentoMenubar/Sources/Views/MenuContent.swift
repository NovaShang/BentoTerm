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

        // The one thing only this menu can do: with no window open the app has
        // no Dock icon, so this is the way back in. It restores the sessions
        // that were open, and the window's own chrome takes over from there.
        Button(action: { BentoTerminalWindow.openMainWindow() }) {
            Label("Open Bento", systemImage: "macwindow")
        }
        .keyboardShortcut("o")

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
