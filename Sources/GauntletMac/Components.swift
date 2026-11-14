import AppKit
import SwiftUI
import GauntletDojo

// MARK: - Design tokens

enum UI {
    static let accent = DojoTheme.accent
    static let violet = DojoTheme.secondary
    static let green = DojoTheme.success
    static let amber = DojoTheme.warning
    static let red = DojoTheme.danger
    static let pink = Color(red: 1.0, green: 0.36, blue: 0.62)
    static let blue = Color(red: 0.25, green: 0.56, blue: 1.0)

    static let cardRadius: CGFloat = 18
    static let pagePadding: CGFloat = 28
    static let spacing: CGFloat = 16

    static func title(_ size: CGFloat = 28) -> Font { .system(size: size, weight: .bold, design: .rounded) }
    static let headline = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 13)
    static let caption = Font.system(size: 11.5)
    static let eyebrow = Font.system(size: 10.5, weight: .semibold, design: .rounded)
}

// MARK: - Window chrome

/// Native macOS vibrancy (the blurred desktop showing through), which SwiftUI materials alone
/// cannot give a whole window.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        view.material = material
        view.blendingMode = blending
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

/// The backdrop behind every page: vibrancy, a dark tint, and two soft colour washes
/// that give the glass cards something to refract.
struct Backdrop: View {
    var tint: Color = UI.accent

    var body: some View {
        ZStack {
            VisualEffect(material: .underWindowBackground)
            DojoTheme.background.opacity(0.82)
            // Radial gradients rather than blurred shapes: always soft-edged, and cheap to draw.
            GeometryReader { proxy in
                let reach = max(proxy.size.width, proxy.size.height)
                ZStack {
                    RadialGradient(colors: [tint.opacity(0.26), tint.opacity(0.08), .clear],
                                   center: UnitPoint(x: 0.88, y: 0.02), startRadius: 0, endRadius: reach * 0.62)
                    RadialGradient(colors: [UI.violet.opacity(0.22), UI.violet.opacity(0.06), .clear],
                                   center: UnitPoint(x: 0.08, y: 1.0), startRadius: 0, endRadius: reach * 0.58)
                    LinearGradient(colors: [.white.opacity(0.035), .clear], startPoint: .top, endPoint: .center)
                }
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Surfaces

/// Frosted glass panel with a hairline highlight along the top edge.
struct Glass<Content: View>: View {
    var padding: CGFloat = 20
    var radius: CGFloat = UI.cardRadius
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.white.opacity(0.025)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.04)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
    }
}

/// A titled glass card.
struct Card<Content: View>: View {
    var title: String?
    var symbol: String?
    var tint: Color
    var trailing: AnyView?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, symbol: String? = nil, tint: Color = UI.accent,
         trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        Glass {
            VStack(alignment: .leading, spacing: 14) {
                if let title {
                    HStack(spacing: 7) {
                        if let symbol {
                            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                        }
                        Text(title.uppercased()).font(UI.eyebrow).tracking(1.1).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if let trailing { trailing }
                    }
                }
                content
            }
        }
    }
}

/// The rounded colour tile macOS uses beside rows in System Settings.
struct IconBadge: View {
    var symbol: String
    var color: Color
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(LinearGradient(colors: [color.opacity(0.95), color.opacity(0.68)], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white))
            .overlay(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
            .shadow(color: color.opacity(0.35), radius: 5, y: 2)
    }
}

struct Pill: View {
    var text: String
    var color: Color
    var symbol: String?

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9.5, weight: .bold)) }
            Text(text).font(.system(size: 11, weight: .semibold, design: .rounded))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4.5)
        .foregroundStyle(color)
        .background(color.opacity(0.15), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.30), lineWidth: 0.75))
    }
}

/// Small labelled figure: icon, big number, caption.
struct Metric: View {
    var label: String
    var value: String
    var symbol: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint == .primary ? Color.secondary : tint)
                Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.06)))
    }
}

// MARK: - Settings-style lists

/// A grouped list in the style of System Settings: glass container, hairline separators.
struct RowGroup<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 6)
            }
            Glass(padding: 0, radius: 14) {
                VStack(spacing: 0) { content }
            }
            if let footer {
                Text(footer).font(UI.caption).foregroundStyle(.tertiary).padding(.horizontal, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One row: icon badge, title and optional detail on the left, a control on the right.
struct Row<Accessory: View>: View {
    var symbol: String
    var color: Color
    var title: String
    var detail: String?
    var showsDivider = true
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                IconBadge(symbol: symbol, color: color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(UI.body.weight(.medium))
                    if let detail {
                        Text(detail).font(UI.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                accessory
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            if showsDivider {
                Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.leading, 54)
            }
        }
    }
}

/// A row whose control is a slider with a live value read-out.
struct SliderRow: View {
    var symbol: String
    var color: Color
    var title: String
    var detail: String?
    @Binding var value: Double
    var range: ClosedRange<Double>
    var showsDivider = true
    var format: (Double) -> String

    var body: some View {
        Row(symbol: symbol, color: color, title: title, detail: detail, showsDivider: showsDivider) {
            HStack(spacing: 10) {
                Slider(value: $value, in: range).controlSize(.small).frame(width: 190).tint(UI.accent)
                Text(format(value))
                    .font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .trailing)
            }
        }
    }
}

struct ToggleRow: View {
    var symbol: String
    var color: Color
    var title: String
    var detail: String?
    @Binding var isOn: Bool
    var showsDivider = true

    var body: some View {
        Row(symbol: symbol, color: color, title: title, detail: detail, showsDivider: showsDivider) {
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(UI.accent)
        }
    }
}

// MARK: - Buttons

/// Filled capsule with a soft glow: the one primary action in a view.
struct ProminentButtonStyle: ButtonStyle {
    var color: Color = UI.accent
    var wide = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .frame(maxWidth: wide ? .infinity : nil)
            .foregroundStyle(Color.black.opacity(0.82))
            .background(
                LinearGradient(colors: [color, color.opacity(0.78)], startPoint: .top, endPoint: .bottom),
                in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.75))
            .shadow(color: color.opacity(configuration.isPressed ? 0.15 : 0.45), radius: configuration.isPressed ? 4 : 12, y: 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Quiet glass capsule for secondary actions.
struct GlassButtonStyle: ButtonStyle {
    var color: Color = .primary
    var wide = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .padding(.horizontal, 15)
            .padding(.vertical, 8)
            .frame(maxWidth: wide ? .infinity : nil)
            .foregroundStyle(color)
            .background(Color.white.opacity(configuration.isPressed ? 0.16 : 0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.75))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Live graphics

/// The animated emblem on the Control page: a watch glyph inside breathing rings whose
/// colour and energy follow the connection state.
struct StatusOrb: View {
    var color: Color
    var symbol: String
    /// 0 = idle, 1 = fully alive (rings sweep faster and brighter).
    var energy: Double
    var size: CGFloat = 132

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, canvasSize in
                let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                let base = min(canvasSize.width, canvasSize.height) / 2

                // Expanding ripples.
                for i in 0..<3 {
                    let phase = (t * (0.28 + 0.25 * energy) + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    let radius = base * (0.52 + 0.46 * phase)
                    let alpha = (1 - phase) * (0.10 + 0.22 * energy)
                    context.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                                   with: .color(color.opacity(alpha)), lineWidth: 1.5)
                }

                // Rotating arc.
                let ringRadius = base * 0.62
                var track = Path()
                track.addArc(center: center, radius: ringRadius, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
                context.stroke(track, with: .color(color.opacity(0.16)), lineWidth: 5)
                let start = Angle.degrees((t * (30 + 110 * energy)).truncatingRemainder(dividingBy: 360))
                var arc = Path()
                arc.addArc(center: center, radius: ringRadius, startAngle: start, endAngle: start + .degrees(70 + 150 * energy), clockwise: false)
                context.stroke(arc, with: .color(color), style: StrokeStyle(lineWidth: 5, lineCap: .round))

                // Core.
                let coreRadius = base * 0.47
                let core = Path(ellipseIn: CGRect(x: center.x - coreRadius, y: center.y - coreRadius, width: coreRadius * 2, height: coreRadius * 2))
                context.fill(core, with: .radialGradient(Gradient(colors: [color.opacity(0.42), color.opacity(0.10)]),
                                                         center: center, startRadius: 0, endRadius: coreRadius))
                context.stroke(core, with: .color(.white.opacity(0.14)), lineWidth: 1)
            }
        }
        .frame(width: size, height: size)
        .overlay(
            Image(systemName: symbol)
                .font(.system(size: size * 0.26, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: color.opacity(0.9), radius: 10))
        .shadow(color: color.opacity(0.35 + 0.25 * energy), radius: 26)
    }
}

/// Minimal line chart for a rolling buffer.
struct Sparkline: View {
    var values: [Double]
    var ceiling: Double
    var color: Color
    /// Optional horizontal marker (e.g. a detection threshold).
    var marker: Double?

    var body: some View {
        Canvas { context, size in
            guard values.count > 1, ceiling > 0 else { return }
            let step = size.width / CGFloat(values.count - 1)
            func y(_ v: Double) -> CGFloat { size.height - CGFloat(min(1, max(0, v / ceiling))) * (size.height - 3) - 1.5 }
            var line = Path()
            for (i, v) in values.enumerated() {
                let p = CGPoint(x: CGFloat(i) * step, y: y(v))
                if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
            }
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .linearGradient(Gradient(colors: [color.opacity(0.32), color.opacity(0)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
            if let marker {
                var m = Path()
                m.move(to: CGPoint(x: 0, y: y(marker)))
                m.addLine(to: CGPoint(x: size.width, y: y(marker)))
                context.stroke(m, with: .color(UI.amber.opacity(0.85)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
    }
}

/// Side view of the forearm: how high it is lifted versus the angle that engages the pointer.
struct ClutchGauge: View {
    var elevationDegrees: Double
    var thresholdDegrees: Double?
    var engaged: Bool
    var valid: Bool

    var body: some View {
        Canvas { context, size in
            let pivot = CGPoint(x: size.width * 0.14, y: size.height * 0.80)
            let length = min(size.width * 0.74, size.height * 1.25)
            func tip(_ degrees: Double, _ scale: CGFloat = 1) -> CGPoint {
                let r = degrees * .pi / 180
                return CGPoint(x: pivot.x + cos(r) * length * scale, y: pivot.y - sin(r) * length * scale)
            }
            let color = !valid ? Color.white.opacity(0.25) : (engaged ? UI.accent : Color.white.opacity(0.55))

            // Angle guides.
            for degrees in stride(from: -30.0, through: 60.0, by: 30.0) {
                var guide = Path()
                guide.move(to: tip(degrees, 0.86))
                guide.addLine(to: tip(degrees, 0.92))
                context.stroke(guide, with: .color(.white.opacity(0.18)), lineWidth: 1)
            }
            var horizon = Path()
            horizon.move(to: CGPoint(x: 0, y: pivot.y))
            horizon.addLine(to: CGPoint(x: size.width, y: pivot.y))
            context.stroke(horizon, with: .color(.white.opacity(0.10)), lineWidth: 1)

            // Engage zone and threshold.
            if let thresholdDegrees {
                var zone = Path()
                zone.move(to: pivot)
                zone.addArc(center: pivot, radius: length * 0.84, startAngle: .degrees(-thresholdDegrees),
                            endAngle: .degrees(-62), clockwise: true)
                zone.closeSubpath()
                context.fill(zone, with: .color(UI.accent.opacity(engaged ? 0.09 : 0.03)))
                var t = Path()
                t.move(to: pivot)
                t.addLine(to: tip(thresholdDegrees, 0.9))
                context.stroke(t, with: .color(UI.amber.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }

            // Forearm.
            var arm = Path()
            arm.move(to: pivot)
            arm.addLine(to: tip(elevationDegrees, 0.82))
            if engaged {
                context.stroke(arm, with: .color(UI.accent.opacity(0.35)), style: StrokeStyle(lineWidth: 16, lineCap: .round))
            }
            context.stroke(arm, with: .color(color), style: StrokeStyle(lineWidth: 8, lineCap: .round))
            let watch = tip(elevationDegrees, 0.6)
            context.fill(Path(roundedRect: CGRect(x: watch.x - 7, y: watch.y - 7, width: 14, height: 14), cornerRadius: 4),
                         with: .color(engaged ? .white : UI.violet))
            context.fill(Path(ellipseIn: CGRect(x: pivot.x - 5, y: pivot.y - 5, width: 10, height: 10)),
                         with: .color(.white.opacity(0.55)))
        }
    }
}

/// Page header: large rounded title with a one-line description and optional trailing controls.
struct PageHeader<Trailing: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(UI.title())
                Text(subtitle).font(UI.body).foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
        .padding(.top, 26)
    }
}
