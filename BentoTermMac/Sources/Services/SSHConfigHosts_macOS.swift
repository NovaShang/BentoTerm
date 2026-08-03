#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import Foundation
import Darwin
import BentoSessionKit
import BentoFoundationKit

/// Lists the concrete host aliases in the user's `~/.ssh/config` — the names
/// `ssh <alias>` accepts. Wildcard and negated patterns (`*`, `?`, `!`) are
/// matching rules, not destinations, so they're skipped. Any problem — missing
/// file, unreadable, malformed — yields an empty list; the menus that consume
/// this simply show nothing.
public enum SSHConfigHosts {
    public static func hosts() -> [String] {
        hosts(in: NSHomeDirectory() + "/.ssh/config", depth: 0)
    }

    /// Parse one config file, following `Include` directives (globs allowed,
    /// relative paths resolve against ~/.ssh). Depth-limited: OpenSSH allows
    /// nested includes, and a cycle must not hang the menu.
    private static func hosts(in path: String, depth: Int) -> [String] {
        guard depth < 3,
              let text = try? String(contentsOfFile: path, encoding: .utf8)
        else { return [] }
        var found: [String] = []
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let (keyword, arguments) = splitKeyword(line)
            switch keyword {
            case "host":
                for pattern in tokenize(arguments)
                where !pattern.contains("*") && !pattern.contains("?") && !pattern.hasPrefix("!") {
                    found.append(pattern)
                }
            case "include":
                for pattern in tokenize(arguments) {
                    for file in expand(includePattern: pattern) {
                        found.append(contentsOf: hosts(in: file, depth: depth + 1))
                    }
                }
            default:
                break
            }
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0).inserted }
    }

    /// ssh_config lines are `keyword [=] arguments` with a case-insensitive
    /// keyword. Returns the lowercased keyword and the raw argument string.
    private static func splitKeyword(_ line: String) -> (String, String) {
        guard let cut = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" })
        else { return (line.lowercased(), "") }
        let keyword = String(line[..<cut]).lowercased()
        var rest = line[line.index(after: cut)...].drop { $0 == " " || $0 == "\t" }
        if rest.first == "=" { rest = rest.dropFirst().drop { $0 == " " || $0 == "\t" } }
        return (keyword, String(rest))
    }

    /// Split arguments on whitespace, honoring double quotes (`Host "my host"`).
    /// A `#` token ends the line — OpenSSH has no trailing comments, but people
    /// write them anyway, and "#staging" must not show up as a host.
    private static func tokenize(_ arguments: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for ch in arguments {
            if ch == "\"" {
                inQuotes.toggle()
            } else if (ch == " " || ch == "\t") && !inQuotes {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        if let comment = tokens.firstIndex(where: { $0.hasPrefix("#") }) {
            tokens.removeSubrange(comment...)
        }
        return tokens
    }

    /// Resolve an `Include` value to absolute paths: `~` → home, relative →
    /// under ~/.ssh (OpenSSH's rule), then glob for wildcards.
    private static func expand(includePattern raw: String) -> [String] {
        var pattern = raw
        if pattern.hasPrefix("~") {
            pattern = NSHomeDirectory() + pattern.dropFirst()
        } else if !pattern.hasPrefix("/") {
            pattern = NSHomeDirectory() + "/.ssh/" + pattern
        }
        var g = glob_t()
        defer { globfree(&g) }
        guard glob(pattern, 0, nil, &g) == 0 else { return [] }
        return (0..<g.gl_pathc).compactMap { i in
            g.gl_pathv[i].flatMap { String(cString: $0) }
        }
    }
}
#endif
