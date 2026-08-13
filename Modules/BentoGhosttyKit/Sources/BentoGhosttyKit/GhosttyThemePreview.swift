import SwiftUI
import BentoFoundationKit
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// A live terminal for the Appearance panel: a real ghostty surface with no
/// process behind it, fed a fixed scrap of agent output.
///
/// **Why a real surface and not a SwiftUI mock-up.** A drawn imitation would
/// need its own copy of theme parsing, ANSI-to-color mapping and font metrics —
/// a second implementation of the thing being previewed, free to disagree with
/// the real one. The surface already has all of it, and the live theme/font
/// paths (`applyTheme`, `.terminalThemeChanged`, `.terminalFontChanged`) are
/// the same ones every open pane uses, so the preview gets them for nothing.
///
/// Three constraints, each of which has bitten before:
///  * **No pty, no shell.** `TerminalSurface.feed(_:)` takes bytes; a preview
///    doesn't need a process to produce them.
///  * **A font-size change recreates the surface** (`applyTheme` rebuilds it so
///    the new metrics take effect), which empties the screen. So the canned
///    bytes are re-fed after every theme application, and they begin with an
///    erase so re-feeding can't stack copies.
///  * **One surface per host window, torn down once.** Building and freeing
///    surfaces repeatedly is where teardown crashes come from; changing a
///    setting must never create a new one.
public struct GhosttyThemePreview: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            PreviewTitleBar()
            GhosttyThemePreviewRepresentable()
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
    }
}

/// The pane title bar over the preview.
///
/// Without it the preview reads as a text field with monospaced text in it —
/// it is a terminal, and what makes a Bento pane recognisable as one is the
/// title strip with the state dot. It also puts the state colour in front of
/// the user one page before the Agents panel explains it.
struct PreviewTitleBar: View {
    /// The working blue, from the same constant the real chrome reads.
    private static let working = Color(
        .sRGB,
        red: Double((0x0A85FF >> 16) & 0xFF) / 255,
        green: Double((0x0A85FF >> 8) & 0xFF) / 255,
        blue: Double(0x0A85FF & 0xFF) / 255,
        opacity: 1)

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Self.working)
                .frame(width: 7, height: 7)
            Text("claude")
                .font(.system(size: 11, weight: .medium))
            Text("~/code/bento-term")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 8)
            Text("2m14s")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Self.working.opacity(0.12))
    }
}

/// The sample. Agent output rather than `git status`: it is what this app is
/// for, and it puts a pane title bar with a live state color in front of the
/// user one page before the Agents panel explains it.
enum GhosttyThemePreviewContent {
    static var bytes: Data {
        // Erase + home first: `applyTheme` may have rebuilt the surface, and a
        // re-feed must replace the screen rather than append to it.
        let reset = "\u{1b}[2J\u{1b}[H"
        // Seven rows, sized to the preview box. Longer content simply scrolls
        // off the top — the surface is a real terminal, so it scrolls like one,
        // and the first thing anyone saw was a sample missing its first line.
        let lines = [
            "\u{1b}[38;5;39m⏺\u{1b}[0m Read \u{1b}[1msrc/parser.swift\u{1b}[0m (412 lines)",
            "\u{1b}[38;5;39m⏺\u{1b}[0m Bash(\u{1b}[3mswift test --filter Parser\u{1b}[0m)",
            "  \u{1b}[90m⎿\u{1b}[0m \u{1b}[32mTest Suite 'ParserTests' passed\u{1b}[0m",
            "",
            "\u{1b}[38;5;39m⏺\u{1b}[0m Found it: the escape sequence is consumed twice",
            "  when the buffer wraps. Want me to fix it?",
            "\u{1b}[33m❯\u{1b}[0m ",
        ]
        return Data((reset + lines.joined(separator: "\r\n")).utf8)
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)

struct GhosttyThemePreviewRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> GhosttyThemePreviewHost { GhosttyThemePreviewHost() }
    func updateNSView(_ nsView: GhosttyThemePreviewHost, context: Context) {}
    static func dismantleNSView(_ nsView: GhosttyThemePreviewHost, coordinator: ()) {
        nsView.teardownPreview()
    }
}

/// Owns the one surface and keeps it fed. An `NSView`/`UIView` rather than a
/// coordinator because the surface IS a view and its lifetime should be the
/// container's, not a SwiftUI value's.
final class GhosttyThemePreviewHost: NSView {
    private var surface: GhosttyTerminalSurface?
    private var observers: [NSObjectProtocol] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        let theme = ThemeStore.shared.makeTerminalTheme()
        let surface = GhosttyTerminalSurface(theme: theme)
        surface.debugLabel = "theme-preview"
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // A preview never takes keystrokes; leaving it unfocused also keeps the
        // engine from reporting focus events for a surface with no session.
        surface.setFocus(false)
        self.surface = surface
        feed()
        observe()
    }

    private func observe() {
        for name in [Notification.Name.terminalThemeChanged, .terminalFontChanged] {
            let token = NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reapplyTheme() }
            }
            observers.append(token)
        }
    }

    private func reapplyTheme() {
        surface?.applyTheme(ThemeStore.shared.makeTerminalTheme())
        // The theme application may have rebuilt the surface (font size), which
        // wipes the screen — put the sample back.
        feed()
    }

    private func feed() {
        surface?.feed(GhosttyThemePreviewContent.bytes)
    }

    func teardownPreview() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        surface?.teardown()
        surface = nil
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}

#elseif canImport(UIKit)

struct GhosttyThemePreviewRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> GhosttyThemePreviewHost { GhosttyThemePreviewHost() }
    func updateUIView(_ uiView: GhosttyThemePreviewHost, context: Context) {}
    static func dismantleUIView(_ uiView: GhosttyThemePreviewHost, coordinator: ()) {
        uiView.teardownPreview()
    }
}

final class GhosttyThemePreviewHost: UIView {
    private var surface: GhosttyTerminalSurface?
    private var observers: [NSObjectProtocol] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        let theme = ThemeStore.shared.makeTerminalTheme()
        let surface = GhosttyTerminalSurface(theme: theme)
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        surface.setFocus(false)
        surface.isUserInteractionEnabled = false
        self.surface = surface
        feed()
        observe()
    }

    private func observe() {
        for name in [Notification.Name.terminalThemeChanged, .terminalFontChanged] {
            let token = NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reapplyTheme() }
            }
            observers.append(token)
        }
    }

    private func reapplyTheme() {
        surface?.applyTheme(ThemeStore.shared.makeTerminalTheme())
        feed()
    }

    private func feed() {
        surface?.feed(GhosttyThemePreviewContent.bytes)
    }

    func teardownPreview() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        surface?.teardown()
        surface = nil
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}

#endif
