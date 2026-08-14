import SwiftUI
import BentoFoundationKit

/// The voice overlay's visual layer, shared by iOS + macOS: a glowing glass mic
/// orb at center, four glass direction buttons that highlight + grow on the
/// active direction, and a glass "finger ball" that rides the ACTIVE AXIS out
/// from the center mic. The transcript bubble also holds the status row and a
/// dim one-line action hint ("Release to …") inside it. Pure SwiftUI — no
/// UIKit/AppKit — so it renders identically wherever it's hosted.
///
/// Liquid Glass on iOS 26 / macOS 26: the targets + finger ball are grouped in
/// one `GlassEffectContainer` — that fusion IS the point, the material blends
/// and the elements share the proximity response (the "soul"). Each is an
/// `.interactive()` glass surface. Highlight = the direction's SEMANTIC LIT
/// COLOR (send green / cancel red / convert blue / correct orange; the center
/// stays emerald) as a bright base + a WHITE icon + the GLASS DISC GROWING
/// 60->74, morphed by the container through `.glassEffectID(_:in:)` +
/// `.glassEffectTransition(.matchedGeometry)` — the supported way to animate
/// glass; hand-animating the frame/scale fought the framework. Emerald lives
/// only on the center mic orb. The finger ball is a pure clear-glass marble
/// (no ring, no shadow). Below 26 -> flat bento surfaces.
///
/// It choreographs its own entrance and exit (see "Enter / exit"), because
/// neither host can: iOS drops the view into the tree and macOS just unhides a
/// long-lived `NSHostingView`, so a transition would only run on one of them.
/// Driving it from the controller's published state instead means both platforms
/// get the same animation.
///
/// `fingerOffset` is the drag delta from the press origin (y-down point space;
/// both hosts flip macOS's y-up before passing). The ball is PROJECTED onto the
/// active axis — the same dominant-axis classification the controller
/// publishes — so it starts fused at the center mic and slides out along that
/// axis by the drag's component on it: a diagonal drag rides the dominant axis
/// instead of leaving the cross. It moves with NO animation (a finger proxy
/// must be 1:1; a spring here lags, freezes on direction change, then snaps),
/// fades in as the drag leaves center, and is clamped so a far drag can't push
/// it off the overlay.
public struct VoiceCompassView: View {
    /// Overlay footprint, and how far its content reaches from the center anchor.
    /// Hosts need these to keep the compass clear of screen edges — the compass is
    /// centered on the touch point, so nothing inside it can enforce that.
    public enum Metrics {
        public static let size = CGSize(width: 360, height: 580)

        /// What the COMPASS ITSELF needs around the anchor: the ring sits at
        /// radius 80, the active disc is 74 across, and its glow adds a few more
        /// points. This — and only this — is what a host must keep on screen,
        /// because it is the part that has to stay under the finger/cursor.
        public static let ringReach: CGFloat = 130

        /// How far the transcript bubble reaches beyond the anchor on whichever
        /// side it is placed. A host with less room than this on the preferred
        /// side flips the bubble instead of dragging the whole compass inward
        /// (`Placement.bubbleBelow`).
        public static let bubbleReach: CGFloat = 270
        /// Half the bubble's width, for the same reason horizontally
        /// (`Placement.bubbleShift`).
        public static let bubbleHalfWidth: CGFloat = 140
    }

    /// Where the bubble goes when the anchor is near an edge. The compass stays
    /// under the finger; only the bubble moves.
    ///
    /// The old behaviour reserved the bubble's whole footprint around EVERY
    /// press and clamped the anchor by it, so a band 270pt deep along the top,
    /// 120pt along the bottom and 180pt down each side could not host a compass
    /// at the cursor at all — in a normal window that is most of the screen.
    public struct Placement: Equatable, Sendable {
        /// The bubble hangs below the compass (no room above the anchor).
        public var bubbleBelow: Bool
        /// Sideways nudge that keeps the bubble on screen while the compass
        /// stays put. Positive = right.
        public var bubbleShift: CGFloat

        public init(bubbleBelow: Bool = false, bubbleShift: CGFloat = 0) {
            self.bubbleBelow = bubbleBelow
            self.bubbleShift = bubbleShift
        }

        /// Resolve the placement for an anchor inside `bounds`, given how much
        /// of each edge is unavailable (safe areas, a floating toolbar…).
        public static func resolve(anchor: CGPoint, in bounds: CGRect,
                                   insets: EdgeInsets = EdgeInsets(),
                                   margin: CGFloat = 8) -> Placement {
            let roomAbove = anchor.y - (bounds.minY + insets.top)
            let below = roomAbove < Metrics.bubbleReach + margin
            let minX = bounds.minX + insets.leading + margin + Metrics.bubbleHalfWidth
            let maxX = bounds.maxX - insets.trailing - margin - Metrics.bubbleHalfWidth
            var shift: CGFloat = 0
            if minX <= maxX { shift = min(max(anchor.x, minX), maxX) - anchor.x }
            return Placement(bubbleBelow: below, bubbleShift: shift)
        }
    }

    /// Observed directly: the shared controller's published state IS the overlay's
    /// state. (It used to be mirrored into the hosts and re-fed here — macOS
    /// rebuilt its hosting root view on every change, which threw away the
    /// SwiftUI animation state, so the bubble jumped instead of growing.)
    @ObservedObject public var controller: VoiceController

    /// Set by the host, which is the only one that knows where on screen the
    /// press landed.
    public var placement: Placement

    public init(controller: VoiceController, placement: Placement = Placement()) {
        self.controller = controller
        self.placement = placement
    }

    private let accent = Color(red: 0.30, green: 0.90, blue: 0.62)
    private let radius: CGFloat = 80

    /// Ceiling for the transcript area (5 lines at 14pt + 3pt spacing). The bubble
    /// grows with what you say up to here, then windows to the newest lines.
    private static let maxTextHeight: CGFloat = 100
    /// Slot the bubble is bottom-pinned in: enough for `maxTextHeight` plus the
    /// status row, hint row and padding, so growth never gets clipped.
    private static let bubbleSlot: CGFloat = maxTextHeight + 76

    /// Identity space the GlassEffectContainer uses to morph each target's glass
    /// between its idle and active size (see `glassEffectID`).
    @Namespace private var glassNS

    /// Line pitch of the 14pt + 3pt-spacing transcript (approx; the measured
    /// full height caps the reveal, so the approximation only paces it).
    private static let linePitch: CGFloat = 20

    /// Transcript area currently revealed, in points. Dictation does NOT arrive
    /// line by line — the first partial is often a whole sentence, so tracking
    /// the text directly would jump the bubble straight to full size. Instead
    /// the area unfurls ONE LINE AT A TIME toward the transcript's full height
    /// (capped at `maxTextHeight`): start small, grow row by row.
    @State private var revealedHeight: CGFloat = 0
    /// The transcript's full natural height, measured without the window.
    @State private var fullTextHeight: CGFloat = 0
    /// The per-line reveal task; restarted on every transcript/height change.
    @State private var revealTask: Task<Void, Never>?

    /// Everything here used to be hardcoded white, which is invisible in light
    /// mode. Observing the store means the overlay repaints when the appearance
    /// flips. (Core can't reach the app target's BentoBrand tokens, but
    /// ThemeStore is the same authority they resolve against.)
    @ObservedObject private var themeStore = ThemeStore.shared

    private var isDark: Bool { themeStore.effectiveIsDark }

    /// Primary content on glass: icons of active targets, transcript text.
    private var ink: Color { isDark ? .white : Color(red: 0.08, green: 0.09, blue: 0.11) }
    /// Idle icons and secondary labels.
    private var inkDim: Color { ink.opacity(isDark ? 0.6 : 0.55) }
    /// The action hint — quietest thing in the bubble.
    private var inkMute: Color { ink.opacity(isDark ? 0.5 : 0.45) }
    /// Activation color per direction — the semantic "lit" colors: send=green,
    /// cancel=red, convert=blue, correct=orange, center keeps the brand emerald
    /// anchor. The active disc tints with its own bright color (white icon on
    /// top, no appearance split — a saturated tint reads on both light and dark
    /// glass). (No built-in glow API exists in this SDK — probe-verified — so
    /// the glow stays a shadow, as before.)
    private func color(for d: VoiceDirection) -> Color {
        switch d {
        case .up:    return .green
        case .down:  return .red
        case .left:  return .blue
        case .right: return .orange
        case .none:  return accent
        }
    }

    public var body: some View {
        ZStack {
            // Pin the bubble by its BOTTOM edge so a taller transcript grows
            // upward, away from the compass, instead of creeping down over it.
            // It is glass too, so on the way out it also has to LEAVE THE TREE
            // rather than fade (see `isMounted`) — it is the first thing to go,
            // which is what leaves the eye on the target.
            if !leaving || chromeShown {
                bubble
                    // Above the compass by default, below it when the press
                    // landed too near the top — mirrored, so it still grows away
                    // from the ring and never creeps over it.
                    .frame(height: Self.bubbleSlot,
                           alignment: placement.bubbleBelow ? .top : .bottom)
                    .offset(x: placement.bubbleShift,
                            y: placement.bubbleBelow ? (radius + 106) : -(radius + 106))
                    // The rise + fade is an entrance flourish; `leaving` pins it
                    // in place so the exit adds no movement of its own.
                    .opacity(chromeShown ? 1 : 0)
                    .scaleEffect(chromeShown || leaving ? 1 : 0.94,
                                 anchor: placement.bubbleBelow ? .top : .bottom)
                    // The entrance drifts in from the compass, so it mirrors too.
                    .offset(y: chromeShown || leaving ? 0 : (placement.bubbleBelow ? -10 : 10))
                    .animation(chromeShown ? Self.chromeFade : Self.chromeOut, value: chromeShown)
                    .transition(.opacity)
            }
            compass
        }
        // Fixed size so the compass center sits at the host's anchor point
        // (NSView center on macOS, `.position` on iOS). Both place by center, so
        // the height only needs to fit the bubble above without clipping — it
        // does not shift the anchor.
        .frame(width: Metrics.size.width, height: Metrics.size.height)
        .onAppear { if controller.showOverlay && !controller.isDismissing { playIntro() } }
        .onChange(of: controller.showOverlay) { _, show in if show { playIntro() } }
        .onChange(of: controller.isDismissing) { _, dismissing in
            if dismissing { playOutro() }
            // Cancelled mid-fold (a new press landed inside the outro): the
            // overlay is staying, so grow it back out.
            else if controller.showOverlay { playIntro() }
        }
        .onDisappear { choreography?.cancel() }
    }

    // MARK: - Enter / exit

    /// Expanded: 1 = the targets sit out on their arms, 0 = everything is a dot
    /// at the center. The intro grows out of that dot; the outro folds back into
    /// it. This is the whole "expand from the middle" — position and disc size
    /// both ride it, and the glass container morphs the size change for us.
    @State private var open = false
    /// The outro is running.
    @State private var leaving = false
    /// The one target that outlives the rest on the way out: whatever the release
    /// acted on (the center mic when nothing was aimed at). Captured when the
    /// outro starts, since the controller clears the direction after it.
    @State private var finale: VoiceDirection = .none
    /// The finale target is still there — it goes a beat after everything else.
    @State private var finaleShown = true
    /// The transcript bubble is still there.
    @State private var chromeShown = false
    /// The finger marble is still there. It leaves before anything else.
    @State private var ballShown = true
    /// The running intro/outro schedule; cancelled if the other one starts.
    @State private var choreography: Task<Void, Never>?

    private static let bloom = Animation.spring(response: 0.34, dampingFraction: 0.72)
    /// Everything that is not the finale target: a quick clean dissolve.
    private static let dissolve = Animation.easeOut(duration: 0.14)
    private static let chromeFade = Animation.easeOut(duration: 0.18)
    /// The bubble leaving — goes with the rest of the chrome, fast.
    private static let chromeOut = Animation.easeOut(duration: 0.12)
    /// The finger marble leaving — quicker still; it is the first thing out.
    private static let ballOut = Animation.easeOut(duration: 0.08)
    /// The finale target waits this long, then takes its time. The contrast
    /// between the two speeds IS the effect: the compass clears, and the thing
    /// you actually chose lingers a moment longer.
    private static let finaleDelay = Duration.milliseconds(100)
    private static let finaleOut = Animation.easeInOut(duration: 0.36)

    /// Bloom out of the center. Starts from the collapsed state, which needs to
    /// be on screen for a frame first — animating from a value SwiftUI never
    /// rendered just snaps to the end.
    private func playIntro() {
        choreography?.cancel()
        leaving = false
        finale = .none
        finaleShown = true
        ballShown = true
        open = false
        chromeShown = false
        choreography = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            withAnimation(Self.bloom) { open = true }
            // The bubble follows the compass out rather than racing it.
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
            chromeShown = true
        }
    }

    /// Leave by FADING ONLY — nothing moves, nothing resizes. The compass holds
    /// its shape and dissolves at different speeds: the bubble goes first and
    /// fastest, the targets the release did not act on go with it, and the one it
    /// did act on lingers and fades slowest. (An earlier version folded
    /// everything back into the center; the motion read as the compass being
    /// yanked away rather than settling.) It all has to finish inside
    /// `VoiceController.dismissDuration` — that is when the overlay is torn down.
    private func playOutro() {
        choreography?.cancel()
        finale = controller.activeDirection
        choreography = Task { @MainActor in
            // Get off the current turn first. This is called from the onChange
            // that observes the controller, and a `withAnimation` issued there —
            // inside the update the controller's own publish is already driving —
            // got folded into that non-animated transaction: the compass blinked
            // out instead of fading. The entrance never hit this because it has
            // always run from here.
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            DIAG("[compass] outro stage 1 (marble, bubble, non-active)")
            // The marble first: the finger it stands for is already gone.
            withAnimation(Self.ballOut) { ballShown = false }
            withAnimation(Self.chromeOut) { chromeShown = false }
            withAnimation(Self.dissolve) {
                leaving = true
                open = false
            }
            try? await Task.sleep(for: Self.finaleDelay)
            guard !Task.isCancelled else { return }
            DIAG("[compass] outro stage 2 (finale \(finale))")
            withAnimation(Self.finaleOut) { finaleShown = false }
        }
    }

    /// Is this target on screen? Everything follows `open` — except, during the
    /// outro, the finale target, which holds until its own beat.
    private func isShown(_ d: VoiceDirection) -> Bool {
        if leaving && d == finale { return finaleShown }
        return open
    }

    /// How far out along its arm the target sits: 1 = home, 0 = fused at center.
    /// Only the ENTRANCE uses this — on the way out every target stays exactly
    /// where it is (`leaving` pins it at 1) and only its opacity changes.
    private func spread(_ d: VoiceDirection) -> CGFloat {
        if leaving { return 1 }
        return open ? 1 : 0
    }

    /// The disc's full size, likewise held through the outro: on the way out
    /// nothing moves and nothing resizes.
    private func atFullSize(_ d: VoiceDirection) -> Bool { leaving || isShown(d) }

    /// Is this target in the view tree at all?
    ///
    /// This is what actually makes it leave. `.opacity` applied outside
    /// `.glassEffect` does NOT reach the glass material — measured: the fade
    /// interpolates at 60fps and the main thread never stalls, yet the compass
    /// stays fully opaque until the host hides the whole overlay. Taking the
    /// element OUT of the container is the framework's own way to remove glass,
    /// and it dissolves it on the current transaction's curve (see
    /// `glassEffectTransition` in `GlassSurface`).
    ///
    /// Only the exit unmounts. The entrance keeps every target mounted and grows
    /// them out of the center, which is why that animation always worked.
    private func isMounted(_ d: VoiceDirection) -> Bool { leaving ? isShown(d) : true }

    // MARK: - Transcript bubble (+ status + action hint, all inside the glass)

    private var bubble: some View {
        VStack(spacing: 5) {
            // Recording indicator — ALWAYS visible. (It used to be merged into
            // the transcript placeholder, so the moment dictation arrived it
            // vanished; and macOS's root-view rebuild made the bubble jump
            // straight to full size.) It is a fixed row: the transcript grows
            // beneath it, one line at a time, and the indicator stays put.
            HStack(spacing: 6) {
                Image(systemName: "circle.fill")
                    .resizable()
                    .frame(width: 6, height: 6)
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse, options: .repeating)
                Text("Listening").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ink.opacity(0.85))
            }
            // The transcript window: measures the FULL natural height (this
            // sits before the window, so it is not clipped), then reveals it
            // one line at a time — bottom-pinned, so the newest words stay
            // visible while older ones scroll off the top as it unfurls. No
            // row at all while empty: the bubble opens as status + hint only.
            if !controller.transcript.isEmpty {
                Text(controller.transcript)
                    .font(.system(size: 14))
                    .foregroundStyle(ink)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(width: 248, alignment: .center)
                    // Lay the text out at its FULL natural height first. Without this
                    // it gets squeezed into the window below and truncates its TAIL —
                    // you'd keep the first lines and lose the newest words, which is
                    // backwards for live dictation.
                    .fixedSize(horizontal: false, vertical: true)
                    .background(
                        GeometryReader { g in
                            Color.clear
                                .onAppear { fullTextHeight = g.size.height }
                                .onChange(of: g.size.height) { _, h in fullTextHeight = h }
                        }
                    )
                    // Then window it: grow with what has been REVEALED so far,
                    // one line at a time up to `maxTextHeight` (5 lines).
                    .frame(height: min(revealedHeight, Self.maxTextHeight),
                           alignment: .bottom)
                    .clipped()
                    .animation(.easeOut(duration: 0.12), value: revealedHeight)
            }
            // Dim, small action hint pinned inside the bubble. Always shown —
            // there is always a live target, the center included. Fixed height so
            // the bubble never resizes.
            Text(hintText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(inkMute)
                .frame(height: 14)
                .animation(.spring(response: 0.3, dampingFraction: 0.8),
                           value: controller.activeDirection)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(width: 280)
        .glassSurface(.rect(cornerRadius: 18))
        .shadow(color: .black.opacity(isDark ? 0.45 : 0.18), radius: 18, y: 6)
        .onChange(of: controller.transcript) { _, _ in startReveal() }
        .onChange(of: fullTextHeight) { _, _ in startReveal() }
        .onDisappear { revealTask?.cancel() }
    }

    /// Unfurl the transcript area one line at a time toward the transcript's
    /// full height (capped at 5 lines). Dictation's first partial is often a
    /// whole sentence — without this pacing the bubble would jump straight to
    /// full size; with it, even a big first chunk grows row by row, and steady
    /// streaming just keeps the reveal ahead of the text.
    private func startReveal() {
        let target = min(fullTextHeight, Self.maxTextHeight)
        guard !controller.transcript.isEmpty else {
            revealedHeight = 0
            return
        }
        // Shrink is instant (e.g. the streamed text replaced by "识别中…");
        // only growth is paced.
        if target <= revealedHeight {
            revealedHeight = target
            return
        }
        revealTask?.cancel()
        revealTask = Task { @MainActor in
            while revealedHeight < target {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                revealedHeight = min(revealedHeight + Self.linePitch, target)
            }
        }
    }

    // MARK: - Compass

    @ViewBuilder
    private var compass: some View {
        // Back to the plain, Apple-intended shape: ONE container, each target a
        // normal `icon -> .frame -> .glassEffect` view. What makes the grow smooth
        // is `.glassEffectID(_:in:)`: it gives each disc a stable identity in the
        // container's namespace, so the container itself drives the size change as
        // a matched-geometry morph. That's the supported way to animate glass —
        // hand-animating frames/scales (and the two-layer split that needed) was
        // fighting the framework.
        let content = ZStack {
            // No neutral-zone ring: the center orb now lights up as its own target
            // when no direction is locked, which says the same thing better.
            centerOrb
            directionButton(.up,    dx: 0,       dy: -radius)
            directionButton(.right, dx: radius,  dy: 0)
            directionButton(.down,  dx: 0,       dy: radius)
            directionButton(.left,  dx: -radius, dy: 0)
            fingerBall
        }
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer(spacing: 12) { content }
                // ONE animation for the whole compass, so the container's morph and
                // every target's frame/color interpolate on a single curve. Per-view
                // .animation calls here are what made the icon and its glass drift
                // apart mid-transition.
                .animation(.spring(response: 0.3, dampingFraction: 0.72), value: controller.activeDirection)
        } else {
            content
                .animation(.spring(response: 0.3, dampingFraction: 0.72), value: controller.activeDirection)
        }
    }

    /// The center is a TARGET too — releasing here inserts the text — so it gets
    /// the same treatment as the four around it: same grow, same bright base
    /// (the brand emerald), same white icon, morphed by the container on the
    /// shared curve. Its hot state is `direction == .none`, which also covers
    /// "just pressed, haven't moved": releasing then does insert the text, so
    /// reading as the default target is correct. Emerald is the one brand
    /// anchor — idle it tints the icon, hot it lights the disc — and the mic
    /// keeps breathing to signal live recording.
    @ViewBuilder
    private var centerOrb: some View {
        let hot = controller.activeDirection == .none
        let shown = isShown(.none)
        // Collapsed it is the seed the whole compass grows out of — a dot, sized
        // by the same frame the container already morphs between hot and idle.
        // On the way out it keeps its size and its glow, and leaves by being
        // taken out of the container (see `isMounted`).
        let full = atFullSize(.none)
        let size: CGFloat = full ? (hot ? 70 : 56) : 24
        if isMounted(.none) {
            Image(systemName: "mic.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(hot ? .white : accent)
                .symbolEffect(.pulse, options: .repeating)
                .frame(width: size, height: size)
                .glassSurface(.circle, tint: hot ? accent : nil,
                              id: "center", namespace: glassNS, leaving: leaving)
                .shadow(color: hot ? accent.opacity(0.9) : accent.opacity(0.5),
                        radius: full ? (hot ? 14 : 16) : 0)
                .opacity(shown ? 1 : 0)
        }
    }

    /// One target: the icon IS the glass surface's content (`Image -> .frame ->
    /// .glassEffect`), exactly like `centerOrb`. That is the only arrangement
    /// where the icon reliably shows: anything layered after `.glassEffect` (an
    /// overlay) or placed beside it inside the container (a sibling) gets
    /// swallowed by the glass rendering — both made the icons vanish.
    ///
    /// So the icon stays in the frame, and the mid-animation offset is fixed the
    /// other way: there is NO custom `.animation` here. The size change is driven
    /// solely by the container's matched-geometry morph (via `glassEffectID`), so
    /// glass and icon interpolate on ONE curve. The offset came from two curves
    /// running at once — my spring on the frame vs. the container's morph.
    @ViewBuilder
    private func directionButton(_ d: VoiceDirection, dx: CGFloat, dy: CGFloat) -> some View {
        let hot = d == controller.activeDirection
        let c = color(for: d)
        let shown = isShown(d)
        let full = atFullSize(d)
        let f = spread(d)
        // Entering, the disc grows from a dot at the middle while it travels out
        // to its arm. Leaving, it does neither — it sits where it is, at full
        // size, and dissolves out of the container.
        let size: CGFloat = full ? (hot ? 74 : 60) : 26
        if isMounted(d) {
            Image(systemName: symbol(for: d))
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(hot ? .white : inkDim)
                .frame(width: size, height: size)
                .glassSurface(.circle, tint: hot ? c : nil,
                              id: d.rawValue, namespace: glassNS, leaving: leaving)
                .shadow(color: hot && full ? c.opacity(0.9) : .clear, radius: hot ? 14 : 0)
                .opacity(shown ? 1 : 0)
                .offset(x: dx * f, y: dy * f)
        }
    }

    /// Clear-glass marble that rides the ACTIVE AXIS out from the center mic —
    /// the same dominant-axis classification the controller publishes, so it and
    /// the highlighted target always agree. Only the drag's component on that
    /// axis survives (`axisComponent`): a diagonal drag rides the dominant axis
    /// instead of leaving the cross. Small (39pt — user shrank it 50% from 78)
    /// so it reads as a cursor, not a finger. 1:1 instant (NO animation — a
    /// spring lags and "sticks" on direction change), clamped so a far swipe
    /// can't push it off the overlay. Pure glass — no ring, no shadow — so it's
    /// one surface, never glass + a drifting outline. Fades in once the drag
    /// leaves center; at `.none` the component is 0, so it stays fused on the
    /// mic.
    ///
    /// It is the FIRST thing to go on release, ahead of even the bubble: it is a
    /// proxy for a finger that is no longer there. (It also has to actually
    /// leave the tree — being glass, opacity does not hide it — or it is left
    /// alone on screen after everything else has dissolved, and then jumps back
    /// to the center when `activeDirection` resets and its axis projection goes
    /// to zero.)
    @ViewBuilder
    private var fingerBall: some View {
        let s = axisComponent(controller.fingerOffset)
        let mag = abs(s)
        // Travel cap: the four targets sit at radius 80 with a ~33pt half-width,
        // so 120 puts the marble's center just past their outer edge — it pokes
        // past the ring a little and no further.
        let maxR: CGFloat = 120
        let travel = mag > maxR ? s * (maxR / mag) : s
        if ballShown {
            Circle()
                .fill(Color.clear)
                .frame(width: 39, height: 39)
                // A touch of ink tint so the marble is legible on light glass too,
                // where clear-on-clear all but disappears.
                .glassSurface(.circle, tint: isDark ? nil : ink.opacity(0.10))
                .offset(x: horizontal ? travel : 0, y: vertical ? travel : 0)
                .opacity(open ? min(1, mag / 26) : 0)
        }
    }

    /// The axis directions, so the ball only ever travels on one line.
    private var horizontal: Bool { controller.activeDirection == .left || controller.activeDirection == .right }
    private var vertical: Bool { controller.activeDirection == .up || controller.activeDirection == .down }

    /// Signed distance of the drag along the active axis (y-down points), 0
    /// while centered/unclassified. This projection is what locks the marble
    /// onto the cross — the off-axis component is discarded.
    private func axisComponent(_ t: CGSize) -> CGFloat {
        switch controller.activeDirection {
        case .up, .down:    return t.height
        case .left, .right: return t.width
        case .none:         return 0
        }
    }

    private var hintText: String {
        switch controller.activeDirection {
        case .up:    return "Release to send"
        case .right: return "Release to correct"
        case .down:  return "Release to cancel"
        case .left:  return "Release to convert"
        case .none:  return "Release to input"
        }
    }

    private func symbol(for d: VoiceDirection) -> String {
        switch d {
        case .up:    return "paperplane.fill"
        case .right: return "wand.and.stars"
        case .down:  return "xmark"
        case .left:  return "chevron.left.forwardslash.chevron.right"
        case .none:  return ""
        }
    }
}

// MARK: - Liquid glass surface (iOS 26 / macOS 26), flat fallback below

private struct GlassSurface: ViewModifier {
    enum Shape { case circle, rect(cornerRadius: CGFloat) }
    let shape: Shape
    var tint: Color?           // nil = plain (untinted) glass / neutral fill
    /// Optional stable identity within a `GlassEffectContainer`. Supplying it lets
    /// the container morph this surface (matched geometry) when its size changes,
    /// instead of the size snapping or having to be hand-animated.
    var id: String?
    var namespace: Namespace.ID?
    /// The compass is exiting: this surface is about to be taken out of the
    /// container, and the transition that governs its REMOVAL has to be a
    /// dissolve, not a geometry morph — `.matchedGeometry` would have it morph
    /// into whichever sibling is still mounted on its way out.
    var leaving = false

    /// The pre-26 fallback paints real fills, so it needs the appearance too —
    /// its old black/white constants were invisible in light mode.
    @ObservedObject private var themeStore = ThemeStore.shared
    private var isDark: Bool { themeStore.effectiveIsDark }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            let glass: Glass = tint.map { Glass.regular.tint($0).interactive() }
                ?? Glass.regular.interactive()
            let shaped = Group {
                switch shape {
                case .circle:      content.glassEffect(glass, in: .circle)
                case .rect(let r): content.glassEffect(glass, in: .rect(cornerRadius: r))
                }
            }
            if let id, let namespace {
                shaped
                    .glassEffectID(id, in: namespace)
                    .glassEffectTransition(leaving ? .materialize : .matchedGeometry)
            } else {
                shaped
            }
        } else {
            let base = isDark ? Color.black.opacity(0.55) : Color.white.opacity(0.75)
            let edge = (isDark ? Color.white : Color.black).opacity(tint == nil ? 0.10 : 0.22)
            switch shape {
            case .circle:
                content
                    .background(Circle().fill(tint ?? base))
                    .overlay(Circle().strokeBorder(edge))
            case .rect(let r):
                content
                    .background(.ultraThinMaterial,
                                in: RoundedRectangle(cornerRadius: r, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: r, style: .continuous)
                        .strokeBorder(edge.opacity(0.6)))
            }
        }
    }
}

private extension View {
    func glassSurface(_ shape: GlassSurface.Shape, tint: Color? = nil,
                      id: String? = nil, namespace: Namespace.ID? = nil,
                      leaving: Bool = false) -> some View {
        modifier(GlassSurface(shape: shape, tint: tint, id: id,
                              namespace: namespace, leaving: leaving))
    }
}
