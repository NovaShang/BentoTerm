import SwiftUI
import UniformTypeIdentifiers
import BentoFoundationKit

/// iTerm2 themes are `.itermcolors` (XML plists). The extension isn't a
/// registered type on iOS, so the lookup falls back to `.xml`; `.data` covers
/// anything the picker reports generically. (File scope because a generic type
/// can't hold a static stored property.)
enum ThemeImport {
    static let types: [UTType] = [
        UTType(filenameExtension: "itermcolors") ?? .xml, .data,
    ]
}

/// Appearance — colors, font, size, and a live terminal above them.
///
/// **Three dropdowns here, three cards on the Voice page — same judgement,
/// opposite answer.** Themes and fonts are open-ended (import a theme, install
/// a font) and the preview already does the "see it without opening a menu"
/// job. Speech has exactly three engines whose costs differ sharply and
/// nothing that can preview them, so those get laid out where they can't be
/// missed.
public struct AppearancePanel: View {
    private let preview: AnyView?

    @ObservedObject private var themeStore = ThemeStore.shared

    @AppStorage(SettingsKey.fontSize) private var fontSize: Double = ThemeStore.defaultFontSize
    @AppStorage(SettingsKey.fontFamily) private var fontFamily: String = MonospacedFonts.bundledDefault
    @AppStorage(SettingsKey.openLinksIn) private var openLinksIn: String = LinkOpenPreference.inApp.rawValue

    @State private var families: [String] = []
    @State private var showThemeImporter = false
    @State private var importError: String?

    /// - Parameter preview: the live terminal. Injected rather than built here
    ///   because the surface belongs to the engine layer (BentoGhosttyKit),
    ///   which this package must not depend on — the apps compose the two.
    public init(
        // The stepper must show what an untouched install actually RENDERS at,
        // so the default comes from the same constant the engine falls back to.
        defaultFontSize: Double = ThemeStore.defaultFontSize,
        preview: AnyView? = nil
    ) {
        self.preview = preview
        _fontSize = AppStorage(wrappedValue: defaultFontSize, SettingsKey.fontSize)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // On the page above the form rather than inside a form card: a
            // terminal nested in a grey rounded box reads as a text field with
            // monospaced text in it. (macOS's grouped form ignores
            // `listRowBackground`, so "a row with no card" is not an option.)
            if let preview {
                preview
                    .frame(height: 164)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
            }
            Form { controls }
                .bentoPanelForm()
        }
        .task {
            let installed = MonospacedFonts.families()
            families = installed
            // The one-time token → family-name migration. Writing it back here
            // means it happens the first time the picker is seen and never again.
            let normalized = MonospacedFonts.normalized(fontFamily, available: installed)
            if normalized != fontFamily {
                fontFamily = normalized
                NotificationCenter.default.post(name: .terminalFontChanged, object: nil)
            }
        }
        .fileImporter(isPresented: $showThemeImporter,
                      allowedContentTypes: ThemeImport.types) { result in
            handleThemeImport(result)
        }
    }

    @ViewBuilder
    private var controls: some View {
        Section {
            Picker("Appearance", selection: Binding(
                get: { themeStore.appearanceMode },
                set: { themeStore.appearanceMode = $0 }
            )) {
                ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            // Following the system means both slots are reachable without
            // touching Bento again, so both are worth setting. Pinned to
            // one, the other slot is a control that does nothing today.
            if themeStore.appearanceMode == .system {
                themePicker("Dark theme", forDark: true)
                themePicker("Light theme", forDark: false)
            } else {
                themePicker("Color theme", forDark: themeStore.appearanceMode == .dark)
            }

            // Imported themes join the pickers above; this is where they
            // come from and where they go.
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
            Button("Import iTerm2 Theme…") { showThemeImporter = true }
            if let importError {
                Label(importError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.caption)
            }
        } footer: {
            if themeStore.appearanceMode == .system {
                PanelNote("Bento switches between these two with the system.")
            }
        }

        Section {
            Picker("Open links in", selection: $openLinksIn) {
                Text("Bento").tag(LinkOpenPreference.inApp.rawValue)
                Text("Default browser").tag(LinkOpenPreference.system.rawValue)
            }
            .pickerStyle(.segmented)
            .onChange(of: openLinksIn) { _, raw in
                LinkRouter.preference = LinkOpenPreference(rawValue: raw) ?? .inApp
            }
        } footer: {
            PanelNote("A page opened in Bento sits beside the terminal, and a localhost address from a remote session is tunnelled there for you. Individual links can still be sent out with ⇧⌘-click.")
        }

        Section {
            Picker("Font", selection: $fontFamily) {
                ForEach(families, id: \.self) { Text($0).tag($0) }
            }
            .onChange(of: fontFamily) { _, _ in
                NotificationCenter.default.post(name: .terminalFontChanged, object: nil)
            }
            // `LabeledContent` keeps the value against the stepper on the
            // right, where every other row in this form puts its value. An
            // HStack with a Spacer left "Size" and "12" sitting together on
            // the left with the stepper stranded at the far edge.
            LabeledContent("Size") {
                HStack(spacing: 6) {
                    Text("\(Int(fontSize))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    // Committed per step, not per drag tick: a live surface
                    // reconfigures on `.terminalFontChanged`, and rebuilding
                    // it mid-drag crashed on iOS.
                    Stepper("Size", value: $fontSize, in: 8...24, step: 1)
                        .labelsHidden()
                        .onChange(of: fontSize) { _, _ in
                            NotificationCenter.default.post(name: .terminalFontChanged, object: nil)
                        }
                }
            }
        } header: { Text("Font") }
    }

    private func themePicker(_ label: String, forDark dark: Bool) -> some View {
        Picker(label, selection: Binding(
            get: { dark ? themeStore.darkThemeID : themeStore.lightThemeID },
            set: { themeStore.select(id: $0, forDark: dark) }
        )) {
            ForEach(themeStore.themes(forDark: dark)) { Text($0.name).tag($0.id) }
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
