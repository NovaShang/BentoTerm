import Foundation

/// One-shot (non-realtime) transcription of a COMPLETE utterance via OpenAI's
/// `/v1/audio/transcriptions` (`gpt-4o-transcribe`) — higher accuracy than the
/// streaming realtime model because it sees the whole clip at once. Backs the
/// right-swipe "transcribe → preview → edit → send" flow.
///
/// Bring-your-own-key, like the realtime engines it mirrors: the user's own
/// `openai_api_key` / `dashscope_api_key` posts straight to the provider. With
/// no key there is nowhere to send the clip, so this returns nil and the caller
/// keeps whatever the realtime engine already streamed.
public final class BatchTranscriptionService: @unchecked Sendable {
    public static let shared = BatchTranscriptionService()
    private let session = URLSession(configuration: .default)

    private static let directURL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    private static let model = "gpt-4o-transcribe"
    // Qwen batch (DashScope multimodal) — used when the Qwen engine is selected so
    // batch re-transcription matches the realtime engine instead of falling back
    // to OpenAI.
    private static let qwenDirectURL = URL(string: "https://dashscope-intl.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation")!

    public init() {}

    /// Transcribe 16-bit mono PCM at `sampleRate`. `language` is an optional
    /// ISO-639-1 hint ("" = auto); `corpus` is Qwen context-biasing text (ignored
    /// by the OpenAI path). Routes to the engine the user has selected so switching
    /// to Qwen is end-to-end Qwen. Returns the text, or nil on empty/failure.
    public func transcribe(pcm: Data, sampleRate: Double, language: String = "", corpus: String = "") async -> String? {
        guard !pcm.isEmpty else { return nil }
        let wav = Self.wav(pcm: pcm, sampleRate: sampleRate)
        if SpeechEngineKind.current() == .qwen {
            return await transcribeQwen(wav: wav, language: language, corpus: corpus)
        }
        return await transcribeOpenAI(wav: wav, language: language)
    }

    /// OpenAI `gpt-4o-transcribe` batch — multipart form straight to OpenAI on
    /// the user's key.
    private func transcribeOpenAI(wav: Data, language: String) async -> String? {
        let key = SpeechEngineKind.openai.apiKey
        guard !key.isEmpty else {
            dlog("[batch-asr] no OpenAI key — skipping batch refinement")
            return nil
        }

        let boundary = "bento-\(UUID().uuidString)"
        var request = URLRequest(url: Self.directURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipart(wav: wav, language: language, boundary: boundary)
        request.timeoutInterval = 30

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                dlog("[batch-asr] HTTP \(code): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["text"] as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            dlog("[batch-asr] error: \(error)")
            return nil
        }
    }

    /// Qwen `qwen3-asr-flash` batch via DashScope multimodal ASR — the native
    /// DashScope request, posted directly on the user's key.
    private func transcribeQwen(wav: Data, language: String, corpus: String) async -> String? {
        let key = SpeechEngineKind.qwen.apiKey
        guard !key.isEmpty else {
            dlog("[batch-asr] no DashScope key — skipping batch refinement")
            return nil
        }
        let b64 = wav.base64EncodedString()

        var request = URLRequest(url: Self.qwenDirectURL)
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
        request.timeoutInterval = 30

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                dlog("[batch-asr] qwen HTTP \(code): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let trimmed = (Self.parseDashScope(json) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            dlog("[batch-asr] qwen error: \(error)")
            return nil
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
