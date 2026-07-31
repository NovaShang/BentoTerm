import Foundation

/// Streaming ASR client for Alibaba DashScope's Qwen realtime model
/// (`qwen3-asr-flash-realtime`) — best-in-class 中文 and 中英混说 (code-switching)
/// accuracy. Pure Foundation, shared by iOS + macOS.
///
/// Wire protocol is OpenAI-Realtime-compatible but a slightly different dialect
/// than OpenAI's GA transcription API, so it lives in its own service:
///   • session config is `input_audio_format`/`sample_rate`/`input_audio_transcription`
///     at the session root (not the GA `type: transcription` envelope),
///   • audio is 16 kHz PCM (OpenAI wants 24 kHz),
///   • interims arrive as `...text` with a rolling-window `stash` (NOT the full
///     running transcript — it resets mid-utterance), so only the post-commit
///     `...completed` `transcript` is authoritative. `VoiceSession` therefore
///     always commits and waits for the final rather than sending an interim.
///
/// Auth: bring-your-own-key only — a DashScope `apiKey` connects straight to
/// DashScope on the user's own quota. Bento operates no server to proxy through.
public final class QwenRealtimeASRService: NSObject, @unchecked Sendable, RealtimeASR {
    public enum ASRError: LocalizedError {
        case missingCredentials
        case unexpectedInitialMessage(String)
        case server(String)

        public var errorDescription: String? {
            switch self {
            case .missingCredentials:
                return SpeechEngineKind.qwen.unavailableReason
                    ?? "DashScope API key not set."
            case .unexpectedInitialMessage(let s):
                return "Qwen Realtime handshake failed: \(s)"
            case .server(let s):
                return s
            }
        }
    }

    /// DashScope wants 16 kHz mono PCM.
    public static let requiredSampleRate: Double = 16000
    public var sampleRate: Double { Self.requiredSampleRate }

    /// DashScope endpoint (international region).
    public static let directEndpoint = URL(string: "wss://dashscope-intl.aliyuncs.com/api-ws/v1/realtime")!
    public static let model = "qwen3-asr-flash-realtime"

    private let apiKey: String
    private let language: String
    private let corpus: String

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var readerTask: Task<Void, Never>?
    private var isOpen = false

    public var onInterim: (@Sendable (String) -> Void)?
    public var onFinal: (@Sendable (String) -> Void)?
    public var onCompleted: (@Sendable () -> Void)?
    public var onError: (@Sendable (Error) -> Void)?

    /// - Parameters:
    ///   - apiKey: the user's DashScope key. Empty is a hard failure — there is
    ///     no proxy to fall back to.
    ///   - language: optional hint ("zh"/"en"/…); empty = auto-detect (best for
    ///     code-switching).
    ///   - corpus: context-biasing background text (entity names, on-screen terms).
    ///     The model reads it and biases toward the entities within — empty = none.
    public init(apiKey: String = "", language: String = "", corpus: String = "") {
        self.apiKey = apiKey
        self.language = language
        self.corpus = corpus
    }

    public func start() async throws {
        // A couple of quick retries on a fresh connection smooth over a stale
        // pooled socket (-1005) or a flaky handshake, same as the OpenAI path.
        var lastError: Error?
        var attempt = 0
        while attempt < 3 {
            attempt += 1
            do {
                try await connectOnce()
                readerTask = Task { [weak self] in await self?.readLoop() }
                return
            } catch {
                await teardownConnection()
                lastError = error
                guard Self.isTransient(error) else { throw error }
                dlog("[voice] qwen connect transient (\(error.localizedDescription)) — retry \(attempt + 1)/3")
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        throw lastError ?? ASRError.missingCredentials
    }

    /// One connect attempt: open WSS → session.created → configure transcription.
    private func connectOnce() async throws {
        guard !apiKey.isEmpty else { throw ASRError.missingCredentials }
        // Straight to DashScope with the user's key + the model in the query.
        var comps = URLComponents(url: Self.directEndpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "model", value: Self.model)]
        let endpoint = comps.url!
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        let urlSession = URLSession(configuration: cfg)
        let wsTask = urlSession.webSocketTask(with: request)
        self.session = urlSession
        self.task = wsTask
        wsTask.resume()

        let firstMsg = try await receiveText(task: wsTask)
        guard let json = parseJSON(firstMsg),
              json["type"] as? String == "session.created" else {
            throw ASRError.unexpectedInitialMessage(firstMsg)
        }

        // DashScope dialect: session-root audio config, manual commit (no VAD).
        var transcription: [String: Any] = [:]
        if !language.isEmpty { transcription["language"] = language }
        // Context biasing: the model reads `corpus.text` and biases toward the
        // entities in it. Over ~20k chars the session.update is silently dropped,
        // so callers must cap; we assume they have.
        if !corpus.isEmpty { transcription["corpus"] = ["text": corpus] }
        let config: [String: Any] = [
            "event_id": "evt_\(UUID().uuidString.prefix(8))",
            "type": "session.update",
            "session": [
                "input_audio_format": "pcm",
                "sample_rate": Int(Self.requiredSampleRate),
                "input_audio_transcription": transcription,
                "turn_detection": NSNull(),
            ] as [String: Any],
        ]
        try await sendJSON(config, on: wsTask)
        isOpen = true
    }

    private func teardownConnection() async {
        task?.cancel(with: .abnormalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        isOpen = false
    }

    private static func isTransient(_ error: Error) -> Bool {
        if let u = error as? URLError {
            switch u.code {
            case .networkConnectionLost, .timedOut, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed:
                return true
            default:
                return false
            }
        }
        if case ASRError.unexpectedInitialMessage = error { return true }
        return false
    }

    public func sendAudio(_ pcm: Data) async {
        guard isOpen, let task, !pcm.isEmpty else { return }
        let payload: [String: Any] = [
            "event_id": "evt_\(UUID().uuidString.prefix(8))",
            "type": "input_audio_buffer.append",
            "audio": pcm.base64EncodedString(),
        ]
        try? await sendJSON(payload, on: task)
    }

    /// Commit the buffered audio so DashScope transcribes it and emits
    /// `...completed`. Leaves the socket open + reader running so the final is
    /// processed (the caller waits for it, then calls `cancel()`).
    public func commit() async {
        guard isOpen, let task else { return }
        try? await sendJSON([
            "event_id": "evt_\(UUID().uuidString.prefix(8))",
            "type": "input_audio_buffer.commit",
        ], on: task)
    }

    public func cancel() async {
        isOpen = false
        // Best-effort graceful finish so DashScope closes the session cleanly.
        if let task { try? await sendJSON([
            "event_id": "evt_\(UUID().uuidString.prefix(8))",
            "type": "session.finish",
        ], on: task) }
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        readerTask?.cancel()
        readerTask = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func sendJSON(_ obj: [String: Any], on task: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: obj)
        guard let text = String(data: data, encoding: .utf8) else { return }
        try await task.send(.string(text))
    }

    private func parseJSON(_ s: String) -> [String: Any]? {
        guard let data = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func receiveText(task: URLSessionWebSocketTask) async throws -> String {
        let msg = try await task.receive()
        switch msg {
        case .string(let s): return s
        case .data(let d): return String(data: d, encoding: .utf8) ?? ""
        @unknown default: return ""
        }
    }

    private func readLoop() async {
        while isOpen, let task {
            do {
                let s = try await receiveText(task: task)
                guard let json = parseJSON(s),
                      let type = json["type"] as? String else { continue }
                switch type {
                case "conversation.item.input_audio_transcription.text":
                    // `text` is the committed, monotonically-growing prefix; `stash`
                    // is the volatile tail being recognized. Their concatenation is
                    // the clean running transcript — the committed part never jumps
                    // back, only the last few words wiggle (normal streaming feel).
                    // Using `stash` alone (as the load-survey did) makes each window
                    // REPLACE the line, because `stash` is a sliding window that
                    // resets as `text` absorbs it.
                    let committed = json["text"] as? String ?? ""
                    let tail = json["stash"] as? String ?? ""
                    let running = committed + tail
                    if !running.isEmpty { onInterim?(running) }
                case "conversation.item.input_audio_transcription.completed":
                    if let text = json["transcript"] as? String, !text.isEmpty {
                        onFinal?(text)
                    }
                    onCompleted?()
                case "error":
                    let info = (json["error"] as? [String: Any])?["message"] as? String
                        ?? "Qwen Realtime error"
                    onError?(ASRError.server(info))
                    return
                default:
                    break
                }
            } catch {
                if isOpen { onError?(error) }
                return
            }
        }
    }
}
