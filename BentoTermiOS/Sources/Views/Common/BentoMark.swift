import SwiftUI

// MARK: - Shared form header

/// Drop into any `Section`'s `header:` closure to get a brand-consistent
/// section title (SF Pro 13 Semibold, sentence case, bento ink). Replaces
/// the system grouped-form's UPPERCASE gray header style.
struct BentoFormHeader: View {
    let title: String
    var trailing: String? = nil

    init(_ title: String, trailing: String? = nil) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.bentoInk)
                .textCase(nil)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.bentoInkDim)
                    .textCase(nil)
            }
        }
        .padding(.bottom, 2)
    }
}

/// Drop into any `Section`'s `footer:` closure for tinted footer copy.
struct BentoFormFooter: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Color.bentoInkDim)
            .textCase(nil)
    }
}

/// The Bento logo mark — 4 unequal compartments with rounded outer corners
/// and near-square inner corners. Geometry mirrors `docs/bento-icon.svg`.
/// Use anywhere we'd put a logo: toolbar wordmark, empty state, about screen.
struct BentoMark: View {
    var size: CGFloat = 22
    /// If non-nil, all four cells render in this tint (chrome usage).
    /// If nil, the four cells render in the full icon palette.
    var mono: Color? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: size, height: size)

            // Top-left — prompt cell (emerald)
            cell(outer: .topLeading, tint: mono ?? .bentoEmerald)
                .frame(width: size * 0.3125, height: size * 0.32)
                .offset(x: size * 0.078, y: size * 0.078)

            // Top-right — salmon
            cell(outer: .topTrailing, tint: mono ?? .bentoSalmon)
                .frame(width: size * 0.484, height: size * 0.32)
                .offset(x: size * 0.4375, y: size * 0.078)

            // Bottom-left — rice (warm white)
            cell(outer: .bottomLeading, tint: mono ?? .bentoRice)
                .frame(width: size * 0.640, height: size * 0.476)
                .offset(x: size * 0.078, y: size * 0.445)

            // Bottom-right — veg green
            cell(outer: .bottomTrailing, tint: mono ?? .bentoVeg)
                .frame(width: size * 0.156, height: size * 0.476)
                .offset(x: size * 0.766, y: size * 0.445)
        }
        .frame(width: size, height: size)
    }

    private var bigR: CGFloat { size * 0.18 }
    private var smallR: CGFloat { max(1, size * 0.025) }

    private enum Corner { case topLeading, topTrailing, bottomLeading, bottomTrailing }

    @ViewBuilder
    private func cell(outer: Corner, tint: Color) -> some View {
        let radii: RectangleCornerRadii = {
            switch outer {
            case .topLeading:
                return .init(topLeading: bigR, bottomLeading: smallR, bottomTrailing: smallR, topTrailing: smallR)
            case .topTrailing:
                return .init(topLeading: smallR, bottomLeading: smallR, bottomTrailing: smallR, topTrailing: bigR)
            case .bottomLeading:
                return .init(topLeading: smallR, bottomLeading: bigR, bottomTrailing: smallR, topTrailing: smallR)
            case .bottomTrailing:
                return .init(topLeading: smallR, bottomLeading: smallR, bottomTrailing: bigR, topTrailing: smallR)
            }
        }()
        UnevenRoundedRectangle(cornerRadii: radii, style: .continuous)
            .fill(tint)
    }
}

/// Hero variant for empty states — adds the `>` arrow and cursor block
/// inside the top-left prompt cell, matching the full icon.
struct BentoMarkHero: View {
    var size: CGFloat = 88

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Frame plate behind cells, gives the icon's "shell" look
            RoundedRectangle(cornerRadius: size * 0.20, style: .continuous)
                .fill(Color.bentoInset)
                .frame(width: size, height: size)

            // Cells
            BentoMark(size: size)

            // Prompt glyph (> + cursor) inside the top-left cell
            promptGlyph
                .frame(width: size * 0.28, height: size * 0.20)
                .offset(x: size * 0.10, y: size * 0.155)
        }
        .frame(width: size, height: size)
    }

    private var promptGlyph: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let stroke = max(2, w * 0.13)

            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: stroke / 2, y: stroke / 2))
                    p.addLine(to: CGPoint(x: w * 0.55, y: h / 2))
                    p.addLine(to: CGPoint(x: stroke / 2, y: h - stroke / 2))
                }
                .stroke(Color.bentoInset, style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round))

                // Cursor block
                RoundedRectangle(cornerRadius: stroke / 2, style: .continuous)
                    .fill(Color.bentoInset)
                    .frame(width: w * 0.32, height: stroke * 0.95)
                    .position(x: w * 0.80, y: h * 0.85)
            }
        }
    }
}
