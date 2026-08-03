import BentoFilePreviewKit
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import SwiftUI
import BentoSessionKit
import BentoFoundationKit

// MARK: - Preview panel

/// One floating preview panel for the whole app (a new preview replaces the
/// current one, like Quick Look). Esc or the close button dismisses.
@MainActor
public final class FilePreviewPanelController {
    public static let shared = FilePreviewPanelController()
    private init() {}

    private var panel: NSPanel?
    private var model = FilePreviewPanelModel()

    /// The optional detached "Open in Window" surface — a floating panel a dock
    /// tab pops out into. (Previews open in the side dock by default now.)
    public func present(path: String, line: Int?, context: PathPreviewContext,
                        nearScreenPoint point: NSPoint) {
        let panel = ensurePanel(near: point)
        model.load(path: path, line: line, context: context)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Last user-chosen panel size, persisted across launches ("820x620").
    static let sizeKey = "path_preview_panel_size"

    private func preferredSize(near point: NSPoint) -> NSSize {
        let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) })
            ?? NSScreen.main
        // Default: comfortable code width, near-full height — files are tall.
        var size = NSSize(width: 820, height: (screen?.visibleFrame.height ?? 900) - 24)
        if let parts = UserDefaults.standard.string(forKey: Self.sizeKey)?.split(separator: "x"),
           parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]),
           w >= 420, h >= 280 {
            size = NSSize(width: w, height: h)
        }
        // Never larger than the screen the click happened on.
        if let vis = screen?.visibleFrame {
            size.width = min(size.width, vis.width - 32)
            size.height = min(size.height, vis.height - 16)
        }
        return size
    }

    private func ensurePanel(near point: NSPoint) -> NSPanel {
        if let panel { position(panel, near: point); return panel }
        let p = EscClosablePanel(
            contentRect: NSRect(origin: .zero, size: preferredSize(near: point)),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .utilityWindow],
            backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = false
        p.isReleasedWhenClosed = false
        p.minSize = NSSize(width: 420, height: 280)
        p.delegate = p          // saves the size the user resizes to
        p.contentView = NSHostingView(rootView: FilePreviewPanelRoot(model: model))
        position(p, near: point)
        panel = p
        return p
    }

    /// Place the panel near the click, clamped inside the screen.
    private func position(_ panel: NSPanel, near point: NSPoint) {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) })
            ?? NSScreen.main else { return }
        let size = panel.frame.size
        var origin = NSPoint(x: point.x + 12, y: point.y - size.height - 12)
        let vis = screen.visibleFrame
        origin.x = min(max(origin.x, vis.minX + 8), vis.maxX - size.width - 8)
        origin.y = min(max(origin.y, vis.minY + 8), vis.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
    }
}

/// NSPanel that closes on Esc (cancelOperation) — Quick Look muscle memory —
/// and remembers the size the user drags it to.
private final class EscClosablePanel: NSPanel, NSWindowDelegate {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }

    func windowDidEndLiveResize(_ notification: Notification) {
        UserDefaults.standard.set("\(Int(frame.width))x\(Int(frame.height))",
                                  forKey: FilePreviewPanelController.sizeKey)
    }
}

// MARK: - Model

@MainActor
final class FilePreviewPanelModel: ObservableObject {
    enum Phase {
        case loading(path: String)
        case loaded(FilePreviewData)
        case failed(path: String, message: String)
    }
    @Published var phase: Phase = .loading(path: "")

    private var task: Task<Void, Never>?

    func load(path: String, line: Int?, context: PathPreviewContext) {
        task?.cancel()
        phase = .loading(path: path)
        task = Task { [weak self] in
            do {
                let data = try await FilePreviewLoader.load(path: path, line: line, context: context)
                guard !Task.isCancelled else { return }
                self?.phase = .loaded(data)
            } catch {
                guard !Task.isCancelled else { return }
                self?.phase = .failed(path: path, message: error.localizedDescription)
            }
        }
    }
}

// MARK: - SwiftUI content

struct FilePreviewPanelRoot: View {
    @ObservedObject var model: FilePreviewPanelModel

    var body: some View {
        Group {
            switch model.phase {
            case .loading(let path):
                VStack(spacing: 12) {
                    ProgressView()
                    Text(path)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let path, let message):
                VStack(spacing: 10) {
                    Image(systemName: "questionmark.folder")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text(path)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let data):
                FilePreviewContentView(data: data)   // the detached window itself
            }
        }
        .frame(minWidth: 420, minHeight: 280)
    }
}

struct FilePreviewContentView: View {
    let data: FilePreviewData
    /// Non-nil in the dock → shows an "Open in Window" button that pops the tab
    /// out into a floating window. Nil in that floating window itself.
    var onDetach: (() -> Void)? = nil
    /// The floating window closes on Esc; the docked view doesn't.
    var showsEscHint: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(data.fileName).font(.system(size: 13, weight: .semibold))
                    if let line = data.line {
                        Text("line \(line)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(data.resolvedPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 26)          // room under the transparent titlebar
        .padding(.bottom, 10)
    }

    private var subtitle: String {
        var parts = [FilePreviewLoader.sizeLabel(data.stat.size)]
        if let m = data.stat.modified {
            parts.append(m.formatted(date: .abbreviated, time: .shortened))
        }
        parts.append(data.hostLabel)
        return parts.joined(separator: " · ")
    }

    private var iconName: String {
        switch data.content {
        case .directory: return "folder"
        case .image: return "photo"
        case .binary: return "doc"
        case .text: return "doc.text"
        }
    }

    @ViewBuilder private var content: some View {
        switch data.content {
        case .text(let text, let truncated):
            VStack(spacing: 0) {
                if text.isEmpty {
                    Text("(empty file)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    WebPreviewText(fileName: data.fileName, text: text, line: data.line,
                                   imageBase: data.context.map {
                                       .init(directory: (data.resolvedPath as NSString).deletingLastPathComponent,
                                             source: $0.source)
                                   })
                }
                if truncated {
                    Text("Showing the first \(FilePreviewLoader.sizeLabel(Int64(FilePreviewLimits.textBytes))) of \(FilePreviewLoader.sizeLabel(data.stat.size))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(.quaternary.opacity(0.5))
                }
            }
        case .image(let bytes):
            if let img = NSImage(data: bytes) {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 1200, maxHeight: 1200)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                unsupported("Couldn't decode this image.")
            }
        case .binary:
            unsupported("Binary file — no inline preview.")
        case .directory:
            unsupported("This is a directory.")
        }
    }

    private func unsupported(_ note: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: iconName).font(.system(size: 40)).foregroundStyle(.quaternary)
            Text(note).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(data.resolvedPath, forType: .string)
            }
            if data.isLocal {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: data.resolvedPath)])
                }
                Button("Open") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: data.resolvedPath))
                }
            }
            if let onDetach {
                Button(action: onDetach) { Label("Open in Window", systemImage: "macwindow") }
            }
            Spacer()
            if showsEscHint {
                Text("esc to close")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// Web-based text/code/markdown renderer (highlight.js + markdown-it inside
/// `FilePreviewWebView`) — one implementation shared with the iOS sheet.
private struct WebPreviewText: NSViewRepresentable {
    let fileName: String
    let text: String
    let line: Int?
    var imageBase: FilePreviewWebView.ImageBase? = nil
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> FilePreviewWebView {
        FilePreviewWebView.makePreview()
    }

    func updateNSView(_ view: FilePreviewWebView, context: Context) {
        let dark = colorScheme == .dark
        let key = RenderKey(fileName: fileName, textHash: text.hashValue, line: line)
        if context.coordinator.rendered != key {
            context.coordinator.rendered = key
            view.render(fileName: fileName, text: text, line: line, dark: dark,
                        imageBase: imageBase)
        } else {
            view.setDark(dark)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    struct RenderKey: Equatable {
        let fileName: String
        /// Content hash, not length — a watched file can change without
        /// changing size (an agent replacing characters in place).
        let textHash: Int
        let line: Int?
    }

    final class Coordinator {
        var rendered: RenderKey?
    }
}
#endif
