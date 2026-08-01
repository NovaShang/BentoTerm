import SwiftUI
import BentoFoundationKit

/// The voice overlay's visual layer, shared by iOS + macOS: a glowing glass mic
/// orb + faint neutral-zone ring at center, four glass direction buttons that
/// highlight + grow on the active direction, and a glass "finger ball" that
/// tracks the drag 1:1. The transcript bubble also holds the status row and a
/// dim one-line action hint ("Release to …") inside it. Pure SwiftUI — no
/// UIKit/AppKit — so it renders identically wherever it's hosted.
///
/// Liquid Glass on iOS 26 / macOS 26: the targets + finger ball are grouped in
/// one `GlassEffectContainer` — that fusion IS the point, the material blends
/// and the elements share the proximity response (the "soul"). Each is an
/// `.interactive()` glass surface. Highlight = a FAINT BRIGHT BASE (low-opacity
/// white glass tint) + a brighter icon + the GLASS DISC GROWING 60->74, morphed
/// by the container through `.glassEffectID(_:in:)` + `.glassEffectTransition(
/// .matchedGeometry)` — the supported way to animate glass; hand-animating the
/// frame/scale fought the framework — never a saturated theme fill. Emerald lives only
/// on the center mic orb. The finger ball is a pure clear-glass marble (no ring,
/// no shadow). Below 26 -> flat bento surfaces.
///
/// `fingerOffset` is the drag delta from the press origin (y-down point space;
/// both hosts flip macOS's y-up before passing). The ball tracks it with NO
/// animation — a finger proxy must be 1:1; a spring here lags, freezes on
/// direction change, then snaps. It fades in as the finger leaves center and is
/// clamped so a far drag can't push it off the overlay.
public struct VoiceCompassView: View {
    /// Overlay footprint, and how far its content reaches from the center anchor.
    /// Hosts need these to keep the compass clear of screen edges — the compass is
    /// centered on the touch point, so nothing inside it can enforce that.
    public enum Metrics {
        public static let size = CGSize(width: 360, height: 580)
        /// Half-width: the side targets sit within this of the anchor.
        public static let halfWidth: CGFloat = size.width / 2
        /// Top of the tallest bubble, above the anchor.
        public static let reachUp: CGFloat = 270
        /// Bottom of the down target (plus its glow), below the anchor.
        public static let reachDown: CGFloat = 120
    }

    public let transcript: String
    public let direction: VoiceDirection
    public let fingerOffset: CGSize

    public init(transcript: String, direction: VoiceDirection, fingerOffset: CGSize = .zero) {
        self.transcript = transcript
        self.direction = direction
        self.fingerOffset = fingerOffset
    }

    private let accent = Color(red: 0.30, green: 0.90, blue: 0.62)
    private let radius: CGFloat = 80

    /// Ceiling for the transcript area (~5 lines at 14pt + 3pt spacing). The bubble
    /// grows with what you say up to here, then windows to the newest lines.
    private static let maxTextHeight: CGFloat = 92
    /// Slot the bubble is bottom-pinned in: enough for `maxTextHeight` plus the
    /// status row, hint row and padding, so growth never gets clipped.
    private static let bubbleSlot: CGFloat = maxTextHeight + 76

    /// Identity space the GlassEffectContainer uses to morph each target's glass
    /// between its idle and active size (see `glassEffectID`).
    @Namespace private var glassNS

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
    /// Activation base + glow. White brightens dark glass; on light glass it
    /// washes out, so tint/glow with the ink color instead.
    private var hotTint: Color { isDark ? Color.white.opacity(0.28) : ink.opacity(0.16) }
    private var hotGlow: Color { isDark ? Color.white.opacity(0.45) : ink.opacity(0.25) }

    public var body: some View {
        ZStack {
            // Pin the bubble by its BOTTOM edge so a taller transcript grows
            // upward, away from the compass, instead of creeping down over it.
            bubble
                .frame(height: Self.bubbleSlot, alignment: .bottom)
                .offset(y: -(radius + 106))
            compass
        }
        // Fixed size so the compass center sits at the host's anchor point
        // (NSView center on macOS, `.position` on iOS). Both place by center, so
        // the height only needs to fit the bubble above without clipping — it
        // does not shift the anchor.
        .frame(width: Metrics.size.width, height: Metrics.size.height)
    }

    // MARK: - Transcript bubble (+ status + action hint, all inside the glass)

    private var bubble: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "circle.fill")
                    .resizable()
                    .frame(width: 6, height: 6)
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse, options: .repeating)
                Text("Listening").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ink.opacity(0.85))
            }
            // Grows with the transcript up to a ceiling, then windows to the
            // newest lines (see the two modifiers below).
            Text(transcript.isEmpty ? "Listening…" : transcript)
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
                // Then window it: the area grows with the text up to `maxTextHeight`
                // (~5 lines), and once it overflows, bottom alignment + clipping keep
                // the NEWEST lines visible while older ones scroll off the top.
                .frame(maxHeight: Self.maxTextHeight, alignment: .bottom)
                .clipped()
            // Dim, small action hint pinned inside the bubble. Always shown —
            // there is always a live target, the center included. Fixed height so
            // the bubble never resizes.
            Text(hintText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(inkMute)
                .frame(height: 14)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: direction)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(width: 280)
        .glassSurface(.rect(cornerRadius: 18))
        .shadow(color: .black.opacity(isDark ? 0.45 : 0.18), radius: 18, y: 6)
        // Ease the growth so adding a line slides rather than jumps.
        .animation(.easeOut(duration: 0.18), value: transcript)
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
                .animation(.spring(response: 0.3, dampingFraction: 0.72), value: direction)
        } else {
            content
                .animation(.spring(response: 0.3, dampingFraction: 0.72), value: direction)
        }
    }

    /// The center is a TARGET too — releasing here inserts the text — so it gets
    /// the same treatment as the four around it: same grow, same faint-bright
    /// base, same white icon, morphed by the container on the shared curve.
    /// Its hot state is `direction == .none`, which also covers "just pressed,
    /// haven't moved": releasing then does insert the text, so reading as the
    /// default target is correct. Emerald stays as the idle tint — the one brand
    /// anchor — and the mic keeps breathing to signal live recording.
    private var centerOrb: some View {
        let hot = direction == .none
        return Image(systemName: "mic.fill")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(hot ? ink : accent)
            .symbolEffect(.pulse, options: .repeating)
            .frame(width: hot ? 70 : 56, height: hot ? 70 : 56)
            .glassSurface(.circle, tint: hot ? hotTint : nil,
                          id: "center", namespace: glassNS)
            .shadow(color: hot ? hotGlow : accent.opacity(0.5),
                    radius: hot ? 14 : 16)
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
    private func directionButton(_ d: VoiceDirection, dx: CGFloat, dy: CGFloat) -> some View {
        let hot = d == direction
        return Image(systemName: symbol(for: d))
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(hot ? ink : inkDim)
            .frame(width: hot ? 74 : 60, height: hot ? 74 : 60)
            .glassSurface(.circle, tint: hot ? hotTint : nil,
                          id: d.rawValue, namespace: glassNS)
            .shadow(color: hot ? hotGlow : .clear, radius: hot ? 14 : 0)
            .offset(x: dx, y: dy)
    }

    /// Clear-glass marble that tracks the drag 1:1 (NO animation — a spring lags
    /// and "sticks" on direction change). Bigger than the targets so it reads as
    /// the finger itself. Pure glass — no ring, no shadow — so it's one surface,
    /// never glass + a drifting outline. Fades in once the finger leaves center
    /// and is clamped so a far swipe can't push it off the overlay.
    @ViewBuilder
    private var fingerBall: some View {
        let mag = hypot(fingerOffset.width, fingerOffset.height)
        let maxR: CGFloat = 150
        let k = mag > maxR ? maxR / mag : 1
        Circle()
            .fill(Color.clear)
            .frame(width: 78, height: 78)
            // A touch of ink tint so the marble is legible on light glass too,
            // where clear-on-clear all but disappears.
            .glassSurface(.circle, tint: isDark ? nil : ink.opacity(0.10))
            .offset(x: fingerOffset.width * k, y: fingerOffset.height * k)
            .opacity(min(1, mag / 26))
    }

    private var hintText: String {
        switch direction {
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
                    .glassEffectTransition(.matchedGeometry)
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
                      id: String? = nil, namespace: Namespace.ID? = nil) -> some View {
        modifier(GlassSurface(shape: shape, tint: tint, id: id, namespace: namespace))
    }
}
