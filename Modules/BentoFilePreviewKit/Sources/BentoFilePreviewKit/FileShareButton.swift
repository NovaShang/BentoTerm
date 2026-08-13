import SwiftUI
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Takes the file OUT of the app — `UIActivityViewController` on iOS,
/// `NSSharingServicePicker` on macOS. Over SSH, on a phone, this is often the
/// only way to get a file off the host at all.
///
/// Two rules this button exists to keep:
///
///  • It shares the FILE, as a URL to a copy under the file's real name.
///    Handing the system `Data` produces untitled, type-less attachments in
///    whatever receives them.
///
///  • It never shares what the preview rendered. Preview reads are capped head
///    reads (`FilePreviewLimits.textBytes`), so exporting that buffer would
///    hand over a file with the right name, the right icon, and everything
///    past 256KB missing — silent data loss the user has no way to notice.
///    The bytes always come from `FileFetch`, which only ever names a complete
///    copy.
///
/// It is also NOT gated on previewability: a PDF or an archive we can't draw
/// is exactly the file whose whole point is getting it out.
public struct FileShareButton: View {
    private let request: FileFetchRequest?
    private let hostLabel: String

    @StateObject private var fetch = FileFetchModel()
    @State private var anchor = ShareAnchor()

    public init?(data: FilePreviewData) {
        // A directory has nothing to hand over; so does a preview that arrived
        // without its pane context.
        guard let request = FileFetchRequest(data) else { return nil }
        self.request = request
        self.hostLabel = data.hostLabel
    }

    public var body: some View {
        content
            .background(ShareAnchorView(anchor: anchor))
            .confirmationDialog(confirmTitle, isPresented: confirming, titleVisibility: .visible) {
                Button("Download") { fetch.confirm() }
                Button("Cancel", role: .cancel) { fetch.cancel() }
            }
            .alert("Couldn't download this file", isPresented: failed) {
                Button("OK") { fetch.cancel() }
            } message: {
                Text(failureMessage)
            }
    }

    @ViewBuilder private var content: some View {
        switch fetch.phase {
        case .fetching(let received, let total):
            HStack(spacing: 6) {
                if total > 0 {
                    ProgressView(value: Double(received), total: Double(total))
                        .frame(width: 70)
                } else {
                    ProgressView().controlSize(.small)
                }
                Button("Cancel") { fetch.cancel() }
            }
        default:
            Button(action: start) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
    }

    private func start() {
        guard let request else { return }
        fetch.request(request) { url in present(url) }
    }

    // MARK: - Phase → SwiftUI bindings

    private var confirmTitle: String {
        guard case .confirming(let bytes) = fetch.phase else { return "" }
        return "Download \(FilePreviewLoader.sizeLabel(bytes)) from \(hostLabel) to share it?"
    }

    private var failureMessage: String {
        if case .failed(let message) = fetch.phase { return message }
        return ""
    }

    private var confirming: Binding<Bool> {
        Binding(
            get: { if case .confirming = fetch.phase { return true }; return false },
            // Dismissal fires AFTER the Download button's action, when the
            // phase has already moved on — cancelling on that would kill the
            // transfer the user just approved.
            set: { shown in
                if !shown, case .confirming = fetch.phase { fetch.cancel() }
            })
    }

    private var failed: Binding<Bool> {
        Binding(
            get: { if case .failed = fetch.phase { return true }; return false },
            set: { shown in if !shown, case .failed = fetch.phase { fetch.cancel() } })
    }

    // MARK: - Handing it to the system

    /// No cleanup here on purpose. Some share targets read the URL well after
    /// the sheet is gone, so deleting on completion races them; copies are
    /// reaped by `FileFetch`'s TTL sweep instead. And for a local file this URL
    /// IS the user's file — deleting it would be a catastrophe.
    private func present(_ url: URL) {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        guard let view = anchor.view else { return }
        let picker = NSSharingServicePicker(items: [url])
        anchor.picker = picker      // the picker is not retained by `show`
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        #elseif canImport(UIKit)
        guard let view = anchor.view, var top = view.owningViewController else { return }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // iPad has no sheet to fall back on: an activity controller without a
        // source view traps at presentation time.
        activity.popoverPresentationController?.sourceView = view
        activity.popoverPresentationController?.sourceRect = view.bounds
        top.present(activity, animated: true)
        #endif
    }
}

// MARK: - Anchor

/// Holds the platform view the share UI hangs off (a popover needs a rect on
/// screen, and SwiftUI won't give one up).
private final class ShareAnchor {
    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    weak var view: NSView?
    /// `show(relativeTo:…)` doesn't keep the picker alive; without this the
    /// menu can vanish before it is used.
    var picker: NSSharingServicePicker?
    #elseif canImport(UIKit)
    weak var view: UIView?
    #endif
}

private struct ShareAnchorView {
    let anchor: ShareAnchor
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)

extension ShareAnchorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Sits behind the button purely as a coordinate anchor — it must never take
/// the click that was meant for the button in front of it.
private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

#elseif canImport(UIKit)

extension ShareAnchorView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = PassthroughView()
        view.isUserInteractionEnabled = false
        anchor.view = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

private final class PassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

private extension UIView {
    /// The controller to present from — walking the responder chain, because a
    /// preview lives inside a sheet and the root controller is the wrong host.
    var owningViewController: UIViewController? {
        sequence(first: self as UIResponder, next: { $0.next })
            .first { $0 is UIViewController } as? UIViewController
    }
}

#endif
