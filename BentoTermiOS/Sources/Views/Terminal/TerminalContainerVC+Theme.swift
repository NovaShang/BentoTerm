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

// MARK: - Theme & appearance

extension TerminalContainerVC {
    func observeAppearanceChanges() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange),
            name: .terminalThemeChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(fontDidChange),
            name: .terminalFontChanged, object: nil)
        // Self-heal for the post-unlock resume race: if this pane was rebuilt
        // while the font-size default transiently read empty (see
        // ThemeStore.fontSize), the surface came up at the fallback size.
        // Re-applying on foreground re-reads the (now readable) value; the
        // surface only recreates when the size actually differs.
        NotificationCenter.default.addObserver(
            self, selector: #selector(fontDidChange),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        // The engine reported the background it's ACTUALLY rendering (initial
        // resolution, config reload, or a runtime OSC 11) — the only honest
        // source for chrome that must fuse with the terminal. Mirrors the macOS
        // window host's surfaceBackgroundChanged subscription.
        NotificationCenter.default.addObserver(
            self, selector: #selector(surfaceBackgroundChanged),
            name: .ghosttySurfaceBackgroundChanged, object: nil)
    }

    @objc private func themeDidChange() {
        reportedBgColor = nil   // surfaces re-report after the config reload
        applyTheme(); titleBar.recolor(); applyPaneBorder(active: paneIsActive)
    }
    @objc private func fontDidChange() { applyTheme() }

    /// Build the engine-agnostic theme from the current ThemeStore selection.
    func currentTerminalTheme() -> TerminalTheme {
        let t = ThemeStore.shared.current
        let fontSize = Double(STTheme.terminalFontSize)
        // Trace the size EVERY build: the user-reported "font grows after
        // app-switch resume" was two fallbacks disagreeing (this path created
        // surfaces at 10, the engine's config reload pushed 12/14 to the live
        // ones); both now resolve through ThemeStore. This line plus
        // [surface] created… in debug.log pins any recurrence.
        dlog("[theme] terminal theme fontSize=\(fontSize) (stored=\(UserDefaults.standard.double(forKey: "terminal_font_size")))")
        return TerminalTheme(
            background: t.bg,
            foreground: t.fg,
            ansi: t.ansi,
            fontSize: fontSize
        )
    }

    private func resolvedTerminalBackground() -> UIColor {
        reportedBgColor ?? ThemeStore.shared.current.bgColor
    }

    /// Push the current terminal bg + pane state onto the container surround,
    /// the surface, and the state wash. Animated on state change, instant on bg
    /// reports / theme reapplies. (The title band is NOT derived from the
    /// terminal bg — it's the shared chrome; see `PaneTitleBar.updateChrome`.)
    func applyBackgrounds(animated: Bool) {
        let bgColor = resolvedTerminalBackground()
        let status = PaneChrome.Status(state: titleBar.paneState,
                                       agentFinishedUnseen: titleBar.agentFinishedUnseen)
        // The surround is the terminal bg FUSED with the same wash the surface
        // wears, so the band and an empty washed terminal read as one color.
        let surround = PaneChromeColors.washed(bgColor, status: status)
        let tint = PaneChromeColors.wash(status) ?? .clear
        let apply = {
            self.view.backgroundColor = surround
            self.surface.backgroundColor = bgColor
            self.stateTint.backgroundColor = tint
        }
        if animated { UIView.animate(withDuration: 0.26, animations: apply) } else { apply() }
    }

    /// The engine reported a new bg (or the theme/appearance re-applied) —
    /// re-derive everything from the current pane state, without animating.
    private func applyTerminalBackground() {
        applyBackgrounds(animated: false)
    }

    @objc private func surfaceBackgroundChanged(_ note: Notification) {
        guard let s = note.object as? GhosttyTerminalSurface,
              s === surface,
              let color = s.reportedBackgroundColor else { return }
        reportedBgColor = color
        applyTerminalBackground()
    }

    /// Apply the user-selected color theme.
    func applyTheme() {
        surface.applyTheme(currentTerminalTheme())
        // The surface re-reports its bg once the new config renders; until then
        // `resolvedTerminalBackground` falls back to the theme bg.
        applyTerminalBackground()
    }
}
