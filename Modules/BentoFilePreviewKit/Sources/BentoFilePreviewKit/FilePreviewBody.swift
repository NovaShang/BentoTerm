import SwiftUI
import WebKit
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - Load state

/// One file preview's load state: loading → loaded / failed. The Mac dock tab
/// and the iOS sheet both used to carry this machine; fetching itself is
/// already one call (`FilePreviewLoader`) and stays behind the pane's context —
/// the Mac reads its own disk or the remote over ssh, the phone reads SFTP.
@MainActor
public final class FilePreviewLoadModel: ObservableObject {
    public enum Phase {
        case loading
        case loaded(FilePreviewData)
        case failed(String)
    }
    @Published public private(set) var phase: Phase

    public let path: String
    public let line: Int?
    public let context: PathPreviewContext

    private var task: Task<Void, Never>?

    /// `initial` seeds the first render when the caller already has it;
    /// otherwise the model starts loading straight away.
    public init(path: String, line: Int?, context: PathPreviewContext,
                initial: FilePreviewData? = nil) {
        self.path = path
        self.line = line
        self.context = context
        self.phase = initial.map(Phase.loaded) ?? .loading
        if initial == nil { reload() }
    }

    /// Fetch again. The previous fetch is cancelled and can no longer land, so
    /// a slow read can't overwrite a newer one (a watched file changing twice).
    /// The current content stays on screen until the new one arrives.
    public func reload() {
        task?.cancel()
        let path = path, line = line, context = context
        task = Task { @MainActor [weak self] in
            do {
                let data = try await FilePreviewLoader.load(path: path, line: line, context: context)
                guard !Task.isCancelled else { return }
                self?.phase = .loaded(data)
            } catch {
                guard !Task.isCancelled else { return }
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    public func cancel() { task?.cancel() }
}

// MARK: - Loaded content

/// The body of a loaded preview — text through the web renderer, Quick Look
/// for what the system draws better, a note for the rest. Shared by the Mac
/// dock and the iOS sheet; each wraps it in its own header/footer. `Style`
/// carries the few metrics the two chromes size differently.
public struct FilePreviewContentBody: View {
    public struct Style {
        public var noteFontSize: CGFloat
        public var truncationPadding: CGFloat
        public var truncationFill: AnyShapeStyle

        public init(noteFontSize: CGFloat, truncationPadding: CGFloat,
                    truncationFill: AnyShapeStyle) {
            self.noteFontSize = noteFontSize
            self.truncationPadding = truncationPadding
            self.truncationFill = truncationFill
        }
    }

    let data: FilePreviewData
    let style: Style

    public init(data: FilePreviewData, style: Style) {
        self.data = data
        self.style = style
    }

    public var body: some View {
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
                        .padding(.vertical, style.truncationPadding)
                        .background(style.truncationFill)
                }
            }
        case .quickLook(let url):
            // PDF, Office, iWork, video, audio, images — the system renders
            // these. A local file has its URL already; a remote one downloads
            // inside the panel (gated + cancellable) before Quick Look sees it.
            QuickLookPanel(data: data, url: url)
        case .binary:
            unsupported("Binary file — no inline preview.", icon: "doc")
        case .directory:
            unsupported("This is a directory.", icon: "folder")
        }
    }

    private func unsupported(_ note: String, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(.quaternary)
            Text(note).font(.system(size: style.noteFontSize)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Web text

/// Web-based text/code/markdown renderer (highlight.js + markdown-it inside
/// `FilePreviewWebView`): syntax colours, rendered markdown, line gutter,
/// `path:42` jump. The representable is the only per-platform part.
struct WebPreviewText {
    let fileName: String
    let text: String
    let line: Int?
    var imageBase: FilePreviewWebView.ImageBase? = nil
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor fileprivate func update(_ view: FilePreviewWebView, _ coordinator: Coordinator) {
        let dark = colorScheme == .dark
        let key = RenderKey(fileName: fileName, textHash: text.hashValue, line: line)
        if coordinator.rendered != key {
            coordinator.rendered = key
            view.render(fileName: fileName, text: text, line: line, dark: dark,
                        imageBase: imageBase)
        } else {
            view.setDark(dark)
        }
    }

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

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
extension WebPreviewText: NSViewRepresentable {
    func makeNSView(context: Context) -> FilePreviewWebView { FilePreviewWebView.makePreview() }
    func updateNSView(_ view: FilePreviewWebView, context: Context) { update(view, context.coordinator) }
}
#elseif canImport(UIKit)
extension WebPreviewText: UIViewRepresentable {
    func makeUIView(context: Context) -> FilePreviewWebView { FilePreviewWebView.makePreview() }
    func updateUIView(_ view: FilePreviewWebView, context: Context) { update(view, context.coordinator) }
}
#endif
