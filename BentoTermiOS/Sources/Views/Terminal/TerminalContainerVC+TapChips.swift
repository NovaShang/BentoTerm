import UIKit
import SwiftUI
import Combine
import BentoSessionKit
import BentoTmuxKit
import BentoFilePreviewKit
import BentoFoundationKit
import BentoGhosttyKit
import BentoUISharedKit

// MARK: - Tap chips (tap a file path or a URL → chip → open)

extension TerminalContainerVC {
    /// Whether a path candidate could be offered at all — this pane knows
    /// where to read files from.
    var canPreviewPaths: Bool {
        pathPreviewContext != nil
    }

    /// Verify the tap's path candidates and show a chip if one of them exists:
    /// bare relatives, TUI wrap-chain joins, `…`-truncated suffixes all go
    /// through `SmartPathResolver` (direct stat → tree search → ancestors), so
    /// prose can't produce phantom chips and incomplete paths still find their
    /// file.
    ///
    /// Runs AFTER the tap has been routed, never before: the stat is remote on
    /// a phone, and nothing about the tap may wait on it.
    func resolvePathChip(_ hits: [SurfacePathHitEngine.TapHit],
                                 rootHints: [String], at point: CGPoint) {
        pathTapSeq += 1
        let seq = pathTapSeq
        hideTapChip()
        guard canPreviewPaths, !hits.isEmpty else { return }
        Task { [weak self] in
            guard let self, let context = self.pathPreviewContext?() else { return }
            guard let res = try? await SmartPathResolver.resolveFirst(
                paths: hits.map(\.path), rootHints: rootHints, context: context),
                  self.pathTapSeq == seq else { return }
            self.showPathChip(hits[res.index], at: point, resolvedPath: res.resolvedPath)
        }
    }

    /// The no-I/O half: a self-contained explicit token (`/…`, `~/…`, `./…`,
    /// quoted) is its own proof, so the chip goes up in the same run loop turn
    /// the tap arrived in.
    func showFastPathChip(_ hit: SurfacePathHitEngine.TapHit, at point: CGPoint) {
        pathTapSeq += 1
        hideTapChip()
        showPathChip(hit, at: point)
    }

    private func showPathChip(_ hit: SurfacePathHitEngine.TapHit, at point: CGPoint,
                              resolvedPath: String? = nil) {
        let highlight = tapChipHighlight ?? PathHighlightUIView(frame: .zero)
        highlight.frame = surface.frame
        highlight.rects = hit.rects
        view.addSubview(highlight)
        tapChipHighlight = highlight

        let chip = tapChip ?? TapConfirmChip(frame: .zero)
        tapChip = chip
        let name = ((resolvedPath ?? hit.path) as NSString).lastPathComponent
        chip.configure(fileName: name, maxWidth: view.bounds.width - 32)
        chip.onTap = { [weak self] in
            self?.hideTapChip()
            self?.presentPathPreviewSheet(path: resolvedPath ?? hit.path, line: hit.line)
        }
        presentTapChip(chip, at: point)
    }

    /// A dev server announced itself in this pane. Offer it; never open it.
    func noticeDevServer(in data: Data) {
        guard let text = String(data: data, encoding: .utf8),
              let found = DevServerDetector.detect(in: text) else { return }
        let paneKey = paneVM.map { "\($0.paneID)" } ?? "single"
        guard devServerOffers.shouldOffer(port: found.port, inPane: paneKey) else { return }
        showDevServerChip(found)
    }

    /// Bottom-centre of the pane rather than under a finger: nobody touched
    /// anything, so there is no point to anchor to.
    private func showDevServerChip(_ found: DevServerAnnouncement) {
        pathTapSeq += 1
        hideTapChip()
        let chip = tapChip ?? TapConfirmChip(frame: .zero)
        tapChip = chip
        chip.configure(devServerPort: found.port, maxWidth: view.bounds.width - 32)
        chip.onTap = { [weak self] in
            self?.hideTapChip()
            let origin = self?.surface?.linkOrigin
            WebSheetPresenter.present(url: found.url, origin: origin)
        }
        presentTapChip(chip, at: CGPoint(x: surface.bounds.midX,
                                         y: surface.bounds.maxY - 24))
    }

    /// Link chip: the URL is shown and opens only on a second, deliberate tap.
    /// Terminal output is dense and a finger is wide — going straight to the
    /// browser off one tap sent people out of the app by accident.
    func showLinkChip(_ url: String, at point: CGPoint) {
        pathTapSeq += 1   // a stat still in flight must not replace this chip
        hideTapChip()
        let chip = tapChip ?? TapConfirmChip(frame: .zero)
        tapChip = chip
        chip.configure(link: url, maxWidth: view.bounds.width - 32)
        chip.onTap = { [weak self] in
            self?.hideTapChip()
            LinkRouter.open(url, from: self?.surface.linkOrigin)
        }
        presentTapChip(chip, at: point)
    }

    private func presentTapChip(_ chip: TapConfirmChip, at point: CGPoint) {
        let off = surface.frame.origin
        // Above the finger, clamped inside the pane.
        var center = CGPoint(x: off.x + point.x, y: off.y + point.y - 44)
        let half = chip.bounds.width / 2
        center.x = min(max(center.x, half + 8), view.bounds.width - half - 8)
        center.y = max(center.y, chip.bounds.height / 2 + 8)
        chip.center = center
        view.addSubview(chip)

        chip.alpha = 0
        chip.transform = CGAffineTransform(scaleX: 0.9, y: 0.9).translatedBy(x: 0, y: 6)
        UIView.animate(withDuration: 0.22, delay: 0,
                       usingSpringWithDamping: 0.82, initialSpringVelocity: 0.4) {
            chip.alpha = 1
            chip.transform = .identity
        }
        HapticService.shared.sent()

        tapChipDismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hideTapChip(animated: true) }
        tapChipDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
    }

    func hideTapChip(animated: Bool = false) {
        tapChipDismissWork?.cancel()
        tapChipDismissWork = nil
        guard let chip = tapChip else { return }
        let highlight = tapChipHighlight
        tapChip = nil
        tapChipHighlight = nil
        if animated {
            UIView.animate(withDuration: 0.18, animations: {
                chip.alpha = 0
                highlight?.alpha = 0
            }, completion: { _ in
                chip.removeFromSuperview()
                highlight?.removeFromSuperview()
            })
        } else {
            chip.removeFromSuperview()
            highlight?.removeFromSuperview()
        }
    }

    /// Also the landing for a file tapped in the browsable tree, which is why
    /// it isn't private.
    func presentPathPreviewSheet(path: String, line: Int?) {
        guard let context = pathPreviewContext?() else { return }
        let model = FilePreviewLoadModel(path: path, line: line, context: context)
        let host = UIHostingController(rootView: FilePreviewSheet(model: model))
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.prefersEdgeAttachedInCompactHeight = true
        }
        present(host, animated: true)
    }
}
