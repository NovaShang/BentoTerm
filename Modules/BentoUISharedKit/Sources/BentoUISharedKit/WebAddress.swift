import Foundation

/// What the browser's address bar accepts.
///
/// Type an address and get that page — `localhost:5173`, `github.com/x`, a
/// full URL. `localhost` means the machine the tab's pane is on (see
/// `WebTab.navigate`).
public enum WebAddress {

    /// Short TLDs only, and a fixed list. Anything longer would start claiming
    /// `main.rs` and `config.yaml`, which are file names, not domains.
    private static let tlds: Set<String> = [
        "com", "org", "net", "io", "dev", "app", "co", "ai", "sh", "me", "gg",
        "edu", "gov", "cn", "uk", "de", "fr", "jp", "xyz", "so", "to", "run",
    ]

    /// The address `query` is asking for, or nil if it isn't one.
    public static func candidate(for query: String) -> URL? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !q.contains(" ") else { return nil }

        if let url = URL(string: q), let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https", url.host != nil {
            return url
        }
        // `localhost:5173`, `127.0.0.1:8080/x` — the shape a terminal prints,
        // and the reason this hatch exists at all.
        let head = q.split(separator: "/", maxSplits: 1).first.map(String.init) ?? q
        let bareHost = head.split(separator: ":").first.map(String.init) ?? head
        if bareHost == "localhost" || bareHost == "127.0.0.1" {
            return URL(string: "http://" + q)
        }
        // `github.com/nova/x` — a domain, not a path. Checked last and with a
        // short TLD list so a real file of that name is never shadowed.
        guard head.contains("."), !head.hasPrefix("."), !head.hasSuffix(".") else { return nil }
        let hostPart = head.split(separator: ":").first.map(String.init) ?? head
        guard let tld = hostPart.split(separator: ".").last.map(String.init)?.lowercased(),
              tlds.contains(tld) else { return nil }
        return URL(string: "https://" + q)
    }
}
