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

// MARK: - Scroll & momentum

extension TerminalContainerVC {
    @objc func handleScrollPan(_ g: UIPanGestureRecognizer) {
        // Don't scroll while voice recording or while a selection drag is active.
        if voiceController?.isRecording == true || isSelecting { return }
        let p = g.location(in: surface)
        switch g.state {
        case .began:
            stopMomentum()
            hideTapChip()   // rows shift under the chip; a stale anchor lies
            lastScrollPoint = p
        case .changed:
            let dy = p.y - lastScrollPoint.y
            let dx = p.x - lastScrollPoint.x
            lastScrollPoint = p
            // Finger down (dy>0) reveals older scrollback — natural touch paging.
            surface.scroll(deltaX: dx, deltaY: dy, at: p)
        case .ended:
            startMomentum(releaseVelocity: g.velocity(in: surface).y, at: p)
        default:
            break
        }
    }

    /// Begin the inertial phase of a scroll fling (vertical only — terminals
    /// have no horizontal scroll). Below the floor velocity the finger came to
    /// a controlled rest before lifting, so there is nothing to continue.
    private func startMomentum(releaseVelocity vy: CGFloat, at point: CGPoint) {
        dlog("fling: release v=\(Int(vy))pt/s")
        guard abs(vy) > 50 else { return }
        momentumVelocity = vy
        momentumAnchor = point
        momentumTravel = 0
        let link = CADisplayLink(target: MomentumLinkProxy(self),
                                 selector: #selector(MomentumLinkProxy.tick(_:)))
        // Track ProMotion: a 120Hz decay reads noticeably smoother on
        // row-quantized content than the 60Hz default.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        momentumLink = link
    }

    func stopMomentum() {
        momentumLink?.invalidate()
        momentumLink = nil
        momentumVelocity = 0
    }

    fileprivate func momentumTick(_ link: CADisplayLink) {
        // The pane can close or the screen dismiss mid-flight; surface.scroll
        // itself is safe after teardown (nil engine handle), but there is no
        // point ticking a detached view.
        guard let surface, surface.window != nil else { stopMomentum(); return }
        let dt = link.targetTimestamp - link.timestamp
        surface.scroll(deltaX: 0, deltaY: momentumVelocity * dt, at: momentumAnchor)
        momentumTravel += momentumVelocity * dt
        momentumVelocity *= pow(Self.decelRate, dt * 1000)
        if abs(momentumVelocity) < 30 {
            dlog("fling: settled after \(Int(momentumTravel))pt")
            stopMomentum()
        }
    }
}

/// Weak-target trampoline for the scroll-momentum CADisplayLink — the link
/// retains its target, so pointing it straight at the VC would keep a dismissed
/// pane (and its fling) alive. Same pattern as the surface's render-link proxy.
/// @MainActor is sound here: the link is scheduled on the main run loop, and
/// the @objc thunk asserts the actor on entry.
@MainActor
private final class MomentumLinkProxy {
    private weak var vc: TerminalContainerVC?
    init(_ vc: TerminalContainerVC) { self.vc = vc }
    @objc func tick(_ link: CADisplayLink) {
        // If the VC died without teardown() mid-glide, self-invalidate so the
        // link doesn't fire into a dead target forever.
        guard let vc else { link.invalidate(); return }
        vc.momentumTick(link)
    }
}
