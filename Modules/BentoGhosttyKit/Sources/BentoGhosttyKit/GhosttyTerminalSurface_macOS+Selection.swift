#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import BentoFilePreviewKit
import BentoFoundationKit
import AppKit
import GhosttyKit

extension GhosttyTerminalSurface {

    // MARK: - Selection / clipboard

    var hasSelection: Bool {
        guard let surface else { return false }
        return GhosttySel.hasSelection(surface)
    }

    func selectedText() -> String? {
        guard let surface else { return nil }
        return GhosttySel.selectedText(surface)
    }

    @discardableResult
    func selectAll() -> Bool {
        guard let surface else { return false }
        return GhosttySel.selectAll(surface)
    }

    func copySelection() {
        guard let text = selectedText(), !text.isEmpty else { return }
        TerminalClipboard.write(text)
    }

    func pasteFromClipboard() {
        guard let surface, let text = TerminalClipboard.read(), !text.isEmpty else { return }
        // Route through ghostty's paste action (not raw `ghostty_surface_text`)
        // so it applies bracketed-paste wrapping when the running app enabled it
        // — otherwise newlines in the pasted text fire Enter per line (e.g. you
        // can't paste a multi-line block into Claude Code). The action requests
        // the clipboard via the runtime's `read_clipboard_cb`, which completes on
        // the surface we register here.
        GhosttyRuntime.shared.pasteSurface = surface
        GhosttySel.bindingAction("paste_from_clipboard", on: surface)
    }

    // MARK: - Context menu (right-click)

    public override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        contextMenuPathHit = pathHit(at: convert(event.locationInWindow, from: nil))
        if let hit = contextMenuPathHit {
            let name = (hit.candidate.path as NSString).lastPathComponent
            let preview = NSMenuItem(title: "Preview \"\(name)\"",
                                     action: #selector(contextPreviewPath), keyEquivalent: "")
            preview.target = self
            menu.addItem(preview)
            let copyPath = NSMenuItem(title: "Copy Path",
                                      action: #selector(contextCopyPath), keyEquivalent: "")
            copyPath.target = self
            menu.addItem(copyPath)
            menu.addItem(.separator())
        }
        let copy = NSMenuItem(title: "Copy", action: #selector(contextCopy), keyEquivalent: "c")
        copy.isEnabled = hasSelection
        copy.target = self
        menu.addItem(copy)
        let paste = NSMenuItem(title: "Paste", action: #selector(contextPaste), keyEquivalent: "v")
        paste.target = self
        menu.addItem(paste)
        menu.addItem(.separator())
        let all = NSMenuItem(title: "Select All", action: #selector(contextSelectAll), keyEquivalent: "a")
        all.target = self
        menu.addItem(all)
        let find = NSMenuItem(title: "Find…", action: #selector(contextFind), keyEquivalent: "f")
        find.target = self
        menu.addItem(find)
        // Always reachable, unlike the title-bar badge (Focus mode has no title
        // bar), and the mode is easy to enter by accident from another client.
        if tmuxInMode {
            menu.addItem(.separator())
            let exitMode = NSMenuItem(title: "Exit tmux copy-mode",
                                      action: #selector(contextExitCopyMode), keyEquivalent: "")
            exitMode.target = self
            menu.addItem(exitMode)
        }
        // Only offered where it can matter — a pane whose program has taken the
        // mouse. ⇧-drag is the per-gesture answer; this is the sticky one.
        if mouseReporting.any {
            menu.addItem(.separator())
            let mouse = NSMenuItem(title: "Mouse Reporting",
                                   action: #selector(contextToggleMouseReporting),
                                   keyEquivalent: "")
            mouse.state = mouseReportingSuppressed ? .off : .on
            mouse.target = self
            menu.addItem(mouse)
        }
        // The host's pane actions last, as one block ending in Close Pane.
        //
        // The surface's own text/clipboard entries stay on top because they are
        // what a right-click on TEXT is usually reaching for, and because the
        // contextual toggles above are about this surface too — keeping them
        // together means one insertion point instead of interleaving the two
        // sources. Close Pane is still the final item overall.
        let paneItems = contextMenuPaneItems?() ?? []
        if !paneItems.isEmpty {
            menu.addItem(.separator())
            for item in paneItems { menu.addItem(item) }
        }
        return menu
    }

    @objc private func contextFind() { beginSearch() }

    @objc private func contextExitCopyMode() { onExitCopyMode?() }

    @objc private func contextToggleMouseReporting() {
        mouseReportingSuppressed.toggle()
        PaneHintChip.show(
            mouseReportingSuppressed
                ? "Mouse reporting off — this app no longer sees the mouse"
                : "Mouse reporting on",
            in: self)
    }

    @objc private func contextCopy() { copySelection() }
    @objc private func contextPaste() { pasteFromClipboard() }
    @objc private func contextSelectAll() { _ = selectAll() }
    @objc private func contextPreviewPath() {
        if let hit = contextMenuPathHit { presentPathPreview(hit) }
        contextMenuPathHit = nil
    }
    @objc private func contextCopyPath() {
        if let hit = contextMenuPathHit { TerminalClipboard.write(hit.candidate.path) }
        contextMenuPathHit = nil
    }

    /// The whole scrollback as text (one line per row, top-aligned with the
    /// SCROLLBAR row space).
    public func readScrollback() -> String? {
        guard let surface else { return nil }
        return GhosttySel.screenText(surface)
    }
}
#endif
