import Foundation
import Darwin

/// One live local→remote port forward.
///
/// The whole point of the feature is that this struct is invisible: a dev
/// server on a build box prints `http://localhost:5173`, and clicking it opens
/// that page. Nobody types `ssh -L`, nobody picks a port. This is the bookkeeping
/// that makes the address honest.
public struct PortForward: Sendable, Equatable, Identifiable {
    public let host: LinkHost
    /// The port the service actually listens on, over there.
    public let remotePort: Int
    /// The port it is reachable on, here. Same number whenever we can get it.
    public let localPort: Int

    public var id: String { "\(host.remoteID ?? "local"):\(remotePort)" }

    /// True when we could not get the same number locally.
    ///
    /// This matters to the user, not just to us: a page that hardcodes its own
    /// port in an absolute link (`http://localhost:5173/api`) will send the
    /// browser to a port that is either empty or someone else's. We cannot fix
    /// that from out here, so we say so instead of letting the page half-work.
    public var isRenumbered: Bool { localPort != remotePort }

    /// What the browser actually loads.
    public func localURL(replacing original: URL) -> URL {
        var c = URLComponents(url: original, resolvingAgainstBaseURL: false)
        c?.host = "127.0.0.1"
        c?.port = localPort
        return c?.url ?? original
    }

    public init(host: LinkHost, remotePort: Int, localPort: Int) {
        self.host = host
        self.remotePort = remotePort
        self.localPort = localPort
    }
}

/// Why a forward could not be established or has stopped working.
///
/// These map onto what the user is told. The distinction that earns its keep is
/// `hostUnreachable` vs `nothingListening`: in a browser both look identical
/// (a blank page and a refused connection), but we know which one it is,
/// and that is the only thing we know that a browser does not.
public enum PortForwardError: Error, Sendable, Equatable {
    /// Could not reach the machine at all — ssh is gone, the session died.
    case hostUnreachable(String)
    /// The tunnel is up; nothing is listening on that port over there. Almost
    /// always "the dev server is restarting", which is a normal thing for an
    /// agent to be doing to it.
    case nothingListening
    /// Every local port we tried was taken.
    case noLocalPort
    /// This build cannot forward for this host (no session to ride).
    case unsupported(String)
}

@MainActor
public protocol PortForwarding: AnyObject {
    /// Make `remotePort` on `host` reachable from this device. Idempotent: two
    /// panes on the same box asking for the same port share one forward.
    func forward(remotePort: Int, on host: LinkHost) async throws -> PortForward

    /// Is this forward still carrying traffic? Asked when a page fails to load,
    /// to tell "the dev server is down" from "the machine is gone" — the two
    /// need different sentences and a browser cannot tell them apart.
    func isAlive(_ forward: PortForward) async -> Bool

    /// Tear down one forward. Closing the tab that owns it is what calls this:
    /// no forward outlives something visible.
    func close(_ forward: PortForward)

    /// Every forward for a machine — its session ended.
    func closeAll(on host: LinkHost)

    var active: [PortForward] { get }
}

/// The forwarder for this platform, installed at launch by the app target.
@MainActor
public enum PortForwarders {
    public static var current: (any PortForwarding)?
}

// MARK: - Local port selection

/// Picking the local side of a forward.
///
/// Same number as the remote whenever possible — not for tidiness, but because
/// a page's own absolute links carry the remote port, and they only keep working
/// if the numbers match. Renumbering is the fallback, and a fallback we tell the
/// user about.
public enum LocalPortProbe {

    /// Ports we will never hand out even if they happen to be free: the
    /// privileged range needs root, and a "remote port" outside 1…65535 is a
    /// parse error upstream, not a port.
    public static func isPlausible(_ port: Int) -> Bool { port >= 1024 && port <= 65535 }

    /// Can we bind 127.0.0.1:port right now?
    ///
    /// Loopback only, everywhere. A forward puts someone else's service on this
    /// machine; binding 0.0.0.0 would put it on the network the machine is on,
    /// which is nobody's idea of what clicking a link does.
    public static func isFree(_ port: Int) -> Bool {
        guard port > 0, port <= 65535 else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        // SO_REUSEADDR so a port left in TIME_WAIT by a forward we just closed
        // does not read as taken. An active listener still refuses the bind,
        // which is the case we actually care about.
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }

    /// A free ephemeral port, or nil.
    public static func ephemeral() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }
        var out = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &out) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard got == 0 else { return nil }
        return Int(UInt16(bigEndian: out.sin_port))
    }

    /// The local port to use for `remotePort`: the same number if it is free,
    /// otherwise an ephemeral one. `taken` are ports this process has already
    /// promised to other forwards but may not have bound yet.
    public static func choose(matching remotePort: Int, taken: Set<Int>) -> Int? {
        if isPlausible(remotePort), !taken.contains(remotePort), isFree(remotePort) {
            return remotePort
        }
        // A handful of tries: `ephemeral()` closes its socket before we return,
        // so two rapid calls can name the same port.
        for _ in 0..<8 {
            guard let p = ephemeral() else { break }
            if !taken.contains(p) { return p }
        }
        return nil
    }
}

// MARK: - The ssh command that adds a tunnel

/// Builds the `ssh -O …` argument vectors that add and remove a forward on an
/// ALREADY authenticated connection.
///
/// Pure and tested because these strings are the whole macOS implementation and
/// a typo in one of them fails at runtime, on a remote host, in a way that
/// looks like the feature not working. `ssh` itself rejects a malformed
/// `-L` spec with "Bad local forwarding specification" long before it reaches
/// the control socket, so the shape is worth pinning down here.
public enum SSHForwardCommand {

    /// `bind:localPort:remoteHost:remotePort`.
    ///
    /// Bound to `127.0.0.1` explicitly rather than left to `GatewayPorts`: a
    /// forward puts someone else's service on this machine, and it must not
    /// land on the network this machine is joined to.
    public static func spec(localPort: Int, remotePort: Int, remoteHost: String = "localhost") -> String {
        "127.0.0.1:\(localPort):\(remoteHost):\(remotePort)"
    }

    public static func forward(localPort: Int, remotePort: Int, alias: String,
                               controlPath: String?) -> [String] {
        control(controlPath) + ["-O", "forward", "-L",
                                spec(localPort: localPort, remotePort: remotePort), alias]
    }

    public static func cancel(localPort: Int, remotePort: Int, alias: String,
                              controlPath: String?) -> [String] {
        control(controlPath) + ["-O", "cancel", "-L",
                                spec(localPort: localPort, remotePort: remotePort), alias]
    }

    public static func check(alias: String, controlPath: String?) -> [String] {
        control(controlPath) + ["-O", "check", alias]
    }

    /// No `-o ControlPath` when the user's own ssh_config names one — ssh finds
    /// it itself, and overriding would opt them out of their own multiplexing.
    private static func control(_ path: String?) -> [String] {
        path.map { ["-o", "ControlPath=\($0)"] } ?? []
    }
}
