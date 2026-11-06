import SwiftUI

/// Settings' three pages, in order, on both platforms. Owned here so the Mac's
/// tabs and the iPhone's list can't disagree about what exists or what it is
/// called.
///
/// Each page is one shared panel (`AppearancePanel`, `VoicePanel`,
/// `GeneralPanel`) with the platform's own rows passed in, so every setting
/// has exactly one implementation. Nothing is folded behind "How this works"
/// or "Advanced": a page either shows a control or doesn't have it.
public enum SettingsPage: String, CaseIterable, Identifiable, Sendable {
    case appearance, voice, general

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .voice:      return "Voice"
        case .general:    return "General"
        }
    }

    public var symbol: String {
        switch self {
        case .appearance: return "paintpalette"
        case .voice:      return "mic"
        case .general:    return "gearshape"
        }
    }
}

// MARK: - Notes

/// A footnote under a control — the sentence the control itself can't say.
public struct PanelNote: View {
    private let text: LocalizedStringKey

    public init(_ text: LocalizedStringKey) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A warning that earns its place on the page: something is wrong now and the
/// user will otherwise discover it as a mystery.
public struct PanelWarning<Actions: View>: View {
    private let text: LocalizedStringKey
    private let actions: Actions

    public init(_ text: LocalizedStringKey, @ViewBuilder actions: () -> Actions) {
        self.text = text
        self.actions = actions()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(text)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 8) { actions }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Form plumbing

extension View {
    /// The form chrome every Settings page wants, kept in one place so the
    /// pages can't drift into looking like different apps.
    public func bentoPanelForm() -> some View {
        #if os(macOS)
        return self.formStyle(.grouped)
        #else
        return self
        #endif
    }
}
