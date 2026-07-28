import BentoTerminalCore
import SwiftUI

@main
struct BentoMenubarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(app: appDelegate)
                .environmentObject(appDelegate.bento)
        } label: {
            // A small wrapper so the always-present menu-bar label can bridge an
            // AppKit request (the terminal toolbar's ⚙) to SwiftUI's reliable
            // `openSettings` action — `showSettingsWindow:` doesn't fire in a
            // MenuBarExtra app.
            MenubarLabel()
        }
        .menuBarExtraStyle(.menu)
        // The "Shell" menu drives the libghostty tiled terminal. Items dispatch
        // through the responder chain (BentoPaneAction) to the focused
        // GhosttyTiledPaneHost. SwiftUI owns the main menu in a MenuBarExtra
        // app, so the menu must be declared here rather than via NSApp.mainMenu.
        .commands { TerminalCommands() }

        Settings {
            SettingsView().environmentObject(appDelegate.bento)
        }
    }
}

extension Notification.Name {
    /// Posted by the terminal toolbar's ⚙ to open the SwiftUI Settings scene.
    static let bentoOpenSettings = Notification.Name("bentoOpenSettings")
}

/// The always-present menu-bar label. It holds SwiftUI's `openSettings` action
/// and triggers it when the AppKit toolbar posts `.bentoOpenSettings`.
struct MenubarLabel: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // Template image — macOS tints to match the dark/light menu bar.
        Image("MenubarIcon")
            .onReceive(NotificationCenter.default.publisher(for: .bentoOpenSettings)) { _ in
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}

/// The Shell menu for Bento terminal windows (split / zoom / navigate / close).
struct TerminalCommands: Commands {
    var body: some Commands {
        CommandMenu("Shell") {
            Button("Command Palette…") { BentoTerminalWindow.presentCommandPalette() }
                .keyboardShortcut("p", modifiers: .command)
            Button("Toggle Preview Panel") { BentoTerminalWindow.togglePreviewDock() }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Divider()
            Button("New Terminal Window") { BentoTerminalWindow.newWindow() }
                .keyboardShortcut("t", modifiers: .command)
            Button("New Window (no tmux)") { BentoTerminalWindow.newWindowNoTmux() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Divider()
            Button("Split Right (-h)") { BentoPaneAction.dispatch(BentoPaneAction.splitVertically) }
                .keyboardShortcut("d", modifiers: .command)
            Button("Split Down (-v)") { BentoPaneAction.dispatch(BentoPaneAction.splitHorizontally) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
            Button("New tmux Window") { BentoPaneAction.dispatch(BentoPaneAction.newTmuxWindow) }
                .keyboardShortcut("t", modifiers: [.command, .control])
            Button("Select Next Pane") { BentoPaneAction.dispatch(BentoPaneAction.nextPane) }
                .keyboardShortcut("]", modifiers: .command)
            Button("Select Previous Pane") { BentoPaneAction.dispatch(BentoPaneAction.previousPane) }
                .keyboardShortcut("[", modifiers: .command)
            Button("Swap Pane Up") { BentoPaneAction.dispatch(BentoPaneAction.swapPaneUp) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Swap Pane Down") { BentoPaneAction.dispatch(BentoPaneAction.swapPaneDown) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Toggle Zoom") { BentoPaneAction.dispatch(BentoPaneAction.toggleZoom) }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            Divider()
            // ⌘1..⌘9 → switch tmux window. Tucked in a submenu to keep the top
            // level tidy; the shortcuts fire whether or not the submenu is open.
            Menu("Select Window") {
                ForEach(1...9, id: \.self) { n in
                    Button("Window \(n)") {
                        BentoPaneAction.dispatch(BentoPaneAction.selectWindow[n - 1])
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                }
            }
            Divider()
            // Re-assert this window's grid on the shared tmux session (another
            // client, e.g. an iPad, may have shrunk the canvas).
            Button("Fit Session to Window") { BentoTerminalWindow.fitActiveSession() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("Close Pane") { BentoPaneAction.dispatch(BentoPaneAction.closePane) }
                .keyboardShortcut("w", modifiers: .command)
            Button("Close Window") { BentoTerminalWindow.closeMainWindow() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }
    }
}

/// Windows manages the small set of secondary windows the menubar can spawn
/// for Pair / Wizard / Devices. We open them via AppKit so we don't fight
/// SwiftUI Scene plumbing for menubar apps (regular Window scenes need a
/// Dock icon, which we don't have).
enum Windows {
    enum Kind { case pair, wizard, devices, firstRun }

    @MainActor
    static func show(_ kind: Kind, env: BentoCLI) {
        let title: String
        let content: AnyView
        switch kind {
        case .pair:
            title = "Pair iPhone"
            content = AnyView(PairingWindow().environmentObject(env))
        case .wizard:
            title = "New agent session"
            content = AnyView(AgentWizardWindow().environmentObject(env))
        case .devices:
            title = "Paired devices"
            content = AnyView(DevicesWindow().environmentObject(env))
        case .firstRun:
            title = "Welcome to Bento"
            content = AnyView(FirstRunWindow().environmentObject(env))
        }
        let host = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: host)
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
