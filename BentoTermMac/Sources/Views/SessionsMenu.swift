import SwiftUI
import AppKit
import BentoSessionKit
import BentoFoundationKit
import BentoUISharedKit

// The `SessionsMenuView` that used to live here is gone, and its behavior now
// lives in `TerminalToolbarController.sessionSwitchSection` as a hand-built
// NSMenu.
//
// It was recovered from the deleted menu bar in e6560d5 and then never wired to
// anything: the toolbar's Sessions button has always built its own NSMenu, so
// this file compiled a second, invisible version of the same menu that no user
// could reach and no reader could tell was dead. Two implementations of one menu
// is exactly the drift the recovery was meant to avoid.
//
// What it knew is preserved in the AppKit version — per-session submenus, the
// windows list, rename/kill for a session you are not in, the attached-vs-open
// glyph distinction — with one correction: its window rows attached through a
// call that ignored the window, so picking window 3 landed wherever the session
// happened to be. See
// `BentoTerminalWindow.focusOrOpen(_:windowIndex:)`.
//
// The two NSAlert helpers below survive unchanged and are used by that menu.

/// promptRename pops a small modal NSAlert with just a text field. We
/// suppress the default app-icon badge so the dialog stays compact.
/// Used by the toolbar's Sessions menu.
@MainActor
func promptRename(current: String) -> String? {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = SessionPromptCopy.renameSession.title
    alert.informativeText = SessionPromptCopy.renameSession.message ?? ""
    // Suppress the default Bento icon on the left — a rename prompt doesn't
    // need a branded badge.
    alert.icon = NSImage(size: NSSize(width: 1, height: 1))
    alert.addButton(withTitle: SessionPromptCopy.renameSession.confirm)
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
    let copy = SessionPromptCopy.killSession(session)
    alert.messageText = copy.title
    alert.informativeText = copy.message ?? ""
    alert.alertStyle = .warning
    alert.addButton(withTitle: copy.confirm)
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
}
