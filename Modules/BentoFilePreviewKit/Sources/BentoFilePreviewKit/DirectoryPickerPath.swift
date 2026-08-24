import Foundation

/// Where the directory picker currently *is* — one absolute path, moved a
/// level at a time.
///
/// The picker browses rather than selects: the directory you are standing in
/// IS the pick, so there is no second "which row is checked" state that can
/// disagree with what the list shows. That is also what makes going up work
/// at all — the old tree picker could only name paths under its root, so a
/// pane whose cwd was already deep inside a repo could never reach the repo
/// itself.
///
/// Split out of the view so the rules that actually bite — "/" is a fixed
/// point going up, joining never doubles a slash, and re-rooting must drop
/// the previous host's path entirely — are testable without a view hierarchy.
public struct DirectoryPickerPath: Equatable {
    /// One tappable ancestor in the breadcrumb.
    public struct Crumb: Equatable, Identifiable {
        /// Display text: "/" for the filesystem root, else the leaf name.
        public let label: String
        /// Absolute path to jump to when tapped.
        public let path: String
        public var id: String { path }
    }

    /// The directory being browsed, absolute and trailing-slash-free.
    /// nil = the picker has no usable location (no pane, or the cwd lookup
    /// failed) → nothing can be confirmed.
    public private(set) var current: String?

    public init(_ path: String? = nil) {
        current = path.map(Self.normalized)
    }

    /// Point at a new starting directory (the sheet opened on another pane,
    /// or the lookup failed with nil). Nothing carries across: the old path
    /// described a directory on a machine we may no longer be talking to.
    public mutating func reset(_ path: String?) {
        current = path.map(Self.normalized)
    }

    /// Descend into a child of the current directory.
    public mutating func enter(_ name: String) {
        guard let current else { return }
        self.current = Self.join(current, name)
    }

    /// Go to the parent. "/" is a fixed point — the walk up stops there
    /// rather than producing "" or a relative path.
    public mutating func up() {
        guard let parent else { return }
        current = parent
    }

    /// Jump straight to an ancestor (a breadcrumb tap). Ignored when it is
    /// not actually an ancestor-or-self of where we are, so a stale crumb
    /// from a previous location can never teleport the picker.
    public mutating func jump(to path: String) {
        guard let current else { return }
        let target = Self.normalized(path)
        guard target == current || Self.isAncestor(target, of: current) else { return }
        self.current = target
    }

    public var parent: String? {
        guard let current, current != "/" else { return nil }
        guard let slash = current.lastIndex(of: "/") else { return nil }
        let head = String(current[current.startIndex ..< slash])
        return head.isEmpty ? "/" : head
    }

    public var canGoUp: Bool { parent != nil }

    /// Root-first trail of everything above and including `current`.
    public var breadcrumb: [Crumb] {
        guard let current else { return [] }
        var crumbs = [Crumb(label: "/", path: "/")]
        var built = ""
        for part in current.split(separator: "/") {
            built += "/" + part
            crumbs.append(Crumb(label: String(part), path: built))
        }
        return crumbs
    }

    /// The absolute path to hand back on confirm — nil when there is none.
    public var selectedPath: String? { current }

    public var canConfirm: Bool { current != nil }

    /// Leaf name of the current directory, for the confirm button's subtitle.
    public var displayName: String? {
        guard let current else { return nil }
        return current == "/" ? "/" : String(current.split(separator: "/").last ?? "/")
    }

    // MARK: - Path arithmetic

    /// Trailing slashes off, but "/" stays "/" — so joining never produces
    /// "//a" or "/a//b".
    static func normalized(_ path: String) -> String {
        var s = path
        while s.count > 1, s.hasSuffix("/") { s.removeLast() }
        return s.isEmpty ? "/" : s
    }

    static func join(_ dir: String, _ name: String) -> String {
        dir == "/" ? "/" + name : dir + "/" + name
    }

    /// Strict ancestor test on normalized paths — the trailing "/" matters,
    /// otherwise "/a/bc" would count as living under "/a/b".
    static func isAncestor(_ ancestor: String, of path: String) -> Bool {
        if ancestor == "/" { return path != "/" }
        return path.hasPrefix(ancestor + "/")
    }
}
