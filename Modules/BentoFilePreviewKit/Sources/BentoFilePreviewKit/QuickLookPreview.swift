import SwiftUI
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import QuickLookUI
#elseif canImport(UIKit)
import UIKit
import QuickLook
#endif

// MARK: - The system preview, embedded

/// Quick Look as a plain view, not a panel — the preview has to live inside
/// the floating window AND the pinned dock tab, and `QLPreviewPanel` is
/// application-wide and takes the whole screen.
///
/// `stamp` is the file's modification date: the dock re-loads a watched file
/// in place, and Quick Look caches per item, so an unchanged URL still needs
/// an explicit refresh to show what the agent just wrote.
public struct QuickLookFileView: View {
    private let url: URL
    private let stamp: Date?

    public init(url: URL, stamp: Date? = nil) {
        self.url = url
        self.stamp = stamp
    }

    public var body: some View {
        // Both representables size from their content: QLPreviewView reports
        // the document's natural size as its intrinsic size, and a PDF page or
        // a video frame is wider than the dock. Without this the preview keeps
        // that width and stops tracking the panel — every other branch of the
        // preview switch already declares fill, so this one has to as well.
        Representable(url: url, stamp: stamp)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)

private struct Representable: NSViewRepresentable {
    let url: URL
    let stamp: Date?

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true          // video/audio don't need a second click
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if context.coordinator.url != url {
            context.coordinator.url = url
            context.coordinator.stamp = stamp
            view.previewItem = url as NSURL
        } else if context.coordinator.stamp != stamp {
            context.coordinator.stamp = stamp
            view.refreshPreviewItem()
        }
    }

    /// QLPreviewView holds a live rendering session; leaving it open when the
    /// tab closes keeps the extension (and the file) alive.
    static func dismantleNSView(_ view: QLPreviewView, coordinator: Coordinator) {
        view.close()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var url: URL?
        var stamp: Date?
    }
}

#elseif canImport(UIKit)

private struct Representable: UIViewControllerRepresentable {
    let url: URL
    let stamp: Date?

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        context.coordinator.url = url
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        guard context.coordinator.url != url || context.coordinator.stamp != stamp else { return }
        context.coordinator.url = url
        context.coordinator.stamp = stamp
        controller.reloadData()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL?
        var stamp: Date?

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            url == nil ? 0 : 1
        }

        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> QLPreviewItem {
            (url ?? URL(fileURLWithPath: "/dev/null")) as NSURL
        }
    }
}

#endif

// MARK: - Panel: fetch when needed, then preview

/// The `.quickLook` case of a preview. A local file goes straight to the
/// system renderer; a remote one has to come down first, so this is where the
/// size gate, the progress and the cancel live.
public struct QuickLookPanel: View {
    private let request: FileFetchRequest?
    private let localURL: URL?
    private let stamp: Date?
    private let hostLabel: String

    @StateObject private var fetch = FileFetchModel()
    @State private var fetched: URL?
    /// One automatic attempt per file. Without this a failed fetch would
    /// re-arm itself on every re-render and hammer the connection.
    @State private var started = false

    public init(data: FilePreviewData, url: URL?) {
        self.request = FileFetchRequest(data)
        self.localURL = url
        self.stamp = data.stat.modified
        self.hostLabel = data.hostLabel
    }

    public var body: some View {
        Group {
            if let url = localURL ?? fetched {
                QuickLookFileView(url: url, stamp: stamp)
            } else if let request {
                FileFetchStatusView(phase: fetch.phase, size: request.size,
                                    hostLabel: hostLabel,
                                    // A cancelled or failed fetch leaves the
                                    // panel with a way back in — otherwise the
                                    // only route is closing and re-opening.
                                    onStart: { started = false; begin() },
                                    onConfirm: { fetch.confirm() },
                                    onCancel: { fetch.cancel() })
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc").font(.system(size: 40)).foregroundStyle(.quaternary)
                    Text("No preview — this file can't be read from here.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { begin() }
    }

    private func begin() {
        guard localURL == nil, fetched == nil, !started, let request else { return }
        started = true
        fetch.request(request) { url in fetched = url }
    }
}

/// Shared wait/gate UI: what will happen, how far along it is, and a way out.
struct FileFetchStatusView: View {
    let phase: FileFetchModel.Phase
    let size: Int64
    let hostLabel: String
    let onStart: () -> Void
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            switch phase {
            case .idle:
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 34)).foregroundStyle(.secondary)
                Button("Download \(FilePreviewLoader.sizeLabel(size)) to preview", action: onStart)
            case .confirming(let bytes):
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 34)).foregroundStyle(.secondary)
                Text("Download \(FilePreviewLoader.sizeLabel(bytes)) from \(hostLabel) to preview it?")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Download", action: onConfirm)
            case .fetching(let received, let total):
                if total > 0 {
                    ProgressView(value: Double(received), total: Double(total))
                        .frame(maxWidth: 220)
                    Text("\(FilePreviewLoader.sizeLabel(received)) of \(FilePreviewLoader.sizeLabel(total))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
                Button("Cancel", action: onCancel)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 30)).foregroundStyle(.secondary)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again", action: onStart)
            }
        }
        .buttonStyle(.bordered)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
