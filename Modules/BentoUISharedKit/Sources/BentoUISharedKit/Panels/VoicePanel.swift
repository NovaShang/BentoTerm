import SwiftUI
import AVFoundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Apple's engine is the default: it is the only one that works without a key.
/// (A Chinese-language system used to get Qwen preselected, back when Bento's
/// relay supplied the key.)
public enum SpeechDefaults {
    public static var engine: String { "apple" }
}

/// The three engines, laid out where none can be missed. File scope because a
/// generic type can't hold a static stored property.
///
/// Each line says what the engine is FOR, not what category it is in. The
/// first version tagged them "On-device" / "Realtime" / "Realtime", which
/// sorted them without telling anyone which to pick — and two of the three
/// carried the same tag. Only one badge survives, and it is a recommendation.
struct SpeechEngineOption: Identifiable {
    let id: String
    let name: String
    /// nil for everything that isn't the recommendation.
    let badge: String?
    let cost: String

    static let all: [SpeechEngineOption] = [
        SpeechEngineOption(id: "apple", name: "Apple", badge: nil,
                           cost: "Never leaves this device. A little less accurate."),
        SpeechEngineOption(id: "qwen", name: "Qwen", badge: "Recommended",
                           cost: "Best on mixed and non-English speech, and it can read what's on screen to get names and jargon right. Needs your DashScope API key."),
        SpeechEngineOption(id: "openai", name: "OpenAI", badge: nil,
                           cost: "A solid middle ground. Needs your OpenAI API key."),
    ]
}

/// Voice — the microphone, the engine (and its key, right under it), the
/// language, and voice → shell command.
public struct VoicePanel: View {
    @AppStorage(SettingsKey.speechEngine) private var speechEngine = SpeechDefaults.engine
    @AppStorage(SettingsKey.speechLocale) private var speechLocale = "auto"
    @AppStorage(SettingsKey.openAIKey) private var openaiKey = ""
    @AppStorage(SettingsKey.dashScopeKey) private var dashscopeKey = ""
    @AppStorage(SettingsKey.asrAutoContext) private var asrAutoContext = true
    @AppStorage(SettingsKey.asrVocab) private var asrVocab = ""
    @AppStorage(SettingsKey.llmEnabled) private var llmEnabled = true
    @AppStorage(SettingsKey.llmKey) private var llmKey = ""
    @AppStorage(SettingsKey.llmModel) private var llmModel = ""
    @AppStorage(SettingsKey.llmEndpoint) private var llmEndpoint = "https://api.openai.com/v1/chat/completions"

    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)

    public init() {}

    public var body: some View {
        Form {
            // First: without the microphone nothing else on this page does
            // anything.
            microphoneSection

            Section {
                ForEach(SpeechEngineOption.all) { engine in
                    engineRow(engine)
                    // The key sits under the engine that needs it. Behind an
                    // "Advanced" fold, picking a cloud engine silently changed
                    // nothing until someone went looking for where the key went.
                    if speechEngine == engine.id {
                        engineSettings(engine.id)
                    }
                }
            } header: { Text("Engine") } footer: {
                PanelNote(engineNote)
            }

            Section {
                Picker("Language", selection: $speechLocale) {
                    Text("Auto").tag("auto")
                    Text("简体中文").tag("zh-Hans")
                    Text("繁體中文").tag("zh-Hant")
                    Text("English (US)").tag("en-US")
                    Text("English (UK)").tag("en-GB")
                    Text("日本語").tag("ja-JP")
                    Text("한국어").tag("ko-KR")
                    Text("Français").tag("fr-FR")
                    Text("Deutsch").tag("de-DE")
                    Text("Español").tag("es-ES")
                    Text("Italiano").tag("it-IT")
                    Text("Português").tag("pt-BR")
                    Text("Русский").tag("ru-RU")
                    Text("العربية").tag("ar-SA")
                    Text("हिन्दी").tag("hi-IN")
                    Text("Bahasa Indonesia").tag("id-ID")
                    Text("ไทย").tag("th-TH")
                    Text("Tiếng Việt").tag("vi-VN")
                }
            } footer: {
                // The gesture is invisible in the UI; this is the one place in
                // Settings that names it.
                PanelNote(Self.gestureHint)
            }

            Section {
                Toggle("Voice → shell command", isOn: $llmEnabled)
                if llmEnabled {
                    SecureField("LLM API key", text: $llmKey)
                    TextField("Endpoint", text: $llmEndpoint)
                        .autocorrectionDisabled()
                        .font(.caption.monospaced())
                    TextField("Model", text: $llmModel)
                        .autocorrectionDisabled()
                        .font(.caption.monospaced())
                }
            } footer: {
                PanelNote("""
                    Slide left while talking to a shell instead of an agent, and Bento turns \
                    what you said into the command. Works with any OpenAI-compatible provider: \
                    set an endpoint and key. Without a key, what you said goes in as is.
                    """)
            }
        }
        .bentoPanelForm()
    }

    private static var gestureHint: LocalizedStringKey {
        #if os(macOS)
        return "Hold right-click on a pane to talk. Slide up to send now, down to cancel."
        #else
        return "Hold anywhere on a pane to talk. Slide up to send now, down to cancel."
        #endif
    }

    /// The rows that belong to one engine, shown only while it is picked.
    @ViewBuilder
    private func engineSettings(_ id: String) -> some View {
        switch id {
        case "openai":
            SecureField("OpenAI API key", text: $openaiKey)
        case "qwen":
            SecureField("DashScope API key", text: $dashscopeKey)
            Toggle("Bias from on-screen text", isOn: $asrAutoContext)
            VStack(alignment: .leading, spacing: 3) {
                Text("Custom vocabulary (names, jargon — one per line or comma-separated)")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $asrVocab)
                    .frame(height: 56).font(.caption.monospaced())
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            }
        default:
            EmptyView()
        }
    }

    // Says where the audio goes for the engine actually picked, and owns up
    // when a cloud engine is picked without its key: voice then quietly runs
    // on Apple's engine, which would otherwise look like the choice was ignored.
    private var engineNote: LocalizedStringKey {
        switch speechEngine {
        case "openai" where openaiKey.trimmingCharacters(in: .whitespaces).isEmpty,
             "qwen" where dashscopeKey.trimmingCharacters(in: .whitespaces).isEmpty:
            return "Add your API key above. Until then, voice uses Apple's engine."
        case "openai", "qwen":
            return "Audio goes straight to the provider, on your own key."
        default:
            return "Apple's engine runs on this device."
        }
    }

    private func engineRow(_ engine: SpeechEngineOption) -> some View {
        Button {
            speechEngine = engine.id
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: speechEngine == engine.id
                      ? "largecircle.fill.circle" : "circle")
                    // `.tint`, not `Color.accentColor`: the former follows the
                    // app's `.tint(...)`, the latter reads the accent asset and
                    // stayed blue while everything else went green.
                    .foregroundStyle(speechEngine == engine.id ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(engine.name).font(.system(size: 14, weight: .semibold))
                        if let badge = engine.badge {
                            Text(badge)
                                .font(.caption2)
                                .foregroundStyle(.tint)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(.tint.opacity(0.12)))
                        }
                        Spacer()
                    }
                    Text(engine.cost)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Asking here rather than on first hold-to-talk: the system prompt would
    /// otherwise arrive as an interruption in the middle of someone's first
    /// sentence.
    @ViewBuilder
    private var microphoneSection: some View {
        switch micStatus {
        case .authorized:
            Section {
                Label("Microphone enabled", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case .denied, .restricted:
            Section {
                Label("Microphone denied", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button(Self.openSettingsTitle) { Self.openPrivacySettings() }
            } footer: {
                PanelNote("Without it, hold-to-talk records nothing.")
            }
        default:
            Section {
                Button {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in
                        Task { @MainActor in
                            micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                        }
                    }
                } label: {
                    Label("Allow Microphone", systemImage: "mic.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            } footer: {
                PanelNote("""
                    Bento needs the microphone to turn what you say into terminal input. \
                    Audio is used for transcription only — nothing is written to disk.
                    """)
            }
        }
    }

    private static var openSettingsTitle: String {
        #if os(macOS)
        return "Open System Settings"
        #else
        return "Open Settings"
        #endif
    }

    private static func openPrivacySettings() {
        #if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
        #else
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }
}
