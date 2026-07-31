import Foundation

/// BentoCLI shells out to the `bento` and `bento-daemon` binaries. We do not
/// re-implement the daemon's Unix-socket RPC in Swift; the CLI already does
/// that with JSON output, and using it dogfoods both code paths.
@MainActor
final class BentoCLI: ObservableObject {
    /// Default relay URL — the production Cloudflare-hosted relay. Used on
    /// first launch when the user hasn't configured anything in Settings.
    static let defaultRelayURL = "https://bento-relay.styleshang.workers.dev"

    /// Resolve a binary path. Search order:
    ///   1. $BENTO_BIN_DIR (used during development)
    ///   2. Sibling of the running .app's executable (production install)
    ///   3. /Users/$USER/code/speakterm/desktop/bin (dev fallback)
    ///   4. /opt/homebrew/bin, /usr/local/bin (Homebrew defaults)
    func locate(_ name: String) -> URL? {
        let candidates = candidateDirs()
        for dir in candidates {
            let url = dir.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private func candidateDirs() -> [URL] {
        var dirs: [URL] = []
        if let env = ProcessInfo.processInfo.environment["BENTO_BIN_DIR"] {
            dirs.append(URL(fileURLWithPath: env))
        }
        // Bundled Go binaries live in Contents/MacOS/helpers/ (not
        // Contents/MacOS/ directly) to avoid an APFS case-insensitive
        // collision between the Swift `Bento` executable and the Go `bento`
        // CLI in the same directory.
        let macOS = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS")
        dirs.append(macOS.appendingPathComponent("helpers"))
        dirs.append(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser
        dirs.append(home.appendingPathComponent("code/speakterm/desktop/bin"))
        dirs.append(URL(fileURLWithPath: "/opt/homebrew/bin"))
        dirs.append(URL(fileURLWithPath: "/usr/local/bin"))
        return dirs
    }

    // MARK: - subcommands

    /// Fetch /v1/status. Returns nil if the daemon isn't running.
    func status() async -> DaemonStatus? {
        let out = try? await runBento(["status"])
        guard let out, let data = out.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DaemonStatus.self, from: data)
    }

    /// Open a pairing window and return the 6-digit code.
    func pair() async throws -> String {
        let out = try await runBento(["pair"])
        // Output: "pairing code: 123456  (expires in 60s)"
        if let match = out.range(of: #"\b\d{6}\b"#, options: .regularExpression) {
            return String(out[match])
        }
        throw CLIError("could not parse pairing code from: \(out)")
    }

    /// List paired devices. The CLI emits text rows like
    /// "dev-abc12345  alice-iphone  paired=2026-05-27T..."; we parse the
    /// first two columns. (PairedAt/fingerprint aren't exposed by the text
    /// output today.)
    func devices() async throws -> [PairedDevice] {
        let out = try await runBento(["devices"])
        if out.contains("no paired devices") {
            return []
        }
        var devices: [PairedDevice] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 1 else { continue }
            devices.append(PairedDevice(
                deviceID: parts[0],
                label: parts.count >= 2 ? parts[1] : nil,
                pairedAt: 0,
                keyFingerprint: ""
            ))
        }
        return devices
    }

    /// Revoke a device by id.
    func revoke(_ deviceID: String) async throws {
        _ = try await runBento(["devices", "revoke", deviceID])
    }

    /// Start the daemon (background). Optionally override relay URL.
    ///
    /// If `relay` is nil and no relay URL is already in ~/.bento/config.json,
    /// we write the default before starting. This is what makes a fresh
    /// install "just work" — the user double-clicks the app and we connect
    /// to the hosted relay without any setup step.
    func startDaemon(relay: String?) async throws {
        if let relay {
            try writeRelayURL(relay)
        } else if currentRelayURL().isEmpty {
            try writeRelayURL(Self.defaultRelayURL)
        }
        _ = try await runBento(["tunnel", "start"])
    }

    /// Read the relay_url field from the daemon's config.json, or "" if missing.
    func currentRelayURL() -> String {
        configValue("relay_url")
    }

    /// Read the daemon_id from config.json. Surfaced in the pairing UI so
    /// the user can copy it into the iOS app.
    func currentDaemonID() -> String {
        configValue("daemon_id")
    }

    private func configValue(_ key: String) -> String {
        guard let data = try? Data(contentsOf: configPath()),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = obj[key] as? String else {
            return ""
        }
        return value
    }

    /// configPath mirrors the Go-side state.Home(): honor $BENTO_HOME if set,
    /// otherwise fall back to $HOME/.bento. Without this, Swift writes to one
    /// path and the daemon reads from another whenever $BENTO_HOME is set.
    private func configPath() -> URL {
        bentoHomeDir().appendingPathComponent("config.json")
    }

    private func bentoHomeDir() -> URL {
        if let env = ProcessInfo.processInfo.environment["BENTO_HOME"] {
            return URL(fileURLWithPath: env)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".bento")
    }

    /// Stop the daemon.
    func stopDaemon() async throws {
        _ = try await runBento(["tunnel", "stop"])
    }

    // MARK: - low-level

    private func runBento(_ args: [String]) async throws -> String {
        guard let bento = locate("bento") else {
            throw CLIError("`bento` binary not found in PATH or known locations")
        }
        return try await run(bento, args)
    }

    private func run(_ exe: URL, _ args: [String]) async throws -> String {
        let proc = Process()
        proc.executableURL = exe
        proc.arguments = args
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            proc.terminationHandler = { p in
                let outData = (try? out.fileHandleForReading.readToEnd()) ?? Data()
                let errData = (try? err.fileHandleForReading.readToEnd()) ?? Data()
                let outStr = String(decoding: outData, as: UTF8.self)
                let errStr = String(decoding: errData, as: UTF8.self)
                if p.terminationStatus == 0 {
                    cont.resume(returning: outStr)
                } else {
                    let msg = errStr.trimmingCharacters(in: .whitespacesAndNewlines)
                    cont.resume(throwing: CLIError(msg.isEmpty ? "exit \(p.terminationStatus)" : msg))
                }
            }
            do {
                try proc.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    private func writeRelayURL(_ url: String) throws {
        let dir = bentoHomeDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = configPath()
        // Read-modify-write so we preserve the daemon_id assigned on first run.
        var cfg: [String: Any] = [:]
        if let data = try? Data(contentsOf: path),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            cfg = existing
        }
        cfg["relay_url"] = url
        let data = try JSONSerialization.data(withJSONObject: cfg, options: .prettyPrinted)
        try data.write(to: path, options: .atomic)
    }
}

struct CLIError: LocalizedError {
    let message: String
    init(_ m: String) { self.message = m }
    var errorDescription: String? { message }
}
