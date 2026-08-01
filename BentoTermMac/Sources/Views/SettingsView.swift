import SwiftUI
import BentoTerminalCore
import UniformTypeIdentifiers
import BentoFoundationKit

/// SettingsView is the content of the app's Settings scene. macOS renders it
/// in the canonical "preferences window" chrome with toolbar + grouped form.
struct SettingsView: View {
    @ObservedObject private var themeStore = ThemeStore.shared
    @State private var preferredTerminal: TerminalAppKind = TerminalAppKind.preferred
    @AppStorage("terminal_font_size") private var fontSize: Double = 13
    @AppStorage("terminal_font_family") private var fontFamily: String = "sf-mono"
    @AppStorage(BentoTerminalWindow.defaultSessionNameKey) private var defaultSessionName: String = "bento"
    @AppStorage(BentoTerminalWindow.autoHideToolbarFullscreenKey) private var autoHideToolbar = true
    @AppStorage(BentoTerminalWindow.newSessionPlacementKey) private var newSessionPlacement = "system"
    @AppStorage("speech_engine") private var speechEngine = "apple"
    @AppStorage("speech_locale") private var speechLocale = "auto"
    @AppStorage("openai_api_key") private var openaiKey = ""
    @AppStorage("dashscope_api_key") private var dashscopeKey = ""
    @AppStorage("asr_auto_context") private var asrAutoContext = true
    @AppStorage("asr_vocab") private var asrVocab = ""
    @AppStorage("llm_enabled") private var llmEnabled = true
    @AppStorage("llm_api_key") private var llmKey = ""
    @AppStorage("llm_model") private var llmModel = "gpt-4o-mini"
    @State private var showThemeImporter = false
    @State private var importError: String?
    @ObservedObject private var telemetry = TelemetryService.shared

    private let fontFamilies: [(token: String, label: String)] = [
        ("sf-mono", "SF Mono"), ("menlo", "Menlo"),
        ("jetbrains", "JetBrains Mono"), ("maple-nf-cn", "Maple Mono NF CN"),
        ("courier", "Courier"),
    ]

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            terminalTab
                .tabItem { Label("Terminal", systemImage: "terminal") }
            voiceTab
                .tabItem { Label("Voice", systemImage: "mic") }
            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 360)
    }

    // MARK: - Voice (shared engine + settings with iOS)

    private var voiceTab: some View {
        Form {
            Section {
                Picker("Engine", selection: $speechEngine) {
                    Text("Apple (on-device)").tag("apple")
                    Text("OpenAI Realtime").tag("openai")
                    Text("Qwen (中文 / 中英混说)").tag("qwen")
                }
                Picker("Language", selection: $speechLocale) {
                    Text("Auto").tag("auto")
                    Text("中文").tag("zh-Hans")
                    Text("English").tag("en-US")
                    Text("日本語").tag("ja-JP")
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
                Text(speechEngine == "qwen"
                     ? "Qwen realtime (qwen3-asr-flash) — best for Chinese and Chinese-English mixed speech. Uses the bundled relay unless you add a DashScope key."
                     : "Apple runs on-device (no key). OpenAI Realtime uses the bundled relay unless you add a key.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Convert speech → shell command", isOn: $llmEnabled)
                if llmEnabled {
                    SecureField("LLM API key", text: $llmKey)
                    Picker("Model", selection: $llmModel) {
                        Text("gpt-4o-mini").tag("gpt-4o-mini")
                        Text("gpt-4o").tag("gpt-4o")
                    }
                }
            } header: { Text("AI command") } footer: {
                Text("Right-click-and-hold a pane to dictate. While held, drag: ↑ send · ↓ cancel · ← / → AI → shell command.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Terminal (font + theme)

    private var terminalTab: some View {
        Form {
            Section {
                HStack {
                    Text("Font size")
                    Slider(value: $fontSize, in: 8...24, step: 1)
                    Text("\(Int(fontSize))").monospacedDigit().frame(width: 28, alignment: .trailing)
                }
                .onChange(of: fontSize) { _, _ in
                    NotificationCenter.default.post(name: .terminalFontChanged, object: nil)
                }
                Picker("Font", selection: $fontFamily) {
                    ForEach(fontFamilies, id: \.token) { Text($0.label).tag($0.token) }
                }
                .onChange(of: fontFamily) { _, _ in
                    NotificationCenter.default.post(name: .terminalFontChanged, object: nil)
                }
            } header: { Text("Font") }

            Section {
                Picker("Appearance", selection: Binding(
                    get: { themeStore.appearanceMode },
                    set: { themeStore.appearanceMode = $0 }
                )) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                }
            } header: { Text("Appearance") } footer: {
                Text("Follow System matches macOS's light/dark; pick Light or Dark to pin it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

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
                    }
                }
            } header: { Text("Color theme") } footer: {
                Text("The Dark theme is used in dark appearance, the Light theme in light. Applies live to open windows.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Auto-hide toolbar in full screen", isOn: $autoHideToolbar)
            } header: { Text("Full Screen") } footer: {
                Text("Hide the toolbar and session tabs in full screen, revealing them when the pointer reaches the top. Takes effect the next time you enter full screen.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                TextField("Default session name", text: $defaultSessionName, prompt: Text("bento"))
                Picker("Open a new session", selection: $newSessionPlacement) {
                    ForEach(BentoTerminalWindow.NewSessionPlacement.allCases, id: \.rawValue) {
                        Text($0.title).tag($0.rawValue)
                    }
                }
            } header: { Text("Sessions") } footer: {
                Text("Clicking the app icon opens the terminal window and reconnects the session you last had open. With no previous session, it creates one with this name.\n\nmacOS already has a system-wide answer for tabs vs. windows (System Settings → Desktop & Dock → “Prefer tabs when opening documents”), which Bento follows by default. Either way you can still merge windows into tabs or drag a tab out into its own window.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $showThemeImporter,
                      allowedContentTypes: [UTType(filenameExtension: "itermcolors") ?? .data]) { result in
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

    private var generalTab: some View {
        Form {
            Section {
                Picker("Open tmux sessions in", selection: $preferredTerminal) {
                    ForEach(TerminalAppKind.allInstalled) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .onChange(of: preferredTerminal) { _, new in
                    TerminalAppKind.preferred = new
                }
            } header: {
                Text("Terminal")
            } footer: {
                Text(terminalFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
        .formStyle(.grouped)
    }

    private var terminalFooter: String {
        if preferredTerminal.isNative {
            return "Sessions open in Bento's own tiled terminal (libghostty + `tmux -CC`), in-app."
        }
        return preferredTerminal.supportsTmuxControlMode
            ? "Bento attaches with `tmux -CC` so \(preferredTerminal.displayName) renders each tmux pane as a native window."
            : "Bento attaches with plain `tmux attach`; \(preferredTerminal.displayName) shows the standard tmux UI."
    }

    private var aboutTab: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("BentoTerm")
                .font(.title2).bold()
            Text("A tmux-native terminal for the Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
