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

// MARK: - Pane Title Bar

/// Minimal title bar sitting atop the terminal. Just a state dot + title — the
/// zoom + pane-menu actions moved to the floating toolbar (the strip is one
/// cell tall in tiled mode, too short for touch targets). Two looks:
///   • Tiled (multi-pane): chrome mirrors the macOS host — a dark-green band
///     with bright-green text when active, dark-gray with muted text otherwise.
///   • Single / focus: blends into the terminal background (no contrast band),
///     so a fullscreen pane reads as one continuous surface.
///
/// Layout: [◉ state] [title……………………………………………] [mode]
final class PaneTitleBar: UIView {
    let titleLabel = UILabel()
    /// Leading semantic state glyph — the SAME symbol language as the macOS
    /// pane chrome and the window sidebar rows, not a bare dot. A dot carries
    /// only a color, which is why it had no way to say "done, unseen".
    private let stateIcon = UIImageView()
    /// Trailing mode glyph. Separate from the state dot on purpose: state is what
    /// the PROGRAM is doing, a mode is something about the pane that changes how
    /// it answers you. Hidden unless a mode is on — "nothing unusual" gets no
    /// marker, the same rule the idle state follows.
    private let modeIcon = UIImageView()

    /// A non-default mode this pane is sitting in — see `PaneChrome.ModeBadge`,
    /// the same vocabulary the macOS title bar uses.
    var modeBadge: PaneChrome.ModeBadge = .none {
        didSet {
            guard oldValue != modeBadge else { return }
            updateModeBadge()
            updateChrome()
        }
    }

    private func updateModeBadge() {
        guard let symbol = modeBadge.symbol else {
            modeIcon.isHidden = true
            return
        }
        modeIcon.image = UIImage(systemName: symbol)
        modeIcon.accessibilityLabel = modeBadge.help
        modeIcon.isHidden = false
    }

    /// Drives the state glyph, the title-bar band color, and (when active) text
    /// emphasis.
    var paneState: PaneState = .idle {
        didSet { updateStateVisuals(); updateChrome() }
    }

    /// An agent that finished while you were looking elsewhere → the green ✓, a
    /// display state that sits beside `paneState` rather than inside it (the
    /// same split the macOS chrome and the sidebar rows make).
    var agentFinishedUnseen: Bool = false {
        didSet {
            guard oldValue != agentFinishedUnseen else { return }
            updateStateVisuals(); updateChrome()
        }
    }

    /// Active state drives the green chrome (tiled) / text emphasis (blend).
    var isActivePane: Bool = false {
        didSet { updateChrome() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        // In tiled mode the strip is only one character cell tall; clip so the
        // centered dot never spills onto the terminal surface below.
        clipsToBounds = true

        stateIcon.contentMode = .scaleAspectFit
        stateIcon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stateIcon)

        titleLabel.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .secondaryLabel
        titleLabel.text = "shell"
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        modeIcon.contentMode = .scaleAspectFit
        modeIcon.isHidden = true
        modeIcon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(modeIcon)

        NSLayoutConstraint.activate([
            // A fixed-width slot, so the title never shifts as the state changes.
            stateIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stateIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            stateIcon.widthAnchor.constraint(equalToConstant: 14),
            stateIcon.heightAnchor.constraint(equalToConstant: 14),

            titleLabel.leadingAnchor.constraint(equalTo: stateIcon.trailingAnchor, constant: 7),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: modeIcon.leadingAnchor, constant: -6),

            modeIcon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            modeIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            modeIcon.widthAnchor.constraint(equalToConstant: 12),
            modeIcon.heightAnchor.constraint(equalToConstant: 12),
        ])

        updateStateVisuals()
        updateChrome()
    }

    /// The title band and its ink, from the shared `PaneChromeColors` — the same
    /// strip the macOS chrome draws (2026-08-07: the Mac treatment is the one
    /// treatment). The band's darkness follows the app appearance, tinted by the
    /// state accent and strengthened on the focused pane; it no longer derives
    /// from the terminal's reported background, so a TUI repainting its bg
    /// leaves the chrome alone.
    private func updateChrome() {
        // Done-unseen wins the band, otherwise the per-state color (nil for
        // idle → neutral band) — the shared chrome precedence.
        let accent: UIColor? = status.accentHex.map { UIColor(hex: $0) }
        backgroundColor = PaneChromeColors.titleBand(accent: accent, active: isActivePane)
        titleLabel.textColor = PaneChromeColors.ink(accent: accent, active: isActivePane)
        // Same ink as the title: a mode is information, not an alarm, and it must
        // never be mistaken for one of the state colors.
        modeIcon.tintColor = titleLabel.textColor
    }

    /// Re-derive the band/ink for the current appearance (the band colors are
    /// resolved at compute time, not trait-reactive UIColors).
    func recolor() { updateChrome() }

    /// What this pane's chrome is announcing — the shared mapping the macOS
    /// title bar and the window sidebar rows also render.
    private var status: PaneChrome.Status {
        PaneChrome.Status(state: paneState, agentFinishedUnseen: agentFinishedUnseen)
    }

    /// The leading glyph for the current state.
    private func updateStateVisuals() {
        let color = UIColor(hex: status.glyphHex)
        stateIcon.image = UIImage(systemName: status.symbol, withConfiguration:
            UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        stateIcon.tintColor = color

        // A pending question / running program gets a soft glow so it reads from
        // across the room; a settled pane doesn't.
        switch paneState {
        case .awaitingInput:
            stateIcon.layer.shadowColor = color.cgColor
            stateIcon.layer.shadowRadius = 3
            stateIcon.layer.shadowOpacity = 0.8
            stateIcon.layer.shadowOffset = .zero
        case .working:
            stateIcon.layer.shadowColor = color.cgColor
            stateIcon.layer.shadowRadius = 2.5
            stateIcon.layer.shadowOpacity = 0.6
            stateIcon.layer.shadowOffset = .zero
        case .idle:
            stateIcon.layer.shadowOpacity = 0
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
