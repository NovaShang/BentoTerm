import Foundation
import BentoFoundationKit
import Citadel
import NIOCore
import NIOPosix
import NIOSSH
import os

private let log = Logger(subsystem: "com.novashang.bento", category: "PortForward")

/// Port forwarding on iOS.
///
/// This is the half of the feature the phone could not fake. On a Mac you can
/// always drop to a shell and run `ssh -L` yourself; on a phone there is no
/// such escape hatch, so "the agent started a dev server on the build box and I
/// want to look at it from the sofa" is simply impossible today.
///
/// The shape is the standard SSH client one: listen on `127.0.0.1:<local>`, and
/// for every connection that arrives, open a `direct-tcpip` channel over the
/// session we are ALREADY authenticated on and splice the two together. No
/// second login, and — unlike a custom URL scheme handler — the page keeps a
/// real origin, so cookies, relative links and the WebSocket a dev server needs
/// for hot reload all work without special cases.
@MainActor
final class IOSPortForwarder: PortForwarding {

    /// Live SSH connections by `LinkHost.remoteID`, registered as sessions
    /// connect. Held weakly: the forwarder must never be the reason a
    /// disconnected client stays alive.
    private var clients: [String: WeakClient] = [:]
    private var tunnels: [String: LocalTunnel] = [:]
    private var claimed: Set<Int> = []

    private struct WeakClient { weak var client: SSHClient? }

    var active: [PortForward] { tunnels.values.map(\.forward) }

    // MARK: Session registry

    /// A session connected: its ports are now reachable.
    func register(client: SSHClient, for remoteID: String) {
        clients[remoteID] = WeakClient(client: client)
    }

    /// A session ended. Its tunnels go with it — nothing keeps carrying traffic
    /// for a connection that is gone.
    func unregister(remoteID: String) {
        clients[remoteID] = nil
        for tunnel in tunnels.values where tunnel.forward.host.remoteID == remoteID {
            close(tunnel.forward)
        }
    }

    // MARK: PortForwarding

    func forward(remotePort: Int, on host: LinkHost) async throws -> PortForward {
        // A local pane's `localhost` is already this device — but on iOS there
        // are no local panes, so this is only the degenerate case.
        guard let remoteID = host.remoteID else {
            return PortForward(host: host, remotePort: remotePort, localPort: remotePort)
        }
        let key = PortForward(host: host, remotePort: remotePort, localPort: remotePort).id
        if let existing = tunnels[key] { return existing.forward }

        guard LocalPortProbe.isPlausible(remotePort) else {
            throw PortForwardError.unsupported("Port \(remotePort) isn’t forwardable")
        }
        guard let client = clients[remoteID]?.client else {
            throw PortForwardError.unsupported("No live connection to \(host.label)")
        }
        guard let localPort = LocalPortProbe.choose(matching: remotePort, taken: claimed) else {
            throw PortForwardError.noLocalPort
        }
        claimed.insert(localPort)
        defer { claimed.remove(localPort) }

        let made = PortForward(host: host, remotePort: remotePort, localPort: localPort)
        do {
            let tunnel = try await LocalTunnel.start(
                forward: made, client: SendableSSHClient(client), remoteHost: "localhost")
            tunnels[made.id] = tunnel
            log.log("""
                forward \(host.label, privacy: .public) \
                \(remotePort, privacy: .public)→\(localPort, privacy: .public)
                """)
            return made
        } catch {
            log.error("forward failed: \(String(describing: error), privacy: .public)")
            throw PortForwardError.hostUnreachable("Couldn’t reach \(host.label)")
        }
    }

    /// The tunnel is alive exactly while its SSH connection is. This is what
    /// lets a failed page load say "the dev server isn’t up" instead of
    /// "something went wrong".
    func isAlive(_ forward: PortForward) async -> Bool {
        guard let remoteID = forward.host.remoteID else { return true }
        guard tunnels[forward.id] != nil else { return false }
        return clients[remoteID]?.client != nil
    }

    func close(_ forward: PortForward) {
        guard let tunnel = tunnels.removeValue(forKey: forward.id) else { return }
        tunnel.stop()
    }

    func closeAll(on host: LinkHost) {
        for tunnel in tunnels.values where tunnel.forward.host == host {
            close(tunnel.forward)
        }
    }
}

// MARK: - One listening port

/// A local listener whose every connection becomes a `direct-tcpip` channel.
private final class LocalTunnel: @unchecked Sendable {
    let forward: PortForward
    private let channel: Channel
    /// Held here rather than captured by the accept closure: `SSHClient` is not
    /// Sendable, and this class already carries the unchecked promise.
    private let client: SSHClient
    private let remoteHost: String

    private init(forward: PortForward, channel: Channel,
                 client: SSHClient, remoteHost: String) {
        self.forward = forward
        self.channel = channel
        self.client = client
        self.remoteHost = remoteHost
    }

    /// Takes the boxed client: `SSHClient` predates `Sendable`, and this hop
    /// leaves the main actor. See `SendableSSHClient`.
    static func start(forward: PortForward,
                      client: SendableSSHClient,
                      remoteHost: String) async throws -> LocalTunnel {
        let group = MultiThreadedEventLoopGroup.singleton
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            // Both ends read only when the other end has drained: a phone
            // loading a big asset must not buffer the whole thing in memory.
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelInitializer { local in
                local.eventLoop.makeSucceededVoidFuture()
            }
        // Loopback only, always. A forward puts someone else's service on this
        // device; binding 0.0.0.0 would put it on whatever Wi-Fi the phone is
        // joined to, which is nobody's idea of what tapping a link does.
        let server = try await bootstrap.bind(host: "127.0.0.1", port: forward.localPort).get()

        let tunnel = LocalTunnel(forward: forward, channel: server,
                                 client: client.client, remoteHost: remoteHost)
        // Accepted connections arrive as child channels; each gets its own SSH
        // channel. Doing this after bind keeps the initializer synchronous.
        server.pipeline.addHandler(AcceptHandler { [tunnel] local in
            Task { await tunnel.splice(local: local) }
        }, position: .last).whenFailure { _ in }
        return tunnel
    }

    fileprivate func splice(local: Channel) async {
        let remotePort = forward.remotePort
        do {
            // `originatorAddress` is required by the protocol and is only ever
            // informational to the server; loopback is the honest answer.
            let origin = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
            let remote = try await client.createDirectTCPIPChannel(
                using: SSHChannelType.DirectTCPIP(
                    targetHost: remoteHost,
                    targetPort: remotePort,
                    originatorAddress: origin)
            ) { channel in
                channel.setOption(ChannelOptions.autoRead, value: false)
            }
            try await GlueHandler.pair(local, remote)
        } catch {
            // Almost always "connection refused over there" — the dev server is
            // restarting. The tab's reload button is the answer, and the panel
            // says so; nothing to do here but drop this connection.
            log.debug("direct-tcpip failed: \(String(describing: error), privacy: .public)")
            local.close(promise: nil)
        }
    }

    func stop() {
        channel.close(promise: nil)
    }
}

/// Hands each accepted child channel to a closure.
private final class AcceptHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Channel

    private let onAccept: @Sendable (Channel) -> Void
    init(_ onAccept: @escaping @Sendable (Channel) -> Void) { self.onAccept = onAccept }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        onAccept(unwrapInboundIn(data))
    }
}

/// Copies bytes between two channels, each reading only once the other has
/// taken what it was given.
private final class GlueHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private var partner: Channel?

    static func pair(_ a: Channel, _ b: Channel) async throws {
        let ga = GlueHandler(), gb = GlueHandler()
        ga.partner = b
        gb.partner = a
        try await a.pipeline.addHandler(ga)
        try await b.pipeline.addHandler(gb)
        a.read()
        b.read()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        guard let partner else { context.close(promise: nil); return }
        let me = context.channel
        partner.writeAndFlush(buffer).whenComplete { _ in me.read() }
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.close(promise: nil)
        partner = nil
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        partner?.close(promise: nil)
        partner = nil
        context.close(promise: nil)
    }
}
