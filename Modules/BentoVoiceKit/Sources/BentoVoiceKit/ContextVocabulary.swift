import Foundation

/// What the terminal knows about the pane a recording targets, read on the
/// main actor when the hold begins. Plain values only, so taking it costs a
/// few property reads; anything that touches the disk goes in
/// `loadHostAliases`, which `ContextVocabulary.gather` runs off the main
/// thread.
public struct VoiceContextSnapshot: Sendable {
    /// tmux `pane_current_command` (a process name: `node`, `claude`, `vim`).
    public var command: String?
    /// The pane's working directory.
    public var cwd: String?
    /// tmux `pane_title` (what the program or a rename set: often a branch,
    /// a task, or `user@host: ~/path`).
    public var paneTitle: String?
    public var sessionName: String?
    /// Active window first.
    public var windowNames: [String]
    /// The host this session runs on (its name / hostname), in memory.
    public var hostNames: [String]
    /// Host aliases that have to be read from disk (`~/.ssh/config` on the
    /// Mac, the saved host list on iOS). Never called on the main thread.
    public var loadHostAliases: (@Sendable () -> [String])?

    public init(command: String? = nil, cwd: String? = nil, paneTitle: String? = nil,
                sessionName: String? = nil, windowNames: [String] = [], hostNames: [String] = [],
                loadHostAliases: (@Sendable () -> [String])? = nil) {
        self.command = command
        self.cwd = cwd
        self.paneTitle = paneTitle
        self.sessionName = sessionName
        self.windowNames = windowNames
        self.hostNames = hostNames
        self.loadHostAliases = loadHostAliases
    }
}

/// The phrase list handed to Apple's recognizers as contextual strings
/// (`SFSpeechRecognitionRequest.contextualStrings`,
/// `AnalysisContext.contextualStrings`): words the user is likely to SAY
/// while looking at this pane, so "tmux" stops coming back as "Tomox".
///
/// Unlike Qwen's corpus this is a short list of names, never raw screen
/// text — Apple's biasing nudges the language model toward listed phrases
/// and cannot echo them back as a transcript, but a list of noise just
/// dilutes the nudge. Order = priority: what's in this pane first, then the
/// session, the built-in dev terms, and host aliases last (the one source
/// that can be long). Pure, so the rules are tested without a terminal.
public enum ContextVocabulary {
    /// Apple caps nothing documented, but biasing weakens as the list grows;
    /// ~100 covers a pane, a session and a modest ssh config.
    public static let defaultCap = 100

    /// Terms that come up in nearly every session.
    public static let builtIn: [String] = [
        "tmux", "git", "docker compose", "npm run dev", "pnpm", "Claude Code", "Codex",
        "SSH", "Bento", "localhost", "pull request", "CI",
    ]

    /// Path components that say nothing about the project.
    static let pathNoise: Set<String> = [
        "users", "home", "root", "private", "var", "tmp", "volumes", "mnt", "opt", "usr",
        "library", "~", ".", "..",
    ]

    /// Login shells: what `pane_current_command` says when nothing is running.
    static let shellNames: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "login", "-zsh", "-bash"]

    static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "is", "it", "with", "at", "by",
    ]

    /// Read the disk-backed sources and build the list, off the main thread.
    public static func gather(_ snapshot: VoiceContextSnapshot?, cap: Int = defaultCap) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            let aliases = snapshot?.loadHostAliases?() ?? []
            return build(snapshot ?? VoiceContextSnapshot(), hostAliases: aliases, cap: cap)
        }.value
    }

    public static func build(_ s: VoiceContextSnapshot, hostAliases: [String] = [],
                             cap: Int = defaultCap) -> [String] {
        var out = OrderedPhrases(cap: cap)
        if let command = s.command { out.add(commandPhrases(command)) }
        if let cwd = s.cwd { out.add(pathPhrases(cwd)) }
        if let title = s.paneTitle { out.add(titlePhrases(title)) }
        for name in s.windowNames { out.add(namePhrases(name)) }
        if let session = s.sessionName { out.add(namePhrases(session)) }
        for host in s.hostNames { out.add(hostPhrases(host)) }
        out.add(builtIn)
        for alias in hostAliases { out.add(hostPhrases(alias)) }
        return out.items
    }

    // MARK: - Splitting

    /// `node`, `/usr/local/bin/node`, `npm run dev` → the program name(s).
    /// A bare login shell is dropped: it's what every idle pane says.
    static func commandPhrases(_ command: String) -> [String] {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let words = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        let program = (words.first ?? trimmed).split(separator: "/").last.map(String.init) ?? trimmed
        if shellNames.contains(program.lowercased()) { return [] }
        // The spoken part of a command line: up to the first flag.
        let spoken = [program] + words.dropFirst().prefix { !$0.hasPrefix("-") }
        var result: [String] = []
        if spoken.count > 1 { result.append(spoken.joined(separator: " ")) }
        result.append(contentsOf: withSpacedVariant(program))
        return result
    }

    /// `/Users/nova/code/bento-term/Modules` → `Modules`, `bento-term`,
    /// `bento term`, `code` — deepest (most specific) first, the home
    /// directory's owner dropped along with the system prefixes.
    static func pathPhrases(_ path: String) -> [String] {
        let parts = path.split(separator: "/").map(String.init)
        var keep: [String] = []
        for (i, part) in parts.enumerated() {
            if pathNoise.contains(part.lowercased()) { continue }
            // The account name right after /Users or /home.
            if i > 0, ["users", "home"].contains(parts[i - 1].lowercased()) { continue }
            if part.hasPrefix(".") { continue }
            keep.append(part)
        }
        return keep.reversed().flatMap(withSpacedVariant)
    }

    /// Identifier-ish words from a pane title: branch names (`feat/voice`
    /// gives `feat/voice`, `voice`), file names, project names. Sentence glue
    /// and pure numbers are dropped.
    static func titlePhrases(_ title: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ":@()[]{}<>,;\"'`|*✳·•…"))
        var result: [String] = []
        for raw in title.components(separatedBy: separators) {
            if raw.hasPrefix("/") || raw.hasPrefix("~") {
                // A path (`user@host: ~/code/app`): its components.
                result.append(contentsOf: pathPhrases(raw).filter(isWordLike))
                continue
            }
            let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
            guard isWordLike(token) else { continue }
            if stopWords.contains(token.lowercased()) { continue }
            if token.contains("/") {
                // A branch: the whole thing, then its pieces.
                result.append(token)
                for piece in token.split(separator: "/").map(String.init) where isWordLike(piece) {
                    result.append(contentsOf: withSpacedVariant(piece))
                }
            } else {
                result.append(contentsOf: withSpacedVariant(token))
            }
        }
        return result
    }

    /// A window or session name as typed. tmux's default numeric names
    /// ("0", "1") are nothing anyone says.
    static func namePhrases(_ name: String) -> [String] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isWordLike(trimmed) else { return [] }
        return withSpacedVariant(trimmed)
    }

    /// `prod-db` stays; `build.example.com` also gives `build`.
    static func hostPhrases(_ host: String) -> [String] {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isWordLike(trimmed) else { return [] }
        // A bare IP address is not something anyone says.
        if trimmed.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" }) { return [] }
        var result = withSpacedVariant(trimmed)
        if trimmed.contains("."), let first = trimmed.split(separator: ".").first, isWordLike(String(first)) {
            result.append(contentsOf: withSpacedVariant(String(first)))
        }
        return result
    }

    /// `bento-term` → `bento-term`, `bento term`: the recognizer hears the
    /// spoken form, the screen shows the written one.
    static func withSpacedVariant(_ s: String) -> [String] {
        guard s.contains("-") || s.contains("_"), !s.contains(where: \.isWhitespace) else { return [s] }
        let spaced = s.split(whereSeparator: { $0 == "-" || $0 == "_" }).joined(separator: " ")
        return spaced.isEmpty || spaced == s ? [s] : [s, spaced]
    }

    /// At least one letter (any script), not a hash or a version, sane length.
    static func isWordLike(_ s: String) -> Bool {
        guard (2...40).contains(s.count), s.contains(where: \.isLetter) else { return false }
        // Commit hashes / ids: long runs of hex with digits in them.
        if s.count >= 7, s.allSatisfy(\.isHexDigit), s.contains(where: \.isNumber) { return false }
        return true
    }
}

/// Insertion-ordered, case-insensitively deduped, capped.
struct OrderedPhrases {
    let cap: Int
    private(set) var items: [String] = []
    private var seen = Set<String>()

    init(cap: Int) { self.cap = cap }

    mutating func add(_ phrases: [String]) {
        for p in phrases {
            guard items.count < cap else { return }
            let t = p.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, seen.insert(t.lowercased()).inserted else { continue }
            items.append(t)
        }
    }
}
