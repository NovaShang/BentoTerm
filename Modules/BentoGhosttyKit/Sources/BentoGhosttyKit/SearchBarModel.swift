import Foundation

/// Shared find-in-scrollback state for the two native search bars — the Mac's
/// `PaneSearchBar` and iOS's `PaneFindBar`. The engine (`GhosttySel` /
/// `GhosttyTerminalSurface`) owns the actual search; this owns the UI-side
/// plumbing both bars used to duplicate: the 120 ms keystroke debounce, the
/// count-string formatting ("0/0", "3/17", "–/17"), and the callback fan-out.
///
/// Both bars are native views embedded in surface hierarchies (not SwiftUI
/// hosts), so the model talks to them through plain closures: `onCountsChanged`
/// fires whenever the displayed count string changes (nil = clear the label).
@MainActor
public final class SearchBarModel {
    /// Typing must not fire a search per keystroke — each one walks the whole
    /// scrollback in the engine. Short enough to still feel live.
    public static let debounceMs = 120

    public var onQueryChanged: ((String) -> Void)?
    public var onNext: (() -> Void)?
    public var onPrevious: (() -> Void)?
    public var onClose: (() -> Void)?
    /// Fires whenever the displayed count string changes (nil = clear).
    public var onCountsChanged: ((String?) -> Void)?

    /// The current count string, or nil when the field is empty.
    public private(set) var countText: String?

    /// The last text the field reported (empty = no active needle). Prefill
    /// paths that set the field directly update this via `setQuery` — the
    /// engine reports counts for a seed that never went through `queryChanged`.
    private var lastQueryText = ""

    private var debounce: DispatchWorkItem?

    public init() {}

    /// Track the field's text WITHOUT scheduling a search. Prefill paths
    /// (`⌘F` with a selection) set the field and run the search themselves.
    public func setQuery(_ text: String) {
        lastQueryText = text
    }

    /// Feed the field's current text in on every change. The search fires after
    /// `debounceMs`; emptying the field also clears the counts.
    public func queryChanged(_ text: String) {
        lastQueryText = text
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.debounce = nil
            self.onQueryChanged?(text)
            if text.isEmpty { self.setCounts(total: nil, selected: nil) }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.debounceMs),
                                      execute: work)
    }

    /// Fire any pending query immediately (Return / chevron taps must navigate
    /// the needle already in the field, not the previous one).
    public func flushPendingQuery(_ currentText: String) {
        guard let work = debounce else { return }
        work.cancel()
        debounce = nil
        onQueryChanged?(currentText)
    }

    public func cancelPendingQuery() {
        debounce?.cancel()
        debounce = nil
    }

    /// `total` / `selected` as the engine reports them (nil = the engine sent
    /// -1, meaning "none"). `selected` is the engine's index into the match
    /// list, so it is displayed +1.
    public func setCounts(total: Int?, selected: Int?) {
        let text: String?
        if lastQueryText.isEmpty {
            text = nil
        } else {
            let totalCount = total ?? 0
            if totalCount == 0 {
                text = "0/0"
            } else if let selected, selected >= 0 {
                text = "\(selected + 1)/\(totalCount)"
            } else {
                text = "–/\(totalCount)"
            }
        }
        if text != countText {
            countText = text
            onCountsChanged?(text)
        }
    }
}
