import Foundation

/// A dev server announcing itself in terminal output.
public struct DevServerAnnouncement: Equatable, Sendable {
    /// Always spelled `localhost`, whatever the server printed: `0.0.0.0` is
    /// what the process bound, not an address anything connects to.
    public let url: URL
    public let port: Int

    public init(url: URL, port: Int) {
        self.url = url
        self.port = port
    }
}

/// Notices `Local: http://localhost:5173/` going past.
///
/// This is the moment the feature is for: an agent starts a dev server and the
/// address it prints is on a machine that might be a continent away. Spotting
/// it is what lets Bento offer the page instead of making someone copy a port
/// number into an `ssh -L` they have to write themselves.
///
/// Deliberately NOT a list of known frameworks. Vite, Next, Rails, webpack,
/// `python -m http.server` and every internal tool print the same thing in a
/// different shape; the constant is a loopback URL with an explicit port. A
/// framework list would be a maintenance treadmill that still missed the
/// user's own script.
public enum DevServerDetector {

    /// Cheap reject before anything is decoded.
    ///
    /// This runs on the terminal's OUTPUT path, which is not allowed to cost
    /// anything — a byte scan for `://` skips essentially all real output
    /// without ever building a String.
    public static func mightAnnounce(_ bytes: some Collection<UInt8>) -> Bool {
        // ":" "/" "/"
        var window: (UInt8, UInt8) = (0, 0)
        for b in bytes {
            if window.0 == 0x3A, window.1 == 0x2F, b == 0x2F { return true }
            window = (window.1, b)
        }
        return false
    }

    /// The first loopback address with an explicit port in `text`, or nil.
    public static func detect(in text: String) -> DevServerAnnouncement? {
        guard let regex = Self.pattern else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in regex.matches(in: text, range: range) {
            guard let whole = Range(match.range, in: text) else { continue }
            var raw = String(text[whole])
            // Terminal output loves to put a URL in quotes, brackets or at the
            // end of a sentence; none of those are part of the address.
            raw = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:'\"“”)]>»"))
            guard let url = URL(string: raw), let port = url.port,
                  LocalPortProbe.isPlausible(port) else { continue }
            guard let normalized = normalize(url) else { continue }
            return DevServerAnnouncement(url: normalized, port: port)
        }
        return nil
    }

    /// `0.0.0.0` and `[::]` are bind addresses — "every interface" — and mean
    /// nothing to a client. What the user wants is the loopback name.
    private static func normalize(_ url: URL) -> URL? {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.host = "localhost"
        return c?.url
    }

    /// Requiring an explicit port is the filter that keeps prose out: a bare
    /// `http://localhost` in a sentence is not a server coming up.
    private static let pattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\]):\d{2,5}(?:/[^\s]*)?"#,
        options: [.caseInsensitive])
}

/// Which announcements have already been offered, so a chip appears when a
/// server comes up and not every time its address scrolls past again.
///
/// Restarting a dev server is something agents do constantly, and every restart
/// reprints the banner. Offering the same port again each time would turn the
/// feature into a popup that never stops.
public struct DevServerOffers {
    /// pane id → ports already offered there.
    private var offered: [String: Set<Int>] = [:]

    public init() {}

    /// True if this is worth showing the user. Records it either way.
    public mutating func shouldOffer(port: Int, inPane paneID: String) -> Bool {
        offered[paneID, default: []].insert(port).inserted
    }

    /// The pane's program exited or the pane went away — a server that comes up
    /// again after that is genuinely new.
    public mutating func forget(paneID: String) {
        offered[paneID] = nil
    }
}
