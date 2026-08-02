import Foundation
import BentoFoundationKit

/// Authoritative cell grid reported by the rendering engine. This is what must
/// drive the tmux client / PTY size — never homemade cell math, or TUI wrapping
/// will drift from what is actually rendered.
public struct TerminalSurfaceSize: Equatable, Sendable {
    public let columns: Int
    public let rows: Int
    public let cellWidthPx: Int
    public let cellHeightPx: Int

    public init(columns: Int, rows: Int, cellWidthPx: Int, cellHeightPx: Int) {
        self.columns = columns
        self.rows = rows
        self.cellWidthPx = cellWidthPx
        self.cellHeightPx = cellHeightPx
    }
}

/// Engine-agnostic terminal appearance. Colors are 24-bit `0xRRGGBB`, matching
/// Bento's existing `TerminalColorTheme` so the app can pass values straight
/// through without converting to any engine's color type.
public struct TerminalTheme: Equatable, Sendable {
    public var background: UInt32
    public var foreground: UInt32
    public var ansi: [UInt32]      // 16 entries: 0-7 normal, 8-15 bright
    public var fontSize: Double
    public var fontFamily: String?
    /// Whether this palette reads as dark. Not decoration: the surface reports it
    /// to the engine (`ghostty_surface_set_color_scheme`) so programs INSIDE the
    /// terminal can query light/dark (OSC 2031 subscriptions, DSR ?996). Without
    /// it the app's appearance switch stops at the chrome and vim/delta/bat keep
    /// picking a theme for the wrong background.
    public var isDark: Bool

    public init(
        background: UInt32,
        foreground: UInt32,
        ansi: [UInt32],
        fontSize: Double,
        fontFamily: String? = nil,
        isDark: Bool = true
    ) {
        self.background = background
        self.foreground = foreground
        self.ansi = ansi
        self.fontSize = fontSize
        self.fontFamily = fontFamily
        self.isDark = isDark
    }
}

/// The thin contract between Bento's pane/session orchestration and a concrete
/// terminal renderer. A SwiftTerm-backed and a libghostty-backed view both
/// satisfy this, so the engine is a swappable leaf. The implementing type is a
/// `UIView` (iOS) or `NSView` (macOS); host code adds it to the view hierarchy
/// and wires the callbacks below.
@MainActor
public protocol TerminalSurface: AnyObject {
    /// Feed terminal output bytes (from an SSH channel or a local pty) into the
    /// surface.
    ///
    /// `nonisolated` because output must not have to wait for the main thread:
    /// every keystroke blocks main for ~19ms inside the input method's
    /// synchronous IPC, and an echo queued behind that is an echo the user
    /// watches arrive late. Implementations hand off to their own queue.
    nonisolated func feed(_ data: Data)

    /// Called when the surface has bytes to send back to the host (keystrokes,
    /// query responses). Host forwards these to the transport.
    var onInput: ((Data) -> Void)? { get set }

    /// Called when the rendered cell grid changes (layout, rotation, font).
    /// Carries the authoritative size that must drive the PTY/tmux resize.
    var onSizeChanged: ((TerminalSurfaceSize) -> Void)? { get set }

    /// Called on OSC 0/1/2 terminal title changes.
    /// Never fired by the current implementation — titles flow via tmux.
    var onTitleChanged: ((String) -> Void)? { get set }

    /// Apply colors and font.
    func applyTheme(_ theme: TerminalTheme)

    /// Latest known authoritative size, if the surface has laid out.
    var currentSize: TerminalSurfaceSize? { get }

    /// Engine focus (affects cursor blink / reporting).
    func setFocus(_ focused: Bool)

    /// Show client-side predicted keystrokes (Mosh-style local echo) as the
    /// engine's preedit overlay; "" clears. Suppressed while a real IME
    /// composition owns that slot. Optional — a renderer that can't overlay
    /// simply doesn't predict.
    func setPredictedText(_ text: String)
}

public extension TerminalSurface {
    func setPredictedText(_ text: String) {}
}

extension ThemeStore {
    /// Build the engine-agnostic TerminalTheme (colors + font) for a surface.
    /// Lives here (not in BentoFoundationKit) because TerminalTheme is a
    /// TerminalSurface type.
    public func makeTerminalTheme() -> TerminalTheme {
        TerminalTheme(background: current.bg, foreground: current.fg,
                      ansi: current.ansi, fontSize: fontSize, fontFamily: ghosttyFontFamily,
                      isDark: current.isDark)
    }
}
