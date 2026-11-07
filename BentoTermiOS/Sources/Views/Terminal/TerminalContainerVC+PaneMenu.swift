import UIKit
import SwiftUI
import Combine
import BentoSessionKit
import BentoTmuxKit
import BentoFilePreviewKit
import BentoFoundationKit
import BentoGhosttyKit
import BentoUISharedKit

// MARK: - Pane menu

extension TerminalContainerVC {
    /// Is this pane backed by tmux? A plain (non-tmux) session's single pane has
    /// no `paneVM`, and everything phrased in tmux vocabulary is gated on this.
    private var isTmuxPane: Bool { paneVM != nil }

    func makePaneMenu() -> UIMenu {
        // Rows, words and conditions come from the shared catalog
        // (PaneMenuLayout.iosPaneMenu). Every section that depends on state is
        // resolved when the menu OPENS (deferred, uncached): the session mode,
        // the zoom and tmux's copy-mode can all flip under the user — another
        // client, a mode switch after the menu was attached. Find and paste are
        // about the TERMINAL, so a plain shell keeps them; the rest is tmux
        // structure and is empty for a plain session.
        let children: [UIMenuElement] = PaneMenuLayout.IOSSection.allCases.flatMap {
            section -> [UIMenuElement] in
            switch section {
            case .find, .paste:
                return self.menuElements(PaneMenuLayout.iosPaneMenu(section, self.paneMenuContext()))
            default:
                return [UIDeferredMenuElement.uncached { [weak self] completion in
                    guard let self else { completion([]); return }
                    completion(self.menuElements(
                        PaneMenuLayout.iosPaneMenu(section, self.paneMenuContext())))
                }]
            }
        }
        return UIMenu(children: children)
    }

    /// The pane's state as the menu needs it, read at open.
    private func paneMenuContext() -> PaneMenuContext {
        // The mode isn't read here: the wrapper's `showsSplitActions` already
        // answers "does this pane offer splits" (Parallel only).
        PaneMenuContext(isTmuxPane: isTmuxPane,
                        sessionMode: .tiled,
                        zoomed: isZoomed?() ?? false,
                        inCopyMode: titleBar.modeBadge == .copyMode,
                        showsSplitActions: showsSplitActions?() ?? true)
    }

    private func menuElements(_ rows: [PaneMenuEntry]) -> [UIMenuElement] {
        rows.compactMap { row -> UIMenuElement? in
            switch row {
            case .command(let command):
                let zoomed = isZoomed?() ?? false
                let symbol = command.symbol(on: .iosPaneMenu, zoomed: zoomed)
                return UIAction(title: command.title(on: .iosPaneMenu, zoomed: zoomed),
                                image: symbol.map { UIImage(systemName: $0) } ?? nil,
                                attributes: command.role(on: .iosPaneMenu) == .destructive
                                    ? .destructive : []) { [weak self] _ in
                    self?.perform(command)
                }
            case .paste:
                return UIAction(title: "Paste",
                                image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                    // Same path the bar's paste key used: the pane surface's
                    // clipboard paste.
                    self?.handleAccessoryKey(.paste)
                }
            case .moveToSession:
                return makeMoveToSessionMenu()
            case .separator, .layouts:
                return nil   // not iOS pane-menu rows
            }
        }
    }

    /// How iOS performs a catalog command: the container's callbacks into the
    /// wrapper, which owns the session.
    private func perform(_ command: PaneCommand) {
        switch command {
        case .find: onFindRequested?(nil)
        case .zoom: onToggleZoom?()
        case .splitRight: onSplitRequested?(true)
        case .splitDown: onSplitRequested?(false)
        case .splitPathCommand: onSplitPathCommandRequested?()
        case .exitCopyMode: onExitCopyMode?()
        case .closePane: onCloseRequested?()
        default: break   // not offered in this menu
        }
    }

    /// Pane menu → Move to Session: other sessions (from the parent's cached
    /// list), plus "New Session…" which prompts for a name. The pane keeps
    /// running — it lands as a window of the target session, and moving the
    /// session's last pane makes the client follow it there. Resolution must
    /// stay synchronous — see `moveTargets`.
    private func makeMoveToSessionMenu() -> UIMenu {
        let deferred = UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else { completion([]); return }
            var items: [UIMenuElement] = (self.moveTargets?() ?? []).map { name in
                UIAction(title: name) { [weak self] _ in
                    self?.onMoveToSession?(name)
                }
            }
            items.append(UIAction(title: "New Session…",
                                  image: UIImage(systemName: "plus")) { [weak self] _ in
                self?.promptMoveToNewSession()
            })
            completion(items)
        }
        return UIMenu(title: "Move to Session",
                      image: UIImage(systemName: "rectangle.portrait.and.arrow.right"),
                      children: [deferred])
    }

    private func promptMoveToNewSession() {
        let copy = SessionPromptCopy.movePaneToNewSession
        let alert = UIAlertController(title: copy.title, message: copy.message,
                                      preferredStyle: .alert)
        alert.addTextField { $0.placeholder = copy.placeholder }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: copy.confirm, style: .default) { [weak self, weak alert] _ in
            guard let name = alert?.textFields?.first?.text, !name.isEmpty else { return }
            self?.onMoveToSession?(name)
        })
        present(alert, animated: true)
    }
}
