import UIKit
import SwiftUI
import Combine
import BentoAgentKit
import BentoSessionKit
import BentoTmuxKit
import BentoFilePreviewKit
import BentoFoundationKit
import BentoGhosttyKit
import BentoUISharedKit

// MARK: - Selection handles & copy

extension TerminalContainerVC {
    /// Number of terminal columns a string occupies on one line (CJK/wide → 2).
    private func displayColumns(of s: Substring) -> Int {
        var n = 0
        for scalar in s.unicodeScalars {
            let v = scalar.value
            let wide = (v >= 0x1100 && v <= 0x115F) || (v >= 0x2E80 && v <= 0xA4CF) ||
                       (v >= 0xAC00 && v <= 0xD7A3) || (v >= 0xF900 && v <= 0xFAFF) ||
                       (v >= 0xFF00 && v <= 0xFF60) || (v >= 0x1F300 && v <= 0x1FAFF)
            n += wide ? 2 : 1
        }
        return n
    }

    /// Show / reposition the two draggable selection handles from the engine's
    /// current selection geometry. Hides them when there's no selection or the
    /// keyboard is down (selection only exists in keyboard mode).
    func refreshSelectionHandles() {
        guard keyboardMode, surface.hasSelection, let geo = surface.selectionGeometry() else {
            hideSelectionHandles()
            return
        }
        let off = surface.frame.origin            // surface sits below the title bar
        let cell = geo.cell
        let startCorner = CGPoint(x: geo.topLeft.x + off.x, y: geo.topLeft.y + off.y)

        // ghostty only reports the selection's top-left, so derive the end:
        // single line → start + text width; multi-line → last line width, N rows
        // down (approximate, but the handle becomes exact once dragged).
        let text = surface.selectedText() ?? ""
        let endCorner: CGPoint
        if text.contains("\n") {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let lastCols = displayColumns(of: lines.last ?? "")
            endCorner = CGPoint(x: off.x + CGFloat(lastCols) * cell.width,
                                y: startCorner.y + CGFloat(lines.count) * cell.height)
        } else {
            endCorner = CGPoint(x: startCorner.x + CGFloat(displayColumns(of: text[...])) * cell.width,
                                y: startCorner.y + cell.height)
        }

        let start = ensureHandle(\.startHandle, isStart: true)
        let end = ensureHandle(\.endHandle, isStart: false)
        start.cellHeight = cell.height
        end.cellHeight = cell.height
        start.positionStemTop(CGPoint(x: startCorner.x, y: startCorner.y))
        end.positionStemTop(CGPoint(x: endCorner.x, y: endCorner.y - cell.height))
        view.bringSubviewToFront(start)
        view.bringSubviewToFront(end)
        start.isHidden = false
        end.isHidden = false
        selStartCorner = startCorner
        selEndCorner = endCorner
    }

    private func ensureHandle(_ keyPath: ReferenceWritableKeyPath<TerminalContainerVC, SelectionHandle?>,
                              isStart: Bool) -> SelectionHandle {
        if let h = self[keyPath: keyPath] { return h }
        let h = SelectionHandle(isStart: isStart)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleSelectionHandlePan(_:)))
        h.addGestureRecognizer(pan)
        view.addSubview(h)
        self[keyPath: keyPath] = h
        return h
    }

    func hideSelectionHandles() {
        startHandle?.isHidden = true
        endHandle?.isHidden = true
        selStartCorner = nil
        selEndCorner = nil
    }

    @objc private func handleSelectionHandlePan(_ g: UIPanGestureRecognizer) {
        guard let handle = g.view as? SelectionHandle,
              let cell = surface.selectionGeometry()?.cell,
              let startCorner = selStartCorner, let endCorner = selEndCorner else { return }

        // Anchor at the cell center of the OTHER (fixed) end; extend to the
        // finger, clamped into the surface.
        let fixedCorner = handle.isStart ? endCorner : startCorner
        let anchorView = handle.isStart
            ? CGPoint(x: fixedCorner.x - cell.width / 2, y: fixedCorner.y - cell.height / 2)
            : CGPoint(x: fixedCorner.x + cell.width / 2, y: fixedCorner.y - cell.height / 2)

        let p = g.location(in: view)
        let off = surface.frame.origin
        func toSurface(_ pt: CGPoint) -> CGPoint {
            CGPoint(x: min(max(pt.x - off.x, 1), surface.bounds.width - 1),
                    y: min(max(pt.y - off.y, 1), surface.bounds.height - 1))
        }

        switch g.state {
        case .began:
            surface.selectionBegin(at: toSurface(anchorView))
            surface.selectionExtend(to: toSurface(p))
        case .changed:
            surface.selectionExtend(to: toSurface(p))
            refreshSelectionHandles()
        case .ended, .cancelled, .failed:
            surface.selectionEnd()
            refreshSelectionHandles()
            if surface.hasSelection { presentEditMenu(at: p) }
        default:
            break
        }
    }

    private func copySelection() {
        guard let text = surface.selectedText(), !text.isEmpty else { return }
        UIPasteboard.general.string = text
        HapticService.shared.sent()
        showCopyToast()
    }

    private func showCopyToast() { showToast("Copied") }

    /// Brief centred-bottom toast. Was inlined in the copy path; the
    /// mouse-grabbed hint needs the same thing, and one-off teaching moments
    /// like these are exactly what it's for.
    func showToast(_ text: String) {
        let label = UILabel()
        label.text = "  \(text)  "
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.backgroundColor = UIColor(white: 0, alpha: 0.78)
        label.layer.cornerRadius = 12
        label.layer.masksToBounds = true
        label.alpha = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -40),
            label.heightAnchor.constraint(equalToConstant: 30),
        ])
        UIView.animate(withDuration: 0.18, animations: { label.alpha = 1 }) { _ in
            UIView.animate(withDuration: 0.25, delay: 0.9, options: [],
                           animations: { label.alpha = 0 },
                           completion: { _ in label.removeFromSuperview() })
        }
    }
}

// MARK: - UIEditMenuInteractionDelegate (text selection menu)

extension TerminalContainerVC: @preconcurrency UIEditMenuInteractionDelegate {
    func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                             menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        var items: [UIMenuElement] = []
        if surface.hasSelection {
            items.append(UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.copySelection()
            })
        }
        // Paste lands at the terminal cursor (bracketed-paste-safe). Offered only
        // when the clipboard actually has text, so the menu doesn't show a dead item.
        if UIPasteboard.general.hasStrings {
            items.append(UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                self?.surface.pasteFromClipboard()
            })
        }
        items.append(UIAction(title: "Select All", image: UIImage(systemName: "selection.pin.in.out")) { [weak self] _ in
            guard let self else { return }
            self.surface.selectAll()
            if self.surface.hasSelection { self.copySelectionMenuReshow() }
        })
        return UIMenu(children: items)
    }

    /// After Select All, re-show the menu so Copy is available on the new selection.
    private func copySelectionMenuReshow() {
        let p = CGPoint(x: surface.bounds.midX, y: surface.bounds.midY)
        DispatchQueue.main.async { [weak self] in self?.presentEditMenu(at: p) }
    }
}

/// An iOS-style text-selection handle: a thin stem one cell tall with a round
/// knob at one end — top for the selection start, bottom for the end (PRD §3.8).
/// The view is padded by `inset` on every side so the small knob is easy to grab.
final class SelectionHandle: UIView {
    let isStart: Bool
    var cellHeight: CGFloat = 16 { didSet { setNeedsDisplay() } }
    private static let inset: CGFloat = 18
    private let knobRadius: CGFloat = 5.5
    private let stemWidth: CGFloat = 2

    init(isStart: Bool) {
        self.isStart = isStart
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Place the view so its stem starts at `stemTop` (superview coords) and
    /// runs down one cell.
    func positionStemTop(_ stemTop: CGPoint) {
        let i = Self.inset
        frame = CGRect(x: stemTop.x - i, y: stemTop.y - i,
                       width: i * 2, height: cellHeight + i * 2)
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        // systemBlue resolves against this view's trait during draw.
        ctx.setFillColor(UIColor.systemBlue.cgColor)
        let cx = bounds.midX
        let top = Self.inset
        ctx.fill(CGRect(x: cx - stemWidth / 2, y: top, width: stemWidth, height: cellHeight))
        let knobY = isStart ? top : top + cellHeight
        ctx.fillEllipse(in: CGRect(x: cx - knobRadius, y: knobY - knobRadius,
                                   width: knobRadius * 2, height: knobRadius * 2))
    }
}
