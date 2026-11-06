import SwiftUI
import BentoTmuxKit
import Combine
import BentoVoiceKit
import BentoAgentKit
import BentoSessionKit
import BentoFilePreviewKit
import BentoFoundationKit
import BentoGhosttyKit
import BentoUISharedKit

// MARK: - Window Tab Bar (List mode, compact width)

/// Bottom tab strip for List mode on phones: one tab per tmux window,
/// browser-tab style, horizontally scrollable, with a trailing "+" that offers
/// the two creation seeds. Each tab shows the window's LIVE display name
/// (derived from what's running — never renamed), its aggregate agent-state
/// dot (`windowStatus`), and a pane-count badge when the window holds several
/// panes (external structures). Tapping a tab is select-window ONLY — zero
/// zoom, zero resize — the terminal above simply starts mirroring that window.
/// Long-press a tab → Close Window (confirmed: processes die).
///
/// State dots refresh on every state poll without an explicit `.id`: the
/// @ObservedObject view model bumps `stateVersion` (@Published) each cycle,
/// which re-runs this body and re-derives `windowStatus`. (`.id(stateVersion)`
/// on the scroll content would also reset the user's horizontal scroll
/// position every poll, so it's deliberately not used here.)
///
/// Drag a tab onto another to rearrange the session (`reorderWindow`): the
/// system drag interaction, so the phone's usual long-press-then-move applies
/// and holding still keeps opening the context menu instead — a hand-rolled
/// long-press gesture would have to fight that menu for the same touch.
struct WindowTabBar: View {
    @ObservedObject var viewModel: TerminalViewModel
    /// Handed to the "New Window" sheet so its working directory can be
    /// browsed; nil = typed-path only.
    var pathContextProvider: (() -> PathPreviewContext?)? = nil
    @StateObject private var actions = WindowActionsState()
    /// The tab a dragged tab is currently hovering over — it lifts to show the
    /// slot the drop would take.
    @State private var dropTarget: TmuxWindowID?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(viewModel.windows) { window in
                        // Body name only — the chips are small, the "N:" index
                        // prefix adds noise here (the sidebar keeps it).
                        WindowTab(name: viewModel.windowBodyName(window.id),
                                  status: viewModel.windowStatus(window.id).chrome,
                                  paneCount: viewModel.panes(in: window.id).count,
                                  isActive: window.id == viewModel.activeWindowID)
                            .id(window.id)
                            .scaleEffect(dropTarget == window.id ? 1.08 : 1)
                            .animation(.easeOut(duration: 0.15), value: dropTarget)
                            .onTapGesture { viewModel.selectWindow(window.id) }
                            .draggable(window.id.description) {
                                // Drag preview: the same chip, drawn inactive so
                                // it reads as a thing in transit rather than as
                                // a second "current window".
                                WindowTab(name: viewModel.windowBodyName(window.id),
                                          status: viewModel.windowStatus(window.id).chrome,
                                          paneCount: viewModel.panes(in: window.id).count,
                                          isActive: false)
                            }
                            .dropDestination(for: String.self) { items, _ in
                                drop(items, onto: window.id)
                            } isTargeted: { targeted in
                                if targeted { dropTarget = window.id }
                                else if dropTarget == window.id { dropTarget = nil }
                            }
                            .contextMenu {
                                WindowContextMenu(viewModel: viewModel, state: actions,
                                                  window: window.id, axis: .horizontal)
                            }
                    }
                    newWindowButton
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: viewModel.activeWindowID) { _, newID in
                // Keep the current tab in view (a switch can come from any
                // attached device, not just a tap here).
                guard let newID else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newID, anchor: .center)
                }
            }
        }
        .background(
            // Transparent: the terminal background (paneBgColor behind) flows
            // through the bar (and under the home indicator — the backdrop
            // already fills it), so the floor fuses with the terminal instead
            // of wearing a hardcoded hex. The chips wear their own glass
            // (BarItemGlass); the bar itself stays bare.
            Color.clear
        )
        .windowActionDialogs(viewModel: viewModel, state: actions, close: .alert,
                             pathContextProvider: pathContextProvider)
    }

    /// Landing a dragged tab on `target` gives it that tab's position — drop
    /// where you want it to end up.
    ///
    /// The payload is the window ID's own text (`@7`) rather than a custom
    /// transfer type, which would mean a UTType declared in the Info.plist and
    /// kept in sync for a two-character string. Foreign text dropped in from
    /// another app therefore reaches here too, and is refused by the same check
    /// that guards a stale ID: it has to name a window this session still has.
    private func drop(_ items: [String], onto target: TmuxWindowID) -> Bool {
        dropTarget = nil
        guard let dragged = items.first.flatMap({ TmuxWindowID(string: $0) }),
              dragged != target,
              viewModel.windows.contains(where: { $0.id == dragged }),
              let destination = position(of: target) else { return false }
        Task { await viewModel.reorderWindow(dragged, toIndex: destination) }
        return true
    }

    private func position(of id: TmuxWindowID) -> Int? {
        viewModel.windows.firstIndex { $0.id == id }
    }

    /// The two creation seeds — same pair as the iPad/macOS sidebar.
    private var newWindowButton: some View {
        NewWindowSeedMenu(viewModel: viewModel,
                          onPathAndCommand: { actions.showsNewWindowForm = true }) {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.bentoInkDim)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .modifier(BarItemGlass(isActive: false))
                .contentShape(Capsule())
        }
    }
}

/// Liquid-glass capsule for the window tab bar's chips — each tab and the
/// "+" button. The bar itself stays transparent so the terminal flows through
/// it; only the items wear glass. iOS 26: the chip's glass is tinted by its
/// window's status (`PaneChrome.Status.accentHex` — working blue, awaiting
/// amber, done green, idle plain); the active chip wears the full color, inactive chips a weakened
/// version of the same, so the bar shows every window's state at a glance
/// while the active tab stays the strongest. Earlier systems: the flat bento
/// chip with the emerald ring. The chip's content (dot, label, badge) is
/// INSIDE the glassEffect — anything layered after glass gets swallowed by
/// the material.
private struct BarItemGlass: ViewModifier {
    var isActive: Bool
    var status: PaneChrome.Status = .idle

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            let glass = tint.map { Glass.regular.tint($0).interactive() }
                ?? Glass.regular.interactive()
            content.glassEffect(glass, in: .capsule)
        } else {
            content
                .background(Capsule().fill(isActive ? Color.bentoSurfaceHi : Color.bentoSurface))
                .overlay(
                    Capsule().strokeBorder(isActive ? Color.bentoEmerald : Color.bentoBorder,
                                           lineWidth: isActive ? 1.5 : 1)
                )
        }
    }

    /// Status accent for the glass, from the canonical palette (working blue /
    /// awaiting amber / done green) — full strength when active, half when
    /// not, so the status reads on every chip and the active one is the
    /// loudest. Idle has no accent: the active chip wears the theme accent
    /// (emerald) so a resting window's selected tab still stands out; inactive
    /// idle chips wear plain glass.
    private var tint: Color? {
        if let hex = status.accentHex {
            let base = Color(hex: hex)
            return isActive ? base : base.opacity(0.5)
        }
        return isActive ? Color.bentoEmerald : nil
    }
}

private struct WindowTab: View {
    var name: String
    var status: PaneChrome.Status
    var paneCount: Int
    var isActive: Bool

    var body: some View {
        HStack(spacing: 6) {
            // Status icon — the sidebar rows' and pane titles' glyph language
            // (`PaneChrome.Status`): play = working, question = awaiting,
            // check = done while you were elsewhere, hollow ring = idle.
            // Active: white, matching the text (the tinted chip owns the color
            // then); inactive: the status color.
            Image(systemName: status.symbol)
                .font(.system(size: 12))
                .foregroundStyle(isActive ? Color.white : Color(hex: status.glyphHex))

            Text(name.isEmpty ? "window" : name)
                .font(.system(.footnote, design: .monospaced))
                // One active rule for every state: the chip is colored (state
                // tint, or the theme accent when idle) and the text is white
                // against it (same rule as the voice compass's lit discs).
                // Inactive chips sit on plain/weakened glass, dim ink reads.
                .foregroundStyle(isActive ? Color.white : Color.bentoInkDim)
                .lineLimit(1)
                .frame(maxWidth: 140)

            if paneCount > 1 {
                Text("\(paneCount)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.bentoInkDim)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.bentoShell))
                    .overlay(Capsule().strokeBorder(Color.bentoBorder, lineWidth: 1))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        // Glass chip on iOS 26, tinted by the window's state — active wears
        // the full color, inactive a weakened version of the same. Flat bento
        // chip with the emerald ring on earlier systems (deployment target 17).
        .modifier(BarItemGlass(isActive: isActive, status: status))
        .contentShape(Capsule())
    }
}
