import BentoTerminalCore
import SwiftUI

@main
struct BentoTermMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // BentoTerm is an ordinary Mac app: Dock icon, main menu, windows owned
        // by AppKit (BentoTerminalWindow). There is no SwiftUI scene for the
        // terminal itself, so `Settings` is the only declared scene — and it is
        // what carries the main menu. `.commands` contributes to NSApp.mainMenu
        // app-wide regardless of which scene declares it; attaching it here is
        // what keeps the Shell menu (and ⌘N) alive now that the MenuBarExtra
        // scene it used to hang off is gone.
        Settings {
            SettingsView()
        }
        // The "Shell" menu drives the libghostty tiled terminal. Items dispatch
        // through the responder chain (BentoPaneAction) to the focused
        // GhosttyTiledPaneHost, because our terminal windows are plain AppKit
        // windows with no NSWindowController of their own.
        .commands { TerminalCommands() }
    }
}

/// The Shell menu for Bento terminal windows (split / zoom / navigate / close),
/// plus File → New Window.
struct TerminalCommands: Commands {
    var body: some Commands {
        // ⌘N is the reflex key for "give me one more of these" in every Mac
        // app, so it always makes a new standalone window — never a no-op when
        // a window is already up, and never a tab. What lands in that window is
        // the launcher: ⌘N asks, ⌘⇧T (New Session, below) doesn't.
        // Reopen-the-last-session is a RESTORE gesture and lives where restore
        // gestures belong: the Dock icon and launch (`openMainWindow`).
        CommandGroup(replacing: .newItem) {
            Button("New Window") { BentoTerminalWindow.newSessionWindow() }
                .keyboardShortcut("n", modifiers: .command)
        }

        CommandMenu("Shell") {
            Button("Command Palette…") { BentoTerminalWindow.presentCommandPalette() }
                .keyboardShortcut("p", modifiers: .command)
            Button("Toggle Preview Panel") { BentoTerminalWindow.togglePreviewDock() }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Divider()
            // Scoped to the ACTIVE PANE's scrollback — the omnibox above is the
            // app-wide one. Standard macOS find keys so nobody has to learn them.
            Button("Find…") { BentoPaneAction.dispatch(BentoPaneAction.findInPane) }
                .keyboardShortcut("f", modifiers: .command)
            Button("Find Next") { BentoPaneAction.dispatch(BentoPaneAction.findNext) }
                .keyboardShortcut("g", modifiers: .command)
            Button("Find Previous") { BentoPaneAction.dispatch(BentoPaneAction.findPrevious) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button("Use Selection for Find") {
                BentoPaneAction.dispatch(BentoPaneAction.useSelectionForFind)
            }
            .keyboardShortcut("e", modifiers: .command)
            Divider()
            // ⌘T is the reflex key in every terminal, and in tmux the reflex
            // action is `prefix-c` — a new WINDOW in the session you're in. It
            // used to create a whole new session here (a heavier, rarer thing
            // that needs a name and shows up in `tmux ls`) while the everyday
            // new-window sat on ⌃⌘T. Frequency and resistance were inverted.
            Button("New tmux Window") { BentoPaneAction.dispatch(BentoPaneAction.newTmuxWindow) }
                .keyboardShortcut("t", modifiers: .command)
            Button("New Session") { BentoTerminalWindow.newWindow() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("New Window (no tmux)") { BentoTerminalWindow.newWindowNoTmux() }
                .keyboardShortcut("t", modifiers: [.command, .option, .shift])
            Divider()
            Button("Split Right (-h)") { BentoPaneAction.dispatch(BentoPaneAction.splitVertically) }
                .keyboardShortcut("d", modifiers: .command)
            Button("Split Down (-v)") { BentoPaneAction.dispatch(BentoPaneAction.splitHorizontally) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
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
            // ⌘0..⌘9 → the window whose tmux INDEX is that digit, matching the
            // `index:name` the toolbar shows and tmux's own `prefix <n>`.
            // Tucked in a submenu; the shortcuts fire whether it's open or not.
            Menu("Select Window") {
                ForEach(0...9, id: \.self) { n in
                    Button("Window \(n)") {
                        BentoPaneAction.dispatch(BentoPaneAction.selectWindow[n])
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                }
            }
            Divider()
            // Re-assert this window's grid on the shared tmux session (another
            // client, e.g. an iPad, may have shrunk the canvas).
            Button("Track Session Size to This Window") { BentoTerminalWindow.trackActiveSessionSize() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("Close Pane") { BentoPaneAction.dispatch(BentoPaneAction.closePane) }
                .keyboardShortcut("w", modifiers: .command)
            Button("Close Window") { BentoTerminalWindow.closeMainWindow() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }
    }
}

/// Windows manages the small set of secondary, single-purpose windows (Wizard /
/// First run). They are opened via AppKit rather than as
/// SwiftUI `Window` scenes because they are transient and app-triggered, not
/// restorable places the user navigates to — and because the terminal windows
/// they sit alongside are AppKit-owned too, so one window story is simpler than
/// two. They deliberately carry no NSWindowController: closing one must not
/// count as "the app's last window" in a way that changes lifecycle, and
/// `applicationShouldTerminateAfterLastWindowClosed` is false anyway.
enum Windows {
    enum Kind { case wizard, firstRun }

    @MainActor
    static func show(_ kind: Kind) {
        let title: String
        let content: AnyView
        switch kind {
        case .wizard:
            title = "New agent session"
            content = AnyView(AgentWizardWindow())
        case .firstRun:
            title = "Welcome to BentoTerm"
            content = AnyView(FirstRunWindow())
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
