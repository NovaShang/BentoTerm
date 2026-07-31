import UIKit
import SwiftUI
import BentoTerminalCore

// MARK: - Tap chip

/// Floating confirmation chip shown when a tap lands on a recognized file
/// path: [doc icon] filename ›. Tapping it opens the preview sheet; it
/// auto-dismisses after a few seconds. The extra step keeps ordinary
/// pane-selection taps cheap, forgives detection false-positives, and masks
/// the stat round-trip on slow links.
final class PathPreviewChip: UIControl {
    var onTap: (() -> Void)?

    private let icon = UIImageView()
    private let label = UILabel()
    private let chevron = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = BentoBrand.surface
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = BentoBrand.border.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 4)

        let cfg = UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        icon.image = UIImage(systemName: "doc.text", withConfiguration: cfg)
        icon.tintColor = BentoBrand.emerald

        label.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        label.textColor = BentoBrand.inkPrimary
        label.lineBreakMode = .byTruncatingMiddle

        chevron.image = UIImage(systemName: "chevron.right",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        chevron.tintColor = .tertiaryLabel

        let stack = UIStackView(arrangedSubviews: [icon, label, chevron])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(fileName: String, maxWidth: CGFloat) {
        label.text = fileName
        let fit = systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        bounds.size = CGSize(width: min(fit.width, maxWidth), height: fit.height)
    }

    @objc private func tapped() { onTap?() }
}

/// Brief underline/wash over the detected token, mirroring the macOS ⌘hover
/// highlight so the user sees exactly what the chip refers to.
final class PathHighlightUIView: UIView {
    var rects: [CGRect] = [] { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let accent = BentoBrand.emerald
        for r in rects {
            ctx.setFillColor(accent.withAlphaComponent(0.16).cgColor)
            let path = UIBezierPath(roundedRect: r.insetBy(dx: -1, dy: 0), cornerRadius: 3)
            ctx.addPath(path.cgPath)
            ctx.fillPath()
            ctx.setFillColor(accent.withAlphaComponent(0.9).cgColor)
            ctx.fill(CGRect(x: r.minX, y: r.maxY - 1.5, width: r.width, height: 1.5))
        }
    }
}

// MARK: - Preview sheet

@MainActor
final class FilePreviewSheetModel: ObservableObject {
    enum Phase {
        case loading(path: String)
        case loaded(FilePreviewData)
        case failed(path: String, message: String)
    }
    @Published var phase: Phase

    init(path: String) {
        phase = .loading(path: path)
    }

    func load(path: String, line: Int?, context: PathPreviewContext) {
        Task { [weak self] in
            do {
                let data = try await FilePreviewLoader.load(path: path, line: line, context: context)
                self?.phase = .loaded(data)
            } catch {
                self?.phase = .failed(path: path, message: error.localizedDescription)
            }
        }
    }
}

struct FilePreviewSheet: View {
    @ObservedObject var model: FilePreviewSheetModel

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
                        .padding(.horizontal, 24)
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
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let data):
                loaded(data)
            }
        }
        .background(Color(BentoBrand.shell))
    }

    private func loaded(_ data: FilePreviewData) -> some View {
        VStack(spacing: 0) {
            header(data)
            Divider()
            content(data)
            Divider()
            footer(data)
        }
    }

    private func header(_ data: FilePreviewData) -> some View {
        HStack(spacing: 10) {
            Image(systemName: iconName(data))
                .font(.system(size: 22))
                .foregroundStyle(Color(BentoBrand.emerald))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(data.fileName)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let line = data.line {
                        Text("line \(line)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color(BentoBrand.border).opacity(0.5)))
                    }
                }
                Text(data.resolvedPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle(data))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    private func subtitle(_ data: FilePreviewData) -> String {
        var parts = [FilePreviewLoader.sizeLabel(data.stat.size)]
        if let m = data.stat.modified {
            parts.append(m.formatted(date: .abbreviated, time: .shortened))
        }
        parts.append(data.hostLabel)
        return parts.joined(separator: " · ")
    }

    private func iconName(_ data: FilePreviewData) -> String {
        switch data.content {
        case .directory: return "folder"
        case .image: return "photo"
        case .binary: return "doc"
        case .text: return "doc.text"
        }
    }

    @ViewBuilder private func content(_ data: FilePreviewData) -> some View {
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
                        .padding(.vertical, 5)
                        .background(Color(BentoBrand.border).opacity(0.35))
                }
            }
        case .image(let bytes):
            if let img = UIImage(data: bytes) {
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: UIScreen.main.bounds.width)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                unsupported("Couldn't decode this image.", icon: "photo")
            }
        case .binary:
            unsupported("Binary file — no inline preview.", icon: "doc")
        case .directory:
            unsupported("This is a directory.", icon: "folder")
        }
    }

    private func unsupported(_ note: String, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(.quaternary)
            Text(note).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func footer(_ data: FilePreviewData) -> some View {
        HStack {
            Button {
                UIPasteboard.general.string = data.resolvedPath
                HapticService.shared.sent()
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
                    .font(.system(size: 13, weight: .medium))
            }
            .tint(Color(BentoBrand.emerald))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// Web-based text/code/markdown renderer (highlight.js + markdown-it inside
/// core's `FilePreviewWebView`) — one implementation shared with the macOS
/// panel: syntax colors, rendered markdown, line gutter, `path:42` jump.
private struct WebPreviewText: UIViewRepresentable {
    let fileName: String
    let text: String
    let line: Int?
    var imageBase: FilePreviewWebView.ImageBase? = nil
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> FilePreviewWebView {
        FilePreviewWebView.makePreview()
    }

    func updateUIView(_ view: FilePreviewWebView, context: Context) {
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
        /// Content hash, not length — a reloaded file can change in place.
        let textHash: Int
        let line: Int?
    }

    final class Coordinator {
        var rendered: RenderKey?
    }
}
