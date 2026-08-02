import Foundation

/// WHICH tmux server a session lives on.
///
/// Until remote sessions existed there was only ever one server — the one on
/// this Mac — so a session's identity could be its bare name. It can't be any
/// more: `bento` on this machine and `bento` on a build box are two different
/// sessions with two different sets of running processes, and every place that
/// keyed off the name alone (the open-windows map, the reopen list, the tab
/// strip, and — worst — `tmux kill-session`) would happily confuse them.
public enum TmuxServer: Hashable, Sendable {
    /// The tmux server on this machine, reached over a local pty.
    case local
    /// A tmux server reached by running `ssh <alias>`, where `alias` is a name
    /// from the user's own `~/.ssh/config`. Everything about *how* to reach it
    /// — hostname, user, port, jump hosts, keys, 2FA — is ssh's business, not
    /// ours; we only ever hand it the alias.
    case ssh(host: String)

    public var isLocal: Bool { self == .local }

    /// The ssh alias, or nil for the local server.
    public var sshHost: String? {
        if case .ssh(let host) = self { return host }
        return nil
    }
}

/// A session's full identity: which server, and its name on that server.
///
/// `key` is the string form used wherever a session has to survive as text
/// (`UserDefaults`, menu `representedObject`, dictionary keys). A LOCAL
/// session's key is just its name, so every key already persisted by an older
/// build keeps parsing, and every local code path reads exactly as before.
public struct TmuxSessionID: Hashable, Sendable {
    public let server: TmuxServer
    public let name: String

    public init(server: TmuxServer, name: String) {
        self.server = server
        self.name = name
    }

    public static func local(_ name: String) -> TmuxSessionID {
        TmuxSessionID(server: .local, name: name)
    }

    public static func ssh(host: String, name: String) -> TmuxSessionID {
        TmuxSessionID(server: .ssh(host: host), name: name)
    }

    public var isLocal: Bool { server.isLocal }

    /// Round-trips through `init?(key:)`. `ssh://<host>/<name>` is unambiguous:
    /// an ssh alias can't contain `/` (it's a config token), so the first slash
    /// after the scheme always separates host from session name — and a tmux
    /// session name can't start with the literal `ssh://`, because `:` is
    /// tmux's own target separator and is rejected in session names.
    public var key: String {
        switch server {
        case .local: return name
        case .ssh(let host): return "ssh://\(host)/\(name)"
        }
    }

    public init?(key: String) {
        guard !key.isEmpty else { return nil }
        guard key.hasPrefix("ssh://") else {
            self.init(server: .local, name: key)
            return
        }
        let rest = key.dropFirst("ssh://".count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let host = String(rest[..<slash])
        let name = String(rest[rest.index(after: slash)...])
        guard !host.isEmpty, !name.isEmpty else { return nil }
        self.init(server: .ssh(host: host), name: name)
    }

    /// What a human should see in a menu or a tab: the bare name locally, and
    /// `name — host` for a remote one. A remote session must never be shown as
    /// if it were a local session of the same name.
    public var displayName: String {
        switch server {
        case .local: return name
        case .ssh(let host): return "\(name) — \(host)"
        }
    }
}

/// A session name that is known to live on the LOCAL tmux server.
///
/// This exists so the local-only operations — everything in `TmuxCLI`, which
/// shells out to the `tmux` binary on *this* machine — cannot be handed the
/// name of a session that lives somewhere else. Before remote sessions, "Kill
/// Session" in a window's toolbar passed `tab.sessionKey` straight to
/// `tmux kill-session`; the same call from a remote window would have killed
/// the local session that happened to share the name, destroying whatever was
/// running in it.
///
/// A guard would have fixed that too, but a guard is only as good as the next
/// person who edits the call site. There are exactly two ways to get one of
/// these, and both state where the name came from:
///
///   • `init?(_ id:)` — nil for a session on another server, so the compiler
///     makes you deal with the remote case.
///   • `init(onLocalServer:)` — for names that came *out* of the local server
///     (`tmux list-sessions` on this machine), where locality is a fact about
///     the source rather than something to check.
public struct LocalTmuxSessionName: Hashable, Sendable {
    public let rawValue: String

    /// Local sessions only — nil for anything on an ssh server.
    public init?(_ id: TmuxSessionID) {
        guard id.isLocal else { return nil }
        self.rawValue = id.name
    }

    /// A name read back from the local tmux server itself.
    public init(onLocalServer name: String) {
        self.rawValue = name
    }

    public var id: TmuxSessionID { .local(rawValue) }
}
