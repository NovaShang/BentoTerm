import BentoSessionKit
import BentoFoundationKit
import SwiftUI
import BentoUISharedKit

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
/// plus File → New Pane / New Window.
struct TerminalCommands: Commands {
    var body: some Commands {
        // The app is a single-window terminal by default, so ⌘N — the reflex
        // key for "one more" — adds to the session you are in instead of
        // opening another window: a pane split along the active pane's longer
        // side in Parallel, a tmux window in Focus. Its title follows the
        // front session's mode ("New Pane" / "New tmux Window"); that is done
        // on the AppKit item (`BentoTerminalWindow.refreshNewItemTitle`), not
        // with observed state here — see there for why. With no session
        // window, ⌘N opens one the way launch does.
        //
        // ⇧⌘N is the explicit second window: a new Mac window holding a new
        // session, `<default>-2`, `-3`…. Every other kind of new thing is in
        // the toolbar's ＋ menu.
        CommandGroup(replacing: .newItem) {
            Button(BentoTerminalWindow.newPaneTitle) { BentoTerminalWindow.newPaneOrWindow() }
                .keyboardShortcut("n", modifiers: .command)
            Button("New Window") { BentoTerminalWindow.newSessionWindow() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        // Where every Mac app keeps it: straight under "About BentoTerm".
        CommandGroup(after: .appInfo) {
            CheckForUpdatesMenuItem()
        }

        CommandMenu("Shell") {
            Button("Toggle Preview Panel") { BentoTerminalWindow.togglePreviewDock() }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Divider()
            // Scoped to the ACTIVE PANE's scrollback. Standard macOS find keys
            // so nobody has to learn them.
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
            // Same two names the toolbar's `+` and the Dock
            // menu use (`LaunchAction`). "New Window (no tmux)" was the old
            // name for a thing that is a terminal, not a window: closing it
            // discards it.
            Button(LaunchAction.emptySession.title) { BentoTerminalWindow.newWindow() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button(LaunchAction.plainTerminal.title) { BentoTerminalWindow.newWindowNoTmux() }
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
            // Mode-dispatched (see `swapActivePaneUp`): moves the pane within
            // the Parallel layout, or the window within the Focus order — so
            // the title names neither.
            Button("Move Up") { BentoPaneAction.dispatch(BentoPaneAction.swapPaneUp) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Move Down") { BentoPaneAction.dispatch(BentoPaneAction.swapPaneDown) }
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
            Button("Close Pane") { BentoPaneAction.dispatch(BentoPaneAction.closePane) }
                .keyboardShortcut("w", modifiers: .command)
            Button("Close Window") { BentoTerminalWindow.closeMainWindow() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }
    }
}
