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

/// Settings sections shared by both platforms.
///
/// Mac and iOS used to render these sections twice with drift (different font
/// tokens, different importers, one side forgetting a key). Each struct below
/// is a complete `Section`; the app keeps its own container (Mac: TabView,
/// iOS: NavigationStack) and its platform-only sections. Where the two sides
/// ever differed, the Mac rendering is the reference — the only parameters are
/// platform-constrained facts (font families, importer content types).

// MARK: - Appearance

public struct SettingsAppearanceSection: View {
    @ObservedObject private var themeStore = ThemeStore.shared

    public init() {}

    public var body: some View {
        Section {
            Picker("Appearance", selection: Binding(
                get: { themeStore.appearanceMode },
                set: { themeStore.appearanceMode = $0 }
            )) {
                ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
            }
        } header: { Text("Appearance") } footer: {
            Text("Follow System to match the system's light/dark appearance; pick Light or Dark to pin it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Font

public struct SettingsFontSection: View {
    /// Maple Mono NF CN is bundled with the app on both platforms (the
    /// default — CJK-friendly); the system monospace families follow, resolved
    /// through the engine's CoreText font registry.
    private static let families: [(token: String, label: String)] = [
        ("maple-nf-cn", "Maple Mono NF CN"), ("sf-mono", "SF Mono"),
        ("menlo", "Menlo"), ("courier", "Courier"),
    ]

    /// Fresh-install size (persisted values always win): 12 on Mac, 10 on iOS.
    public let defaultSize: Double

    @AppStorage(SettingsKey.fontSize) private var fontSize: Double = 12
    @AppStorage(SettingsKey.fontFamily) private var fontFamily: String = "maple-nf-cn"

    public init(defaultSize: Double = 12) {
        self.defaultSize = defaultSize
        _fontSize = AppStorage(wrappedValue: defaultSize, SettingsKey.fontSize)
    }

    public var body: some View {
        Section {
            HStack {
                Text("Font size")
                // Post on release, not per tick: a live surface reconfigures on
                // `.terminalFontChanged`, and re-configuring mid-drag crashed on
                // iOS (the surface was rebuilt while live). Both platforms apply
                // the new size when the user lets go.
                Slider(value: $fontSize, in: 8...24, step: 1) { editing in
                    if !editing {
                        NotificationCenter.default.post(name: .terminalFontChanged, object: nil)
                    }
                }
                Text("\(Int(fontSize))").monospacedDigit().frame(width: 28, alignment: .trailing)
            }
            Picker("Font", selection: $fontFamily) {
                ForEach(Self.families, id: \.token) { Text($0.label).tag($0.token) }
            }
            .onChange(of: fontFamily) { _, _ in
                NotificationCenter.default.post(name: .terminalFontChanged, object: nil)
            }
        } header: { Text("Font") }
    }
}

// MARK: - Color theme

public struct SettingsThemeSection: View {
    @ObservedObject private var themeStore = ThemeStore.shared
    @State private var showThemeImporter = false
    @State private var importError: String?

    /// iTerm2 themes are `.itermcolors` files (XML plists). The extension is
    /// not a registered type on iOS, so the lookup falls back to `.xml` there;
    /// `.data` covers anything the picker reports generically. Same list on
    /// both platforms.
    private static let importerTypes: [UTType] = [
        UTType(filenameExtension: "itermcolors") ?? .xml, .data,
    ]

    public init() {}

    public var body: some View {
        Section {
            Picker("Dark theme", selection: Binding(
                get: { themeStore.darkThemeID },
                set: { themeStore.select(id: $0, forDark: true) }
            )) {
                ForEach(themeStore.themes(forDark: true)) { Text($0.name).tag($0.id) }
            }
            Picker("Light theme", selection: Binding(
                get: { themeStore.lightThemeID },
                set: { themeStore.select(id: $0, forDark: false) }
            )) {
                ForEach(themeStore.themes(forDark: false)) { Text($0.name).tag($0.id) }
            }
            Button("Import iTerm2 Theme…") { showThemeImporter = true }
            if let importError {
                Label(importError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.caption)
            }
            ForEach(themeStore.customThemes) { theme in
                HStack {
                    Text(theme.name)
                    Spacer()
                    Button(role: .destructive) {
                        themeStore.removeCustomTheme(theme.id)
                    } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(theme.name)")
                }
            }
        } header: { Text("Color theme") } footer: {
            Text("The Dark theme is used in dark appearance, the Light theme in light. Applies live to open windows.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .fileImporter(isPresented: $showThemeImporter,
                      allowedContentTypes: Self.importerTypes) { result in
            handleThemeImport(result)
        }
    }

    private func handleThemeImport(_ result: Result<URL, Error>) {
        importError = nil
        do {
            let url = try result.get()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let name = url.deletingPathExtension().lastPathComponent
            let theme = try TerminalColorTheme.fromITermColors(data: data, name: name)
            themeStore.addCustomTheme(theme)
        } catch {
            importError = (error as NSError).localizedDescription
        }
    }
}

// MARK: - Speech recognition

public struct SettingsSpeechSection: View {
    @AppStorage(SettingsKey.speechEngine) private var speechEngine = "apple"
    @AppStorage(SettingsKey.speechLocale) private var speechLocale = "auto"
    @AppStorage(SettingsKey.openAIKey) private var openaiKey = ""
    @AppStorage(SettingsKey.dashScopeKey) private var dashscopeKey = ""
    @AppStorage(SettingsKey.asrAutoContext) private var asrAutoContext = true
    @AppStorage(SettingsKey.asrVocab) private var asrVocab = ""

    public init() {}

    @ViewBuilder
    private var footerText: some View {
        switch speechEngine {
        case "apple":
            Text("Apple runs on-device (no key needed).")
        case "openai":
            Text("OpenAI Realtime. Leave the API key blank to use Bento's servers — forwarding is rate-limited.")
        default:
            Text("Qwen realtime (qwen3-asr-flash) — real-time recognition with solid quality across multiple languages, including mixed speech. Leave the DashScope key blank to use Bento's servers — forwarding is rate-limited.")
        }
    }

    public var body: some View {
        Section {
            Picker("Engine", selection: $speechEngine) {
                Text("Apple (on-device)").tag("apple")
                Text("OpenAI Realtime").tag("openai")
                Text("Qwen").tag("qwen")
            }
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
            if speechEngine == "openai" {
                SecureField("OpenAI API key (optional)", text: $openaiKey)
            }
            if speechEngine == "qwen" {
                SecureField("DashScope API key (optional)", text: $dashscopeKey)
                Toggle("Bias from on-screen text", isOn: $asrAutoContext)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Custom vocabulary (names, jargon — one per line or comma-separated)")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $asrVocab)
                        .frame(height: 56).font(.caption.monospaced())
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                }
            }
        } header: { Text("Speech") } footer: {
            footerText
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Voice → shell command (LLM)

public struct SettingsLLMSection: View {
    @AppStorage(SettingsKey.llmEnabled) private var llmEnabled = true
    @AppStorage(SettingsKey.llmKey) private var llmKey = ""
    @AppStorage(SettingsKey.llmModel) private var llmModel = ""
    @AppStorage(SettingsKey.llmEndpoint) private var llmEndpoint = "https://api.openai.com/v1/chat/completions"

    public init() {}

    public var body: some View {
        Section {
            Toggle("Convert speech → shell command", isOn: $llmEnabled)
            if llmEnabled {
                SecureField("LLM API key", text: $llmKey)
                TextField("Endpoint", text: $llmEndpoint)
                    .autocorrectionDisabled()
                    .font(.caption.monospaced())
                TextField("Model", text: $llmModel)
                    .autocorrectionDisabled()
                    .font(.caption.monospaced())
            }
        } header: { Text("LLM") } footer: {
            Text("Uses an LLM to generate shell commands from speech and refine input prompts. Works with any OpenAI-compatible provider — set an endpoint and key, or leave them blank to use Bento's servers (forwarding is rate-limited).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - The whole shared form

/// The settings form both platforms render: the six common sections in one
/// order, plus the platform-only sections appended via `extra`. The shells
/// stopped being tabbed/grouped wrappers with this — Mac renders it in a plain
/// settings window (`.formStyle(.grouped)` applied by the shell), iOS inside
/// its NavigationStack. One source of truth for what a Bento settings page is.
public struct BentoSettingsForm<Extra: View>: View {
    /// Fresh-install font size — 12 on Mac, 10 on iOS.
    public let defaultFontSize: Double
    @ViewBuilder public let extra: Extra

    public init(defaultFontSize: Double = 12, @ViewBuilder extra: () -> Extra) {
        self.defaultFontSize = defaultFontSize
        self.extra = extra()
    }

    public var body: some View {
        Form {
            SettingsAppearanceSection()
            SettingsFontSection(defaultSize: defaultFontSize)
            SettingsThemeSection()
            SettingsSpeechSection()
            SettingsLLMSection()
            SettingsPrivacySection()
            extra
        }
    }
}

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

// MARK: - Privacy

public struct SettingsPrivacySection: View {
    @ObservedObject private var telemetry = TelemetryService.shared

    public init() {}

    public var body: some View {
        Section {
            Toggle("Share anonymous usage statistics", isOn: Binding(
                get: { telemetry.enabled },
                set: { telemetry.enabled = $0 }
            ))
            DisclosureGroup("What gets counted") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(TelemetryEvent.allCases, id: \.rawValue) { event in
                        Text(event.rawValue)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } header: {
            Text("Privacy")
        } footer: {
            Text("No terminal content, commands, transcripts, paths, or hostnames — ever. Just the event names above, tied to a random ID that is deleted when you turn this off. Events go straight to Bento's own endpoint; no third-party SDKs.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
