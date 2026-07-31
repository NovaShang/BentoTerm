import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Single-finger press-and-hold recognizer for SpeakTerm's primary voice input.
///
/// Why a custom recognizer instead of `UILongPressGestureRecognizer`:
/// - We need a precise hold threshold (180ms) that is shorter than SwiftTerm's
///   selection long-press, so we win cleanly via `shouldRequireFailureOf` on
///   any real hold.
/// - We need to fail fast on quick taps and on early movement, so SwiftTerm's
///   tap-to-position-cursor and any flick gestures keep working untouched.
/// - We want one recognizer that owns the full press → drag → release lifecycle
///   so direction tracking in `.changed` is unambiguous.
///
/// Coexistence policy is enforced by `TerminalContainerVC` as the delegate:
/// SwiftTerm's selection long-press requires THIS gesture to fail before it
/// can activate. In practice, since we commit at 180ms and SwiftTerm's at
/// ~500ms, we always win on a sustained hold — by design.
@MainActor
final class VoicePressGesture: UIGestureRecognizer {

    /// Time the finger must stay down (mostly still) before we commit.
    var holdThreshold: TimeInterval = 0.18

    /// Movement (in points) allowed during the arming window before we bail
    /// and let other recognizers take the touch. Kept tight so even a gentle
    /// scroll drag fails us promptly — the pan recognizer isn't asked to wait
    /// for our failure, so the smaller this is, the snappier scrolling feels.
    var slop: CGFloat = 6

    /// Fired the moment a (single) finger lands, before the hold threshold is
    /// even evaluated. Used to prewarm the mic engine so a hold that becomes a
    /// voice recording starts capturing instantly — the same button-down
    /// prewarm the macOS controller gets. Cheap + idempotent, so firing on
    /// touches that turn into scrolls/taps is harmless.
    var onTouchDown: (() -> Void)?

    /// Consulted at touch-down, BEFORE `onTouchDown` fires, so the host can
    /// veto arming from pre-touch state that `onTouchDown` itself mutates
    /// (the scroll fling it stops): a finger landing mid-glide only "catches"
    /// the content — UIScrollView's dead-touch-during-deceleration semantics —
    /// and must not become a voice press or selection. Returning false fails
    /// this recognizer for the whole touch; taps and the scroll pan still see it.
    var shouldArm: (() -> Bool)?

    private var startLocation: CGPoint = .zero
    private var armTimer: Timer?
    private var trackedTouch: UITouch?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func reset() {
        super.reset()
        cancelArmTimer()
        trackedTouch = nil
        startLocation = .zero
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        // Single-finger only. If a second finger lands, we bail so multi-touch
        // gestures (two-finger scroll, pinch) are unaffected.
        if trackedTouch != nil || touches.count != 1 {
            state = .failed
            return
        }
        guard let touch = touches.first, let view else {
            state = .failed
            return
        }
        trackedTouch = touch
        startLocation = touch.location(in: view)
        // Read the veto before onTouchDown — it inspects the very state
        // (an in-flight fling) that onTouchDown's handler stops.
        let vetoed = shouldArm?() == false
        onTouchDown?()
        if vetoed {
            state = .failed
            return
        }
        scheduleArmTimer()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch), let view else { return }
        let loc = touch.location(in: view)
        switch state {
        case .possible:
            // Still arming — early movement means this is a flick / drag, not a hold.
            let dx = loc.x - startLocation.x
            let dy = loc.y - startLocation.y
            if dx * dx + dy * dy > slop * slop {
                state = .failed
            }
        case .began, .changed:
            state = .changed
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        switch state {
        case .possible:
            // Lifted before threshold → not a hold. Fail so SwiftTerm's tap fires.
            state = .failed
        case .began, .changed:
            state = .ended
        default:
            break
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        if state == .began || state == .changed {
            state = .cancelled
        } else {
            state = .failed
        }
    }

    // MARK: - Arm timer

    private func scheduleArmTimer() {
        cancelArmTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: holdThreshold, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.state == .possible else { return }
                // Commit. From this point on the touch belongs to us; SwiftTerm's
                // long-press will be force-failed because of the delegate's
                // shouldRequireFailureOf wiring.
                self.cancelsTouchesInView = true
                self.state = .began
            }
        }
        armTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelArmTimer() {
        armTimer?.invalidate()
        armTimer = nil
    }

    /// Current finger location in the recognizer's view coordinates.
    /// Useful for handlers that need a single source of truth.
    func currentLocation() -> CGPoint {
        guard let view, let touch = trackedTouch else { return startLocation }
        return touch.location(in: view)
    }
}
