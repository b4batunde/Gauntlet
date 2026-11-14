import SwiftUI

/// The translucent card every HUD element sits on. (Plain fills, no blur materials: they
/// cannot see through to the Metal view underneath and would flatten to grey.)
struct HUDPanel<Content: View>: View {
    var title: String?
    var symbol: String?
    var tint = DojoTheme.textSecondary
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let title {
                HStack(spacing: 6) {
                    if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .bold)) }
                    Text(title.uppercased()).font(.system(size: 10.5, weight: .heavy)).tracking(1.5)
                }
                .foregroundStyle(tint)
            }
            content
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(DojoTheme.panel.opacity(0.90)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(DojoTheme.panelStroke, lineWidth: 1))
    }
}

/// Small rounded status label.
struct Chip: View {
    var text: String
    var symbol: String?
    var tone: Color
    var filled = false

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .bold)) }
            Text(text).font(.system(size: 10.5, weight: .heavy)).tracking(0.9)
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .foregroundStyle(filled ? DojoTheme.background : tone)
        .background(Capsule().fill(filled ? tone : tone.opacity(0.16)))
        .overlay(Capsule().strokeBorder(tone.opacity(filled ? 0 : 0.45), lineWidth: 1))
    }
}

struct HUDButtonStyle: ButtonStyle {
    var tone = DojoTheme.accent
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold))
            .lineLimit(1)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .foregroundStyle(prominent ? DojoTheme.background : tone)
            .background(Capsule().fill(prominent ? tone : tone.opacity(configuration.isPressed ? 0.32 : 0.16)))
            .overlay(Capsule().strokeBorder(tone.opacity(prominent ? 0 : 0.5), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}

/// Square icon button for the top bar.
struct IconButtonStyle: ButtonStyle {
    var active = false
    var tone = DojoTheme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .frame(width: 32, height: 30)
            .foregroundStyle(active ? DojoTheme.background : DojoTheme.textPrimary)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(active ? tone : Color.white.opacity(configuration.isPressed ? 0.18 : 0.08)))
            .contentShape(Rectangle())
    }
}

struct ProgressLine: View {
    var value: Double
    var tone = DojoTheme.accent

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                Capsule().fill(tone).frame(width: max(6, proxy.size.width * CGFloat(min(1, max(0, value)))))
            }
        }
        .frame(height: 6)
    }
}

/// Lays children out left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews, width: bounds.width)
        for (index, origin) in rows.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], width: CGFloat, height: CGFloat) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (origins, widest, y + lineHeight)
    }
}

/// A keyboard / mouse key and what it does.
struct KeyHint: View {
    var key: String
    var label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .foregroundStyle(DojoTheme.textPrimary)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.13)))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(DojoTheme.textSecondary)
        }
        .lineLimit(1)
        .fixedSize()
    }
}
