import Foundation
import BentoTerminalCore
import Citadel
import Crypto
import NIO
import NIOSSH
import os

/// The connection-state type now lives in BentoTerminalCore (shared with the
/// cross-platform TerminalViewModel). Kept as a typealias so existing app call
/// sites (`SSHConnectionState`) are unchanged.
typealias SSHConnectionState = TerminalConnectionState

enum SSHError: LocalizedError {
    case notConnected
    case invalidKeyFormat

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to server."
        case .invalidKeyFormat: return "Invalid SSH key format."
        }
    }
}

/// Wrapper to make TTYStdinWriter usable across concurrency boundaries.
/// TTYStdinWriter is a struct containing a NIO Channel, which is thread-safe.
struct SendableStdinWriter: @unchecked Sendable {
    let writer: TTYStdinWriter
}

/// Thread-safe mutable state for SSHService
private struct SSHMutableState: Sendable {
    var state: SSHConnectionState = .disconnected
    var stdinWriter: SendableStdinWriter?
}

/// Manages an SSH connection and interactive shell session.
///
/// SSHService is transport-agnostic at its public surface — callers always
/// say `connect(host:)`, `startShell`, `write`, etc. Internally we branch on
/// `host.transport`:
///   * `.directTCP` → Citadel/NIOSSH TCP, the original path
///   * `.relay`     → BentoRelayClient (SSH-over-WSS through Cloudflare)
///
/// All other state (onDataReceived, connection phase, etc.) is shared.
final class SSHService: @unchecked Sendable, TerminalTransport {
    private let mutableState = OSAllocatedUnfairLock(initialState: SSHMutableState())
    private var client: SSHClient?
    private var sessionTask: Task<Void, Never>?

    /// Set when the active host uses the Bento relay transport. Mutually
    /// exclusive with `client` — only one is non-nil at a time.
    /// `nonisolated(unsafe)` because we only mutate it from MainActor and
    /// only call its methods from MainActor; the bare reference check is
    /// safe to read elsewhere (BentoRelayClient itself stays @MainActor).
    nonisolated(unsafe) private var relayClient: BentoRelayClient?

    var state: SSHConnectionState {
        mutableState.withLock { $0.state }
    }

    /// Called on each chunk of terminal output
    var onDataReceived: (@Sendable (Data) -> Void)?
    var onStateChanged: (@Sendable (SSHConnectionState) -> Void)?

    /// Publish a connection-state change: store it, then notify the observer.
    private func transition(to s: SSHConnectionState) {
        mutableState.withLock { $0.state = s }
        onStateChanged?(s)
    }

    // MARK: - Connect

    func connect(host: Host) async {
        transition(to: .connecting)

        // Relay transport detours into BentoRelayClient — no Citadel.
        if case .relay(let daemonID, let hostFingerprint, let deviceID) = host.transport {
            await connectRelay(
                daemonID: daemonID,
                hostFingerprint: hostFingerprint,
                deviceID: deviceID,
                deviceKeyLabel: relayKeyLabel(host: host),
                daemonUUID: host.id
            )
            return
        }

        do {
            let authentication: SSHAuthenticationMethod

            switch host.authMethod {
            case .password:
                let password = try KeychainService.shared.loadPassword(for: host.id.uuidString)
                authentication = .passwordBased(username: host.username, password: password)
            case .privateKey(let keyLabel):
                let keyData = try KeychainService.shared.loadPrivateKey(label: keyLabel)
                let ed25519Key = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
                authentication = .ed25519(username: host.username, privateKey: ed25519Key)
            }

            let sshClient = try await SSHClient.connect(
                host: host.hostname,
                port: Int(host.port),
                authenticationMethod: authentication,
                hostKeyValidator: .acceptAnything(),
                reconnect: .never
            )

            self.client = sshClient
            mutableState.withLock { $0.state = .connected }
            dlog("SSH connected successfully")
            Task { @MainActor in TelemetryService.shared.record(.sshDirectConnected) }

            // Identify this client so the disconnect callback can tell whether
            // it's still the active client. Otherwise an old client's delayed
            // onDisconnect (after the user popped + we reconnected) would
            // clobber the new client's .connected state, leaving the UI
            // stuck on "Connecting…". `ObjectIdentifier` is Sendable, so the
            // capture survives strict concurrency.
            let clientID = ObjectIdentifier(sshClient)
            sshClient.onDisconnect { [weak self] in
                guard let self,
                      let current = self.client,
                      ObjectIdentifier(current) == clientID else { return }
                self.mutableState.withLock {
                    $0.state = .disconnected
                    $0.stdinWriter = nil
                }
                self.onStateChanged?(.disconnected)
            }

            onStateChanged?(.connected)
        } catch {
            dlog("SSH connection error: \(error)")
            transition(to: .failed(error.localizedDescription))
        }
    }

    // MARK: - Relay path

    /// Extract the device-key Keychain label from `host.authMethod`. The
    /// synthetic Host built by `Host.fromRelayDaemon` always uses
    /// `.privateKey(keyLabel:)`, so this is just a typed unwrap.
    private func relayKeyLabel(host: Host) -> String {
        if case .privateKey(let label) = host.authMethod { return label }
        return ""
    }

    @MainActor
    private func connectRelay(daemonID: String, hostFingerprint: String, deviceID: String, deviceKeyLabel: String, daemonUUID: UUID) async {
        // Reconnect reuses this SSHService, so a previous relay client may still
        // be set. Tear it down NOW — synchronously, on the MainActor, with its
        // callbacks detached first — before dialing a fresh one. Detaching is
        // critical: `disconnect()` cancels the read pump, whose `ws.receive()`
        // then throws and routes through `fail()` → `onTerminated(.failed)`. If
        // that stale failure reached the view model it would spuriously
        // re-trigger reconnect, and since each reconnect tears down the prior
        // client the app would loop "Reconnecting…" forever. Doing it here
        // (not via disconnect()'s deferred Task) also removes any race against
        // the new client we build below.
        if let old = relayClient {
            old.onDataReceived = nil
            old.onTerminated = nil
            old.disconnect()
            relayClient = nil
        }

        // BentoRelayClient takes a full RelayDaemon for ergonomics, but only
        // these five fields are required to dial — the rest are pairing
        // metadata that isn't used after the device key was installed.
        let stub = RelayDaemon(
            id: daemonUUID,
            daemonID: daemonID,
            label: "",
            hostFingerprint: hostFingerprint,
            deviceKeyLabel: deviceKeyLabel,
            deviceID: deviceID
        )
        let client = BentoRelayClient(daemon: stub)
        let onData = self.onDataReceived
        client.onDataReceived = { data in onData?(data) }
        client.onTerminated = { [weak self] err in
            guard let self else { return }
            let s: SSHConnectionState = err.map { .failed($0.localizedDescription) } ?? .disconnected
            self.transition(to: s)
        }
        do {
            try await client.connect()
            self.relayClient = client
            transition(to: .connected)
            dlog("Relay SSH connected (daemon=\(daemonID.prefix(8))…)")
        } catch {
            transition(to: .failed(error.localizedDescription))
            dlog("Relay SSH connect failed: \(error)")
        }
    }

    // MARK: - Shell

    func startShell(cols: Int, rows: Int) {
        // Relay branch: drive BentoRelayClient.startShell on the MainActor.
        if let relayClient {
            Task { @MainActor in
                do {
                    try await relayClient.startShell(cols: UInt16(cols), rows: UInt16(rows))
                } catch {
                    self.transition(to: .failed(error.localizedDescription))
                }
            }
            return
        }
        guard let client = self.client else { return }

        let onData = self.onDataReceived
        let onState = self.onStateChanged
        let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )

        // Capture the SSHClient instance so the catch below can tell whether
        // the failure belongs to *our* session or to an already-superseded
        // one (e.g. user popped back to the sessions list, which called
        // disconnect() and started a fresh client). Without this, the
        // closing channel's tail error stomps the new client's .connected
        // state and the UI surfaces "NIOError.ChannelError error 6".
        let runningClient = client
        sessionTask = Task { [weak self] in
            do {
                try await client.withPTY(ptyRequest) { inbound, outbound in
                    let sendableWriter = SendableStdinWriter(writer: outbound)
                    self?.mutableState.withLock { $0.stdinWriter = sendableWriter }

                    for try await chunk in inbound {
                        switch chunk {
                        case .stdout(let buffer):
                            let data = Data(buffer.readableBytesView)
                            onData?(data)
                        case .stderr(let buffer):
                            let data = Data(buffer.readableBytesView)
                            onData?(data)
                        }
                    }
                }
            } catch {
                // Suppress the error if the service has moved on to a new
                // client (or was explicitly disconnected) — in that case we
                // don't want to clobber the new state with stale failure.
                let stillCurrent = self?.client === runningClient
                guard stillCurrent else { return }

                let errorState = SSHConnectionState.failed(error.localizedDescription)
                self?.mutableState.withLock {
                    $0.state = errorState
                    $0.stdinWriter = nil
                }
                onState?(errorState)
            }
        }
    }

    // MARK: - Input

    func write(_ data: Data) {
        // Relay branch — bytes go straight to BentoRelayClient (MainActor).
        if relayClient != nil {
            let bytes = data
            Task { @MainActor in self.relayClient?.write(bytes) }
            return
        }
        guard let wrapper = mutableState.withLock({ $0.stdinWriter }) else { return }

        Task {
            var buffer = ByteBufferAllocator().buffer(capacity: data.count)
            buffer.writeBytes(data)
            try? await wrapper.writer.write(buffer)
        }
    }

    func write(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        write(data)
    }

    func resize(cols: Int, rows: Int) {
        if relayClient != nil {
            Task { @MainActor in
                try? await self.relayClient?.resize(cols: UInt16(cols), rows: UInt16(rows))
            }
            return
        }
        guard let wrapper = mutableState.withLock({ $0.stdinWriter }) else { return }

        Task {
            try? await wrapper.writer.changeSize(
                cols: cols,
                rows: rows,
                pixelWidth: 0,
                pixelHeight: 0
            )
        }
    }

    // MARK: - Path-preview file source

    /// Cached per underlying connection so repeated previews reuse one SFTP
    /// channel / source object. Rebuilt after a reconnect (the connection
    /// object's identity changes).
    private var fileSource: (source: any FilePreviewSource, owner: ObjectIdentifier)?

    /// A file source riding the CURRENT connection, or nil while disconnected.
    @MainActor
    func filePreviewSource() -> (any FilePreviewSource)? {
        if let relayClient {
            let id = ObjectIdentifier(relayClient)
            if let cached = fileSource, cached.owner == id { return cached.source }
            let source = RelayFileSource(client: relayClient)
            fileSource = (source, id)
            return source
        }
        if let client {
            let id = ObjectIdentifier(client)
            if let cached = fileSource, cached.owner == id { return cached.source }
            let source = CitadelSFTPFileSource(client: client)
            fileSource = (source, id)
            return source
        }
        return nil
    }

    // MARK: - Liveness probe

    /// Relay: real WS ping round-trip. Direct TCP: trust the reported state —
    /// Citadel surfaces channel death via onDisconnect, and there is no cheap
    /// application-level ping on that path.
    func probeLiveness() async -> Bool {
        if relayClient != nil {
            let rc = await MainActor.run { self.relayClient }
            guard let rc else { return false }
            return await rc.probe()
        }
        if case .connected = state { return true }
        return false
    }

    // MARK: - Disconnect

    func disconnect() {
        sessionTask?.cancel()
        sessionTask = nil

        mutableState.withLock {
            $0.stdinWriter = nil
            $0.state = .disconnected
        }

        let clientToClose = client
        client = nil

        if let clientToClose {
            Task {
                try? await clientToClose.close()
            }
        }

        // Relay branch shutdown. Capture the instance to tear down NOW (like
        // the direct `clientToClose` above) and only nil `relayClient` if it's
        // still that same instance when the deferred close runs. A reconnect
        // calls disconnect() then immediately connect() (which assigns a NEW
        // relayClient); without the identity guard this deferred teardown would
        // disconnect/nil the fresh client, wedging the new connection — the
        // handshake never completes and the UI spins on "Reconnecting…" forever.
        let relayToClose = relayClient
        Task { @MainActor in
            relayToClose?.disconnect()
            if self.relayClient === relayToClose { self.relayClient = nil }
        }

        onStateChanged?(.disconnected)
    }
}
