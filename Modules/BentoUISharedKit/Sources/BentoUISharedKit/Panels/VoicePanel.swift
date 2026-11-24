import SwiftUI
import AVFoundation
import BentoVoiceKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Apple's engine is the default: it is the only one that works with neither a
/// key nor a download.
public enum SpeechDefaults {
    public static var engine: String { SpeechEngineKind.apple.rawValue }
}

/// The three engines, laid out where none can be missed. File scope because a
/// generic type can't hold a static stored property.
///
/// One sentence each, saying what the engine is FOR: most accurate, best
/// offline, or nothing to set up.
struct SpeechEngineOption: Identifiable {
    let kind: SpeechEngineKind
    let name: String
    let purpose: String
    var id: String { kind.rawValue }

    static let all: [SpeechEngineOption] = [
        SpeechEngineOption(kind: .qwen, name: "Qwen (online)",
                           purpose: "Most accurate: handles mixed languages and reads the screen to get names and jargon right, on your own DashScope key."),
        SpeechEngineOption(kind: .senseVoice, name: "SenseVoice (offline)",
                           purpose: "Best without a network: runs on this device with no key, after a one-time model download."),
        SpeechEngineOption(kind: .apple, name: "Apple",
                           purpose: "Nothing to set up: no key and no download, but the least accurate."),
    ]
}

/// Voice — the microphone, the engine (and its key, right under it), the
/// language, and voice → shell command.
public struct VoicePanel: View {
    @AppStorage(SettingsKey.speechEngine) private var speechEngine = SpeechDefaults.engine
    @AppStorage(SettingsKey.speechLocale) private var speechLocale = "auto"
    @AppStorage(SettingsKey.dashScopeKey) private var dashscopeKey = ""
    @AppStorage(SettingsKey.asrAutoContext) private var asrAutoContext = true
    @AppStorage(SettingsKey.asrVocab) private var asrVocab = ""
    @AppStorage(SettingsKey.llmEnabled) private var llmEnabled = true
    @AppStorage(SettingsKey.llmKey) private var llmKey = ""
    @AppStorage(SettingsKey.llmModel) private var llmModel = ""
    @AppStorage(SettingsKey.llmEndpoint) private var llmEndpoint = "https://api.openai.com/v1/chat/completions"

    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)

    public init() {}

    private var picked: SpeechEngineKind { SpeechEngineKind(setting: speechEngine) }

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
                    if engine.kind == picked {
                        engineSettings(engine.kind)
                    }
                }
            } header: { Text("Engine") } footer: {
                if let engineNote { PanelNote(engineNote) }
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
    private func engineSettings(_ engine: SpeechEngineKind) -> some View {
        switch engine {
        case .senseVoice:
            OnDeviceModelRow(store: .shared(for: .senseVoiceSmall))
        case .qwen:
            SecureField("DashScope API key", text: $dashscopeKey)
            Toggle("Bias from on-screen text", isOn: $asrAutoContext)
            VStack(alignment: .leading, spacing: 3) {
                Text("Custom vocabulary (names, jargon — one per line or comma-separated)")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $asrVocab)
                    .frame(height: 56).font(.caption.monospaced())
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            }
        case .apple:
            EmptyView()
        }
    }

    /// Owns up when Qwen is picked without its key: voice then quietly runs on
    /// Apple's engine, which would otherwise look like the choice was ignored.
    private var engineNote: LocalizedStringKey? {
        switch picked {
        case .qwen:
            guard dashscopeKey.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return "Add your API key above. Until then, voice uses Apple's engine."
        case .senseVoice:
            // The FunASR model licence asks for the source to be credited.
            return "Model: SenseVoiceSmall by Alibaba FunAudioLLM, via FluidAudio."
        case .apple:
            return nil
        }
    }

    private func engineRow(_ engine: SpeechEngineOption) -> some View {
        Button {
            speechEngine = engine.id
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: engine.kind == picked
                      ? "largecircle.fill.circle" : "circle")
                    // `.tint`, not `Color.accentColor`: the former follows the
                    // app's `.tint(...)`, the latter reads the accent asset and
                    // stayed blue while everything else went green.
                    .foregroundStyle(engine.kind == picked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 3) {
                    Text(engine.name).font(.system(size: 14, weight: .semibold))
                    Text(engine.purpose)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
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

/// Download / progress / cancel / delete for one on-device speech model, shown
/// under its engine. The store does the work off the main thread; this only
/// renders its state.
struct OnDeviceModelRow: View {
    @ObservedObject var store: OnDeviceModelStore

    var body: some View {
        Group {
            switch store.state {
            case .installed(let bytes):
                HStack {
                    Label("Model downloaded", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Delete model (\(Self.size(bytes)))", role: .destructive) { store.delete() }
                }
            case .downloading(let fraction):
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: fraction)
                    HStack {
                        Text("Downloading speech model… \(Int((fraction * 100).rounded(.down)))% of \(Self.size(store.totalBytes))")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { store.cancelDownload() }
                    }
                }
            case .verifying:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking speech model…").font(.caption).foregroundStyle(.secondary)
                }
            case .notInstalled, .failed:
                VStack(alignment: .leading, spacing: 6) {
                    if case .failed(let message) = store.state {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Button(downloadTitle) { store.download() }
                }
            }
        }
        .onAppear { store.refresh() }
    }

    private var downloadTitle: String {
        if store.partialBytes > 0 {
            return "Resume download (\(Self.size(store.partialBytes)) of \(Self.size(store.totalBytes)))"
        }
        return "Download model (\(Self.size(store.totalBytes)))"
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
