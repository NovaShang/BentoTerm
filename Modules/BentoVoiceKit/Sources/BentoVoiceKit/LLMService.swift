import Foundation
import BentoFoundationKit

/// Translates a natural-language utterance into a single shell command via an
/// OpenAI-compatible chat endpoint. Zero-config by default — routes through the
/// bundled relay, which injects the key server-side (same posture as the ASR
/// relay). BYOK is optional: set a key to talk to OpenAI (or any compatible
/// endpoint) directly. Pure Foundation — shared iOS + macOS.
public final class LLMService: @unchecked Sendable {
    public static let shared = LLMService()

    private let session = URLSession(configuration: .default)

    /// The bundled relay's chat endpoint. Mirrors `BatchTranscriptionService`'s
    /// zero-config ASR relay: the client sends NO key; the Worker injects
    /// `OPENAI_API_KEY` and forces a cheap, capped model server-side.
    private static let relayEndpoint = URL(string: "https://relay.bentoai.dev/v1/chat/completions")!

    /// Enabled = the feature runs. It no longer needs a key: with none set we use
    /// the relay, so voice→shell works out of the box. When off, `convertTo…`
    /// falls back to inserting the raw transcript.
    public var isConfigured: Bool { enabled }

    private var enabled: Bool {
        if UserDefaults.standard.object(forKey: "llm_enabled") == nil { return true }
        return UserDefaults.standard.bool(forKey: "llm_enabled")
    }

    private var apiKey: String {
        UserDefaults.standard.string(forKey: "llm_api_key") ?? ""
    }

    /// BYOK when the user supplied their own key — then we hit OpenAI (or their
    /// custom endpoint) directly with it. Otherwise we route through the relay.
    private var usesBYOK: Bool { !apiKey.isEmpty }

    private var endpoint: URL {
        guard usesBYOK else { return Self.relayEndpoint }
        let urlStr = UserDefaults.standard.string(forKey: "llm_endpoint") ?? defaultEndpoint
        return URL(string: urlStr) ?? URL(string: defaultEndpoint)!
    }

    private var model: String {
        let m = UserDefaults.standard.string(forKey: "llm_model") ?? ""
        return m.isEmpty ? "gpt-4o-mini" : m
    }

    private let defaultEndpoint = "https://api.openai.com/v1/chat/completions"

    /// Convert natural language to a shell command. Returns the original
    /// transcript on any failure (or when disabled).
    public func convertToShellCommand(transcript: String, context: String) async -> String {
        guard isConfigured else { return transcript }

        let system = """
        You convert a natural-language request into a single shell command for a Unix-like system.
        Rules:
        - Output the command and only the command — no explanation, no markdown fences, no leading "$".
        - If the request implies multiple steps, chain them with && or use a one-liner.
        - Prefer common, portable tools (bash, coreutils, git). Use sudo only if explicitly asked.
        - If the request is ambiguous or unsafe, output a best-effort safe command.
        Recent terminal context (most recent at the bottom):
        \(context.isEmpty ? "(none)" : context)
        """

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": transcript],
            ],
            "temperature": 0.2,
            "max_tokens": 256,
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        // Only BYOK carries a key; the relay injects its own server-side.
        if usesBYOK {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return transcript }
            guard (200...299).contains(http.statusCode) else {
                let snippet = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
                dlog("LLM HTTP \(http.statusCode): \(snippet)")
                return transcript
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                return transcript
            }
            return cleanCommand(content)
        } catch {
            dlog("LLM error: \(error)")
            return transcript
        }
    }

    /// Strip code fences, leading shell prompts, and surrounding whitespace.
    private func cleanCommand(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let firstNL = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: firstNL)...])
            } else {
                s = String(s.dropFirst(3))
            }
            if s.hasSuffix("```") {
                s = String(s.dropLast(3))
            }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for prefix in ["$ ", "# ", "> "] {
            if s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        }
        return s
    }
}
