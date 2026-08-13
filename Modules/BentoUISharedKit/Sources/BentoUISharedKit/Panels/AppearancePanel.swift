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

/// ① Appearance — colors, font, size, and a live terminal beside them.
///
/// **No prose, on purpose.** Every other panel teaches something the controls
/// can't show; this one puts a real terminal where the prose would go, which
/// explains more than a sentence about it could. See `PanelBody`'s note.
///
/// **Three dropdowns here, three cards on the Speech panel — same judgement,
/// opposite answer.** Themes and fonts are open-ended (import a theme, install
/// a font) and the preview already does the "see it without opening a menu"
/// job. Speech has exactly three engines whose costs differ sharply and
/// nothing that can preview them, so those get laid out where they can't be
/// missed.
public struct AppearancePanel<Advanced: View>: View {
    private let context: PanelContext
    private let preview: AnyView?
    private let advanced: Advanced

    @ObservedObject private var themeStore = ThemeStore.shared

    @AppStorage(SettingsKey.fontSize) private var fontSize: Double = 12
    @AppStorage(SettingsKey.fontFamily) private var fontFamily: String = MonospacedFonts.bundledDefault

    @State private var families: [String] = []
    @State private var showThemeImporter = false
    @State private var importError: String?

    /// - Parameters:
    ///   - preview: the live terminal. Injected rather than built here because
    ///     the surface belongs to the engine layer (BentoGhosttyKit), which
    ///     this package must not depend on — the apps compose the two.
    ///   - advanced: platform-only rows, rendered INSIDE this panel's own
    ///     Advanced disclosure. Passing them as a sibling block is what put two
    ///     rows labelled "Advanced" one under the other on the first page.
    public init(
        context: PanelContext,
        defaultFontSize: Double = 12,
        preview: AnyView? = nil,
        @ViewBuilder advanced: () -> Advanced = { EmptyView() }
    ) {
        self.context = context
        self.preview = preview
        self.advanced = advanced()
        _fontSize = AppStorage(wrappedValue: defaultFontSize, SettingsKey.fontSize)
    }

    public var body: some View {
        PanelBody(context) {
            // The preview takes the explanation slot: it sits on the page above
            // the controls rather than inside a form card, because a terminal
            // nested in a grey rounded box reads as a text field with
            // monospaced text in it.
            if let preview {
                preview
                    .frame(height: 164)
                    .frame(maxWidth: .infinity)
            }
        } controls: {
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
            } footer: {
                if themeStore.appearanceMode == .system {
                    PanelNote("Bento switches between these two with the system.")
                }
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

            AdvancedBlock(context) {
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
                advanced
            }
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
