import SwiftUI
import UniformTypeIdentifiers
import BentoFoundationKit

/// UserDefaults keys shared with the app shells and engine kits — matched by
/// convention, so the strings live in this one place.
enum SettingsKey {
    static let fontSize = "terminal_font_size"
    static let fontFamily = "terminal_font_family"
    static let speechEngine = "speech_engine"
    static let speechLocale = "speech_locale"
    static let openAIKey = "openai_api_key"
    static let dashScopeKey = "dashscope_api_key"
    static let asrAutoContext = "asr_auto_context"
    static let asrVocab = "asr_vocab"
    static let llmEnabled = "llm_enabled"
    static let llmKey = "llm_api_key"
    static let llmModel = "llm_model"
    static let llmEndpoint = "llm_endpoint"
}

/// The one surviving free-standing section: About.
///
/// Everything else that used to live here — appearance, font, theme, speech,
/// LLM, privacy, and the `BentoSettingsForm` that stacked them — moved into
/// the five panels in `Panels/`. The sections were a flat list of controls
/// with nowhere to put a preview, an illustration or a paragraph, and setup
/// needs all three around the same settings. Keeping both would have meant two
/// renderings of every control, which is the drift this file was written to
/// prevent in the first place.
///
/// `SettingsKey` above stays: it is the contract the panels write through, and
/// the reason moving the UI changed no stored data at all.

// MARK: - About

/// The About block, one shared shape on both platforms: optional app icon,
/// name, tagline, and the version read from the bundle. (The iOS About used to
/// hardcode "0.2.0" and the Mac one showed no version at all — both now read
/// `CFBundleShortVersionString`.)
public struct SettingsAboutSection: View {
    public let icon: Image?
    public let tagline: String

    public init(icon: Image? = nil, tagline: String) {
        self.icon = icon
        self.tagline = tagline
    }

    public static func bundleVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    public var body: some View {
        Section {
            HStack(spacing: 12) {
                if let icon {
                    icon
                        .resizable()
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("BentoTerm")
                        .font(.headline)
                    if !tagline.isEmpty {
                        Text(tagline)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Version \(Self.bundleVersion())")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(.vertical, 4)
        } header: { Text("About") }
    }
}


