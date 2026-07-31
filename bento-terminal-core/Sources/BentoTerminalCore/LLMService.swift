import Foundation

/// Translates a natural-language utterance into a single shell command via an
/// OpenAI-compatible chat endpoint. Bring-your-own-key: the request goes from
/// this machine straight to the endpoint the user configured, on the user's own
/// key. Bento runs no server, so with no key the feature is simply off and the
/// raw transcript is inserted instead. Pure Foundation — shared iOS + macOS.
public final class LLMService: @unchecked Sendable {
    public static let shared = LLMService()

    private let session = URLSession(configuration: .default)

    /// The feature runs only when it is switched on AND the user supplied a key.
    /// Otherwise `convertTo…` falls back to inserting the raw transcript, which
    /// is a graceful degradation rather than a failure: the words the user spoke
    /// still land in the pane.
    public var isConfigured: Bool { enabled && !apiKey.isEmpty }

    /// Why the conversion is not available, or nil when it is. Lets the settings
    /// UI say so at the point the user turns the feature on.
    public var unavailableReason: String? {
        guard enabled, apiKey.isEmpty else { return nil }
        return "Add your own API key to convert speech into shell commands. Without one, dictation inserts the raw transcript."
    }

    private var enabled: Bool {
        if UserDefaults.standard.object(forKey: "llm_enabled") == nil { return true }
        return UserDefaults.standard.bool(forKey: "llm_enabled")
    }

    private var apiKey: String {
        (UserDefaults.standard.string(forKey: "llm_api_key") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var endpoint: URL {
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
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
