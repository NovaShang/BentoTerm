import SwiftUI
import AVFoundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A Chinese-language system gets Qwen preselected — Apple's engine is close
/// to unusable on mixed Chinese/English, which is exactly what this audience
/// dictates. Preselected, not decided for them: all three engines are on
/// screen, so changing it is one click.
public enum SpeechDefaults {
    public static var engine: String {
        (Locale.preferredLanguages.first?.hasPrefix("zh") == true) ? "qwen" : "apple"
    }
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
                           cost: "Best on mixed and non-English speech, and it can read what's on screen to get names and jargon right."),
        SpeechEngineOption(id: "openai", name: "OpenAI", badge: nil,
                           cost: "A solid middle ground."),
    ]
}

/// ② Speech — the engine choice, and the gesture nobody can see.
///
/// The gesture is the whole reason this panel explains itself: hold-to-talk is
/// invisible in the UI, so a user who is never told simply never finds the
/// feature we built the product around. And the explanation leads with the
/// stance, not the mechanic — "hold right-click to talk" reads like a minor
/// convenience unless you first say that talking is meant to be the main way
/// you drive an agent here.
public struct SpeechPanel<Extra: View>: View {
    private let context: PanelContext
    private let extra: Extra

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

    public init(context: PanelContext, @ViewBuilder extra: () -> Extra = { EmptyView() }) {
        self.context = context
        self.extra = extra()
    }

    public var body: some View {
        PanelBody(context) {
                PanelLead("Bento is built to be talked to.")
                // ~150 wpm speech vs ~50 wpm prose typing — a checkable 3×,
                // not an invented one. An earlier draft said "a paragraph in
                // five seconds", which nobody can do.
                PanelProse("You speak about three times faster than you type.")
                PanelProse("With three panes running, talking to the one that needs you beats switching to it first.")
                VoiceGestureFigure()
                // The privacy sentence moved down to the microphone block: it
                // is the answer to "why does it want the mic", and it should be
                // where that question gets asked.
                PanelProse("What you said goes into that pane exactly as if you had typed it.")
        } controls: {
            // Above the engine list, not below it. It used to sit under
            // Language, which on an iPhone is below the fold: the one action
            // on the page that the flagship feature cannot work without was
            // reachable only by scrolling, and tapping Next — which is right
            // there — skipped it silently.
            microphoneSection

            Section {
                ForEach(SpeechEngineOption.all) { engine in
                    engineRow(engine)
                }
            } header: { Text("Engine") } footer: {
                // The setup flow hides Advanced, which is where the API key
                // fields are — so without this line a user would never learn
                // that any of this leaves the machine, or that they can point
                // it at their own account.
                //
                // It follows the selection because Apple's engine genuinely
                // does not leave the device: saying "speech recognition goes
                // through Bento's relay" while Apple is selected would be a
                // false claim about someone's audio, which is the one kind of
                // copy this app cannot get away with.
                PanelNote(relayNote)
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
            }

            AdvancedBlock(context) {
                PanelNote("""
                    Leave the key blank to use Bento's servers (rate-limited). \
                    Fill it in to talk to your own account directly.
                    """)
                switch speechEngine {
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
                    PanelNote("Apple's engine runs on this device and needs no key.")
                }

                Divider()

                Toggle("Voice → shell command", isOn: $llmEnabled)
                PanelNote("""
                    Talking to a shell instead of an agent? With this on, Bento turns what you \
                    said into the command. Works with any OpenAI-compatible provider — set an \
                    endpoint and key, or leave them blank to use Bento's servers.
                    """)
                if llmEnabled {
                    SecureField("LLM API key", text: $llmKey)
                    TextField("Endpoint", text: $llmEndpoint)
                        .autocorrectionDisabled()
                        .font(.caption.monospaced())
                    TextField("Model", text: $llmModel)
                        .autocorrectionDisabled()
                        .font(.caption.monospaced())
                }
            }

            extra
        }
    }

    private var relayNote: LocalizedStringKey {
        speechEngine == "apple"
            ? "Apple's engine runs on this device. Turning speech into a shell command still goes through Bento's relay (rate-limited) — you can use your own API key in Settings."
            : "Speech recognition and voice → shell go through Bento's relay (rate-limited). You can use your own API key in Settings."
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

    /// The panel's only action, and the one thing on it that has to be done
    /// now: without the microphone the feature this whole page is about cannot
    /// run at all, and the prompt would otherwise arrive as an interruption in
    /// the middle of someone's first hold-to-talk.
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
