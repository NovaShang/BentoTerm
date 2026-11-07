import Foundation

/// Asking a tmux server which sessions it has — the one format, the one parser
/// and the one reading of a failure, for every route the question takes: the
/// Mac's local `tmux` binary, the Mac's short-lived `ssh <alias> tmux …`, a
/// control-mode connection, and a shell typed into before tmux is attached
/// (iOS's picker and a fresh connect).
///
/// There used to be three `-F` formats and two shell routes that threw stderr
/// away — so a host without tmux showed an empty list, which reads as "nothing
/// running here" rather than "install tmux".
public enum TmuxSessionListing {

    /// One session as the list reports it.
    public struct Session: Equatable, Sendable {
        public let name: String
        public let windows: Int
        /// Some client — maybe on another machine — is attached right now.
        public let attached: Bool
        /// Last output / keystroke / attach. nil when tmux reported none.
        public let lastActivity: Date?

        public init(name: String, windows: Int, attached: Bool, lastActivity: Date? = nil) {
            self.name = name
            self.windows = windows
            self.attached = attached
            self.lastActivity = lastActivity
        }
    }

    /// Name first, then three numbers we asked for. The name is not trusted to
    /// be free of the separator, so rows are read from the right; and a line
    /// whose tail isn't three numbers is not a session — that is what keeps a
    /// login banner or stray pane output out of the list.
    public static let format =
        "#{session_name}|#{session_windows}|#{?session_attached,1,0}|#{session_activity}"

    /// `list-sessions` with the format, as tmux's own command parser reads it
    /// (control mode, a shell).
    public static let command = "list-sessions -F '\(format)'"

    /// The argv for running the local binary directly (no shell, no quoting).
    public static let arguments = ["list-sessions", "-F", format]

    /// Sessions in `output`, in the order tmux printed them. Escape sequences
    /// and CRLF are tolerated: one route reads this back off a pty.
    public static func parse(_ output: String) -> [Session] {
        var sessions: [Session] = []
        // `isNewline`, not "\n": Swift reads CRLF as one character.
        for raw in ANSI.strip(output).split(whereSeparator: { $0.isNewline }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let f = line.split(separator: "|", omittingEmptySubsequences: false)
            guard f.count >= 4,
                  let windows = Int(f[f.count - 3]),
                  let attached = Int(f[f.count - 2]),
                  let activity = Int(f[f.count - 1]) else { continue }
            let name = f.dropLast(3).joined(separator: "|")
            guard !name.isEmpty, !sessions.contains(where: { $0.name == name }) else { continue }
            sessions.append(Session(
                name: name, windows: windows, attached: attached > 0,
                lastActivity: activity > 0 ? Date(timeIntervalSince1970: TimeInterval(activity)) : nil))
        }
        return sessions
    }

    // MARK: - When there is no list

    public enum Failure: Error, Equatable, Sendable {
        /// ssh could not authenticate without asking a human.
        case needsCredentials
        /// tmux is not installed, or not on the login shell's PATH.
        case noTmux
        /// tmux is there, but no server is running — no sessions yet.
        case noSessions
        /// Anything else: unreachable, host-key trouble, timeout, tmux's own
        /// complaint. Quoted, not guessed at.
        case unreachable(String)

        /// One line, for the row that stands in for the list.
        public var message: String {
            switch self {
            case .needsCredentials:
                return "Needs a password — connect once and save it to list sessions here"
            case .noTmux: return "tmux isn’t installed on this host"
            case .noSessions: return "No tmux sessions running"
            case .unreachable(let why): return why
            }
        }
    }

    /// Read a finished listing. `status` is the exit code when the route has
    /// one (a pty doesn't); `stderr` is whatever came back besides the rows —
    /// ssh's complaints, the shell's, tmux's.
    public static func result(status: Int32?, stdout: String,
                              stderr: String) -> Result<[Session], Failure> {
        let sessions = parse(stdout)
        if !sessions.isEmpty { return .success(sessions) }

        let err = ANSI.strip(stderr).lowercased()
        if err.contains("permission denied") || err.contains("no supported authentication")
            || err.contains("password") {
            return .failure(.needsCredentials)
        }
        if err.contains("host key verification failed") {
            return .failure(.unreachable("Host key verification failed"))
        }
        // Before "not installed": with no server, tmux says "error connecting
        // to /tmp/tmux-501/default (No such file or directory)", which the
        // missing-binary patterns below would otherwise claim.
        if err.contains("no server running") || err.contains("error connecting to") {
            return .failure(.noSessions)
        }
        // bash/zsh "command not found", sh "tmux: not found", fish "Unknown
        // command", a login shell that can't exec it at all.
        if err.contains("not found") || err.contains("unknown command")
            || err.contains("no such file") {
            return .failure(.noTmux)
        }
        let firstLine = stderr.split(whereSeparator: { $0.isNewline }).first
            .map { ANSI.strip(String($0)).trimmingCharacters(in: .whitespaces) } ?? ""
        if status == 0 || (status == nil && firstLine.isEmpty) { return .failure(.noSessions) }
        return .failure(.unreachable(firstLine.isEmpty ? "Couldn’t reach this host" : firstLine))
    }

    /// Whether what a failed tmux launch printed says the binary isn't there
    /// (`zsh: command not found: tmux`, `sh: tmux: not found`, …). Same
    /// reading as a listing, plus the word itself: a launch transcript can
    /// carry other "not found"s that have nothing to do with tmux.
    public static func saysTmuxIsMissing(_ output: String) -> Bool {
        guard output.lowercased().contains("tmux") else { return false }
        return result(status: nil, stdout: "", stderr: output) == .failure(.noTmux)
    }

    // MARK: - Over a shell

    /// The listing typed into a shell before tmux is attached, bracketed by
    /// markers so the answer can be cut out of whatever else the pty carries.
    ///
    /// Each marker is printed from two halves: the pty's echo of the command
    /// line shows them with a quote and a space between, so only the runtime
    /// `printf` ever produces the contiguous marker. stderr is folded into the
    /// bracket (`2>&1`) so a missing tmux can be told from an empty server.
    public struct MarkerProbe: Sendable {
        public let command: String
        public let startMarker: String
        public let endMarker: String

        public init(token: String = String(UUID().uuidString.prefix(8))) {
            let startA = "__SPK_S_\(token)_", startB = "_GO__"
            let endA = "__SPK_E_\(token)_", endB = "_DONE__"
            startMarker = startA + startB
            endMarker = endA + endB
            command =
                "printf '\\n%s%s\\n' '\(startA)' '\(startB)';" +
                " tmux \(TmuxSessionListing.command) 2>&1;" +
                " printf '%s%s\\n' '\(endA)' '\(endB)'\n"
        }

        /// What was printed between the markers. With no start marker (it can
        /// be lost to an escape sequence the shell injected), everything before
        /// the end marker.
        public func body(of output: String) -> String {
            if let s = output.range(of: startMarker), let e = output.range(of: endMarker),
               s.upperBound < e.lowerBound {
                return String(output[s.upperBound..<e.lowerBound])
            }
            if let e = output.range(of: endMarker) { return String(output[..<e.lowerBound]) }
            return output
        }

        /// The sessions, or why there are none. Rows and complaints share the
        /// one stream here, so the same text is read both ways.
        public func result(of output: String) -> Result<[Session], Failure> {
            let body = body(of: output)
            return TmuxSessionListing.result(status: nil, stdout: body, stderr: body)
        }
    }
}
