import Foundation
import BentoFoundationKit

/// One-shot (non-realtime) transcription of a COMPLETE utterance via OpenAI's
/// `/v1/audio/transcriptions` (`gpt-4o-transcribe`) — higher accuracy than the
/// streaming realtime model because it sees the whole clip at once. Backs the
/// right-swipe "transcribe → preview → edit → send" flow.
///
/// Zero-config by default: posts raw WAV to the bundled relay, which injects the
/// key and forces the model (same pattern as the ASR mint). If the user set their
/// own `openai_api_key`, posts the multipart form straight to OpenAI (BYOK).
public final class BatchTranscriptionService: @unchecked Sendable {
    public static let shared = BatchTranscriptionService()
    private let session = URLSession(configuration: .default)

    /// What a batch attempt produced. `refused` exists so a spent quota reaches
    /// the user as a sentence instead of as silence — every other failure is
    /// still just "nothing came back", which the caller already handles.
    public enum Outcome: Sendable, Equatable {
        case text(String)
        case empty
        case refused(RelayQuotaError)
    }

    private static let relayURL = URL(string: "https://relay.bentoai.dev/v1/audio/transcriptions")!
    private static let directURL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    private static let model = "gpt-4o-transcribe"
    // Qwen batch (DashScope multimodal) — used when the Qwen engine is selected so
    // batch re-transcription matches the realtime engine instead of falling back
    // to OpenAI. Relay normalizes the response to `{ text }`; direct is BYOK.
    private static let qwenRelayURL = URL(string: "https://relay.bentoai.dev/v1/asr/qwen/transcribe")!
    private static let qwenDirectURL = URL(string: "https://dashscope-intl.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation")!

    /// Mirrors the relay's `QUOTA_MAX_CLIP_SECONDS`. Kept as a client-side
    /// pre-check only — the relay is the one that enforces it.
    static let relayMaxClipSeconds: Double = 120

    /// True when the user brought a key for whichever engine is selected, so the
    /// request bypasses the relay entirely.
    private static var hasOwnKey: Bool {
        let key = SpeechEngineKind.current() == .qwen ? "dashscope_api_key" : "openai_api_key"
        return !(UserDefaults.standard.string(forKey: key) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public init() {}

    /// Transcribe 16-bit mono PCM at `sampleRate`. `language` is an optional
    /// ISO-639-1 hint ("" = auto); `corpus` is Qwen context-biasing text (ignored
    /// by the OpenAI path). Routes to the engine the user has selected so switching
    /// to Qwen is end-to-end Qwen. Returns the text, or nil on empty/failure.
    public func transcribe(pcm: Data, sampleRate: Double, language: String = "", corpus: String = "") async -> String? {
        switch await outcome(pcm: pcm, sampleRate: sampleRate, language: language, corpus: corpus) {
        case .text(let t): return t
        case .empty, .refused: return nil
        }
    }

    /// Same call, but able to say the relay refused it (daily free quota spent).
    public func outcome(pcm: Data, sampleRate: Double, language: String = "", corpus: String = "") async -> Outcome {
        guard !pcm.isEmpty else { return .empty }
        // The relay refuses clips past its per-call ceiling. Catching that here
        // saves uploading megabytes of WAV to be told no — BYOK skips the check
        // because it isn't the relay's audio to cap.
        if !Self.hasOwnKey, Double(pcm.count) / (sampleRate * 2) > Self.relayMaxClipSeconds {
            return .refused(RelayQuotaError(reason: .clipTooLong))
        }
        let wav = Self.wav(pcm: pcm, sampleRate: sampleRate)
        if SpeechEngineKind.current() == .qwen {
            return await transcribeQwen(wav: wav, language: language, corpus: corpus)
        }
        return await transcribeOpenAI(wav: wav, language: language)
    }

    /// OpenAI `gpt-4o-transcribe` batch (relay zero-config, or BYOK direct).
    private func transcribeOpenAI(wav: Data, language: String) async -> Outcome {
        let key = (UserDefaults.standard.string(forKey: "openai_api_key") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var request: URLRequest
        if key.isEmpty {
            // Zero-config: raw WAV to the relay; it builds the multipart + injects key.
            var comps = URLComponents(url: Self.relayURL, resolvingAgainstBaseURL: false)!
            if !language.isEmpty { comps.queryItems = [URLQueryItem(name: "language", value: language)] }
            request = URLRequest(url: comps.url!)
            request.httpMethod = "POST"
            request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
            RelayInstall.stamp(&request)
            request.httpBody = wav
        } else {
            // BYOK: multipart form straight to OpenAI.
            let boundary = "bento-\(UUID().uuidString)"
            request = URLRequest(url: Self.directURL)
            request.httpMethod = "POST"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.multipart(wav: wav, language: language, boundary: boundary)
        }
        request.timeoutInterval = 30

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                dlog("[batch-asr] HTTP \(code): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
                if let refusal = Self.refusal(status: code, body: data) { return .refused(refusal) }
                return .empty
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["text"] as? String else { return .empty }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .empty : .text(trimmed)
        } catch {
            dlog("[batch-asr] error: \(error)")
            return .empty
        }
    }

    /// Read a relay quota refusal out of a non-2xx response. 429 is the quota
    /// gate; 413 is a clip the relay won't accept at any quota.
    static func refusal(status: Int, body: Data) -> RelayQuotaError? {
        guard status == 429 || status == 413 else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return RelayQuotaError.from(payload: json)
    }

    /// Qwen `qwen3-asr-flash` batch via DashScope multimodal ASR. Zero-config posts
    /// `{ audio, language?, corpus? }` to the relay (which injects the key and
    /// returns `{ text }`); BYOK posts the native DashScope request directly.
    private func transcribeQwen(wav: Data, language: String, corpus: String) async -> Outcome {
        let b64 = wav.base64EncodedString()
        let key = (UserDefaults.standard.string(forKey: "dashscope_api_key") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let direct = !key.isEmpty

        var request: URLRequest
        if direct {
            request = URLRequest(url: Self.qwenDirectURL)
            request.httpMethod = "POST"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var asrOptions: [String: Any] = ["enable_lid": true, "enable_itn": false]
            if !language.isEmpty { asrOptions["language"] = language }
            let payload: [String: Any] = [
                "model": "qwen3-asr-flash",
                "input": ["messages": [
                    ["role": "system", "content": [["text": corpus]]],
                    ["role": "user", "content": [["audio": "data:audio/wav;base64,\(b64)"]]],
                ]],
                "parameters": ["asr_options": asrOptions],
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        } else {
            request = URLRequest(url: Self.qwenRelayURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            RelayInstall.stamp(&request)
            var payload: [String: Any] = ["audio": b64]
            if !language.isEmpty { payload["language"] = language }
            if !corpus.isEmpty { payload["corpus"] = corpus }
            request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        }
        request.timeoutInterval = 30

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                dlog("[batch-asr] qwen HTTP \(code): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
                if let refusal = Self.refusal(status: code, body: data) { return .refused(refusal) }
                return .empty
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .empty }
            // Relay returns { text }; direct returns the native DashScope shape.
            let text = direct ? Self.parseDashScope(json) : (json["text"] as? String)
            let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .empty : .text(trimmed)
        } catch {
            dlog("[batch-asr] qwen error: \(error)")
            return .empty
        }
    }

    /// Pull the transcript from a native DashScope multimodal response:
    /// `output.choices[0].message.content[<text part>].text`.
    private static func parseDashScope(_ json: [String: Any]) -> String? {
        guard let output = json["output"] as? [String: Any],
              let choices = output["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return nil }
        for part in content { if let t = part["text"] as? String { return t } }
        return nil
    }

    /// Wrap raw little-endian 16-bit mono PCM in a 44-byte WAV header.
    static func wav(pcm: Data, sampleRate: Double) -> Data {
        let rate = UInt32(sampleRate)
        let channels: UInt16 = 1
        let bits: UInt16 = 16
        let byteRate = rate * UInt32(channels) * UInt32(bits / 8)
        let blockAlign = channels * (bits / 8)
        let dataLen = UInt32(pcm.count)
        func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func u16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

        var h = Data()
        h.append("RIFF".data(using: .ascii)!)
        h.append(u32(36 + dataLen))
        h.append("WAVE".data(using: .ascii)!)
        h.append("fmt ".data(using: .ascii)!)
        h.append(u32(16))            // PCM fmt-chunk size
        h.append(u16(1))             // format = PCM
        h.append(u16(channels))
        h.append(u32(rate))
        h.append(u32(byteRate))
        h.append(u16(blockAlign))
        h.append(u16(bits))
        h.append("data".data(using: .ascii)!)
        h.append(u32(dataLen))
        h.append(pcm)
        return h
    }

    private static func multipart(wav: Data, language: String, boundary: String) -> Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n".data(using: .utf8)!)
        field("model", Self.model)
        field("response_format", "json")
        if !language.isEmpty { field("language", language) }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }
}
