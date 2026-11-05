import UIKit
import SwiftUI
import BentoSessionKit
import BentoFoundationKit
import BentoFilePreviewKit
import BentoGhosttyKit

// MARK: - Tap chip

/// Floating confirmation chip shown when a tap lands on something Bento can
/// open — a file path ([doc icon] filename ›) or a URL ([link icon] host/… ›).
/// Tapping the chip is what actually opens it; it auto-dismisses after a few
/// seconds. The extra step keeps ordinary pane-selection taps cheap, forgives
/// detection false-positives, masks the stat round-trip on slow links, and on
/// a touch screen keeps a mistap from launching the browser.
final class TapConfirmChip: UIControl {
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

        icon.image = UIImage(systemName: "doc.text", withConfiguration: Self.iconConfig)
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

    private static let iconConfig = UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)

    func configure(fileName: String, maxWidth: CGFloat) {
        icon.image = UIImage(systemName: "doc.text", withConfiguration: Self.iconConfig)
        label.text = fileName
        sizeToChipFit(maxWidth: maxWidth)
    }

    /// Link variant: the URL itself is the label, elided in the middle so the
    /// host and the tail — who is being opened, and which page — both survive.
    func configure(link: String, maxWidth: CGFloat) {
        icon.image = UIImage(systemName: "link", withConfiguration: Self.iconConfig)
        label.text = LinkChipText.display(for: link, maxChars: Self.linkMaxChars)
        sizeToChipFit(maxWidth: maxWidth)
    }

    /// Dev-server variant: the port IS the name. On a phone the full
    /// `http://localhost:5173/` is most of the screen and all of it is
    /// boilerplate except those four digits.
    func configure(devServerPort port: Int, maxWidth: CGFloat) {
        icon.image = UIImage(systemName: "globe", withConfiguration: Self.iconConfig)
        label.text = "Open :\(port)"
        sizeToChipFit(maxWidth: maxWidth)
    }

    /// Character budget for a link label. Chosen for the narrowest phone: the
    /// chip is monospaced 13pt, so this is a width the layout can honour
    /// without the label truncating a second time.
    private static let linkMaxChars = 34

    private func sizeToChipFit(maxWidth: CGFloat) {
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

struct FilePreviewSheet: View {
    @ObservedObject var model: FilePreviewLoadModel

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                VStack(spacing: 12) {
                    ProgressView()
                    Text(model.path)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                VStack(spacing: 10) {
                    Image(systemName: "questionmark.folder")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text(model.path)
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
            content(data)
                .padding(.top, 18)   // room under the sheet grabber
            Divider()
            footer(data)
        }
    }

    /// The sheet's sizes for the shared body: phone-sized notes, and the
    /// truncation bar tinted with the brand border instead of a system fill.
    private static let bodyStyle = FilePreviewContentBody.Style(
        noteFontSize: 13, truncationPadding: 5,
        truncationFill: AnyShapeStyle(Color(BentoBrand.border).opacity(0.35)))

    private func content(_ data: FilePreviewData) -> some View {
        FilePreviewContentBody(data: data, style: Self.bodyStyle)
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
            // The way a file leaves the phone: Files, AirDrop, another app.
            // Offered for anything that resolved, including the formats the
            // sheet above couldn't draw.
            if let share = FileShareButton(data: data) {
                share
                    .font(.system(size: 15, weight: .medium))
                    .tint(Color(BentoBrand.emerald))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
