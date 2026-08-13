import SwiftUI
import UIKit

// MARK: - Shared form header

/// Drop into any `Section`'s `header:` closure to get a brand-consistent
/// section title (SF Pro 13 Semibold, sentence case, bento ink). Replaces
/// the system grouped-form's UPPERCASE gray header style.
struct BentoFormHeader<Action: View>: View {
    let title: String
    var trailing: String? = nil
    private let action: Action

    init(_ title: String, trailing: String? = nil,
         @ViewBuilder action: () -> Action = { EmptyView() }) {
        self.title = title
        self.trailing = trailing
        self.action = action()
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
            action
                .font(.system(size: 12, weight: .medium))
                .textCase(nil)
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

/// The Bento logo mark — the current app-icon design, ported from
/// `docs/bento-icon.svg`: grey-gradient shell holding four dark-gradient
/// compartments with the emerald prompt chevron in the top-left cell.
/// Use anywhere we'd put a logo: toolbar wordmark, empty state, about screen.
struct BentoMark: View {
    /// Corner radius as a fraction of the icon's width, for the `.continuous`
    /// (squircle) shape iOS masks home-screen icons with. The drawn mark used
    /// 0.1406 — the radius in the source SVG's own square, which is NOT what
    /// the user ever sees, because the system rounds the icon further. Beside a
    /// real app icon the difference reads as "the logo is the wrong shape".
    static let iconCornerRatio: CGFloat = 0.2237

    var size: CGFloat = 22
    /// If non-nil, the mark renders in this single tint (chrome usage):
    /// shell full-strength, panels at 55% so the grid stays legible, no
    /// chevron or icon texture. If nil, the full icon palette renders.
    var mono: Color? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Shell plate — visible as the grid gaps between panels
            RoundedRectangle(cornerRadius: size * Self.iconCornerRatio, style: .continuous)
                .fill(mono.map { AnyShapeStyle($0) } ?? AnyShapeStyle(shellStyle))
                .frame(width: size, height: size)

            cell(x: 0.0781, y: 0.0781, w: 0.3516, h: 0.3711, outer: .topLeading, fill: panelLit)
            cell(x: 0.4922, y: 0.0781, w: 0.4297, h: 0.3711, outer: .topTrailing, fill: panelDark)
            cell(x: 0.0781, y: 0.5117, w: 0.6641, h: 0.4102, outer: .bottomLeading, fill: panelDark)
            cell(x: 0.8047, y: 0.5117, w: 0.1172, h: 0.4102, outer: .bottomTrailing, fill: panelDark)

            if mono == nil {
                // Prompt chevron (>) inside the top-left cell
                chevron

                // Text lines inside the bottom-left cell (icon texture)
                textLine(x: 0.1328, y: 0.5859, w: 0.4297)
                textLine(x: 0.1328, y: 0.6738, w: 0.2930)
                textLine(x: 0.1328, y: 0.7617, w: 0.5176)
            }
        }
        .frame(width: size, height: size)
    }

    // MARK: - Icon palette (from docs/bento-icon.svg)

    private var shellStyle: LinearGradient {
        LinearGradient(colors: [Color(hex: 0x6C768A), Color(hex: 0x444C5E)],
                       startPoint: .top, endPoint: .bottom)
    }

    /// Top-left panel — the "lit" prompt cell, one step lighter than the rest
    private var panelLit: AnyShapeStyle { panelStyle(0x272E3A, 0x151A22) }
    private var panelDark: AnyShapeStyle { panelStyle(0x181D24, 0x0C0F14) }

    private func panelStyle(_ top: UInt32, _ bottom: UInt32) -> AnyShapeStyle {
        if let mono {
            return AnyShapeStyle(mono.opacity(0.55))
        }
        return AnyShapeStyle(LinearGradient(colors: [Color(hex: top), Color(hex: bottom)],
                                            startPoint: .top, endPoint: .bottom))
    }

    // MARK: - Geometry

    private var bigR: CGFloat { size * 0.1406 }
    private var smallR: CGFloat { size * 0.0156 }

    private enum Corner { case topLeading, topTrailing, bottomLeading, bottomTrailing }

    private func cell(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
                      outer: Corner, fill: AnyShapeStyle) -> some View {
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
        return UnevenRoundedRectangle(cornerRadii: radii, style: .continuous)
            .fill(fill)
            .frame(width: size * w, height: size * h)
            .offset(x: size * x, y: size * y)
            .overlay {
                if mono == nil {
                    // Top sheen, matching the icon's highlight pass
                    LinearGradient(colors: [.white.opacity(0.11), .white.opacity(0)],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
    }

    private var chevron: some View {
        Path { p in
            p.move(to: CGPoint(x: size * 0.210, y: size * 0.181))
            p.addLine(to: CGPoint(x: size * 0.298, y: size * 0.264))
            p.addLine(to: CGPoint(x: size * 0.210, y: size * 0.347))
        }
        .stroke(Color.bentoMarkGreen,
                style: StrokeStyle(lineWidth: max(1.5, size * 0.041), lineCap: .round, lineJoin: .round))
    }

    private func textLine(x: CGFloat, y: CGFloat, w: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: size * 0.0127, style: .continuous)
            .fill(Color(red: 138/255, green: 147/255, blue: 166/255).opacity(0.22))
            .frame(width: size * w, height: size * 0.0254)
            .offset(x: size * x, y: size * y)
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(UIColor(hex: hex))
    }
}
