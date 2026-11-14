import Foundation
import SwiftUI

/// Small all-caps caption used above values and as section labels.
struct CapsLabel: View {
    let text: String
    var color: Color = Palette.textDim

    var body: some View {
        Text(text)
            .tracking(1.2)
            .font(.system(.caption2, design: .rounded).weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

/// Expanding rings, used while looking for the Mac. Static when `animated` is false.
struct RadarView: View {
    var color: Color
    var animated: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !animated)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3, id: \.self) { ring in
                    let phase = RadarView.phase(time: time, offset: Double(ring) / 3.0)
                    Circle()
                        .stroke(color.opacity(animated ? (1.0 - phase) * 0.85 : 0.3), lineWidth: 2)
                        .scaleEffect(animated ? 0.2 + 0.8 * phase : 0.45 + 0.27 * Double(ring))
                }
                Circle()
                    .fill(color.opacity(animated ? 1.0 : 0.6))
                    .frame(width: 8, height: 8)
            }
        }
    }

    /// 0...1, repeating every 1.8 s.
    static func phase(time: TimeInterval, offset: Double) -> Double {
        let value = (time / 1.8 + offset).truncatingRemainder(dividingBy: 1.0)
        return value < 0 ? value + 1.0 : value
    }
}

/// The glowing ring on the Control page. Its colour is the Mac's state.
struct StatusRing: View {
    var mode: ControlMode
    var touching: Bool
    /// Always-on display: dim, thin, and perfectly still.
    var dim: Bool
    /// June is listening or thinking: her colour, always spinning.
    var override: Color? = nil

    var body: some View {
        let color = override ?? mode.color
        let moving = (override != nil || mode.animates) && !dim
        let width: CGFloat = dim ? 3 : 6
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !moving)) { context in
            let period: Double = override != nil ? 1.6 : 4.0
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            ZStack {
                Circle()
                    .stroke(color.opacity(dim ? 0.35 : 0.2), lineWidth: width)
                if !dim {
                    Circle()
                        .trim(from: 0, to: moving ? 0.72 : 1.0)
                        .stroke(
                            AngularGradient(gradient: Gradient(colors: [color.opacity(0.05), color]),
                                            center: .center,
                                            startAngle: .degrees(0),
                                            endAngle: .degrees(moving ? 259 : 360)),
                            style: StrokeStyle(lineWidth: width, lineCap: .round))
                        .rotationEffect(.degrees(moving ? turn * 360.0 : -90.0))
                        .shadow(color: color.opacity(0.75), radius: touching ? 11 : 6)
                }
            }
            .padding(width / 2 + 8)
        }
    }
}

/// Round chip that reports press and release (push-to-talk). Filled while held or `active`.
struct HoldChip: View {
    let symbol: String
    let color: Color
    var active = false
    let onChange: (Bool) -> Void
    @GestureState private var pressed = false

    var body: some View {
        let filled = pressed || active
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(filled ? Palette.background : color)
            .frame(width: 38, height: 38)
            .background(Circle().fill(filled ? color : Palette.panel))
            .overlay(Circle().strokeBorder(color.opacity(0.4), lineWidth: 1))
            .scaleEffect(pressed ? 1.12 : 1.0)
            .animation(.easeOut(duration: 0.12), value: pressed)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).updating($pressed) { _, state, _ in state = true })
            .onChange(of: pressed) { _, down in onChange(down) }
    }
}

/// Round icon button in the corners of the Control page.
struct ChipButtonStyle: ButtonStyle {
    var color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 38, height: 38)
            .background(Circle().fill(Palette.panel))
            .overlay(Circle().strokeBorder(color.opacity(0.4), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.55 : 1.0)
            .contentShape(Circle())
    }
}

/// Capsule button between the chips.
struct PillButtonStyle: ButtonStyle {
    var color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.caption2, design: .rounded).weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(Capsule().fill(Palette.panel))
            .overlay(Capsule().strokeBorder(color.opacity(0.4), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.55 : 1.0)
            .contentShape(Capsule())
    }
}

/// Large full-width button on the Actions page; filled while its state is on.
struct ActionButtonStyle: ButtonStyle {
    var color: Color
    var isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        configuration.label
            .foregroundStyle(isOn ? Palette.background : Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(shape.fill(isOn ? color : Palette.panel))
            .overlay(shape.strokeBorder(color.opacity(isOn ? 0.0 : 0.45), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.6 : 1.0)
            .contentShape(shape)
    }
}

struct ActionButton: View {
    let title: String
    var detail: String?
    let symbol: String
    let color: Color
    var isOn = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isOn ? Palette.background : color)
                    .frame(width: 26)
                Text(title)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 2)
                if let detail {
                    Text(detail)
                        .font(.system(.caption2, design: .rounded).weight(.bold))
                        .foregroundStyle(isOn ? Palette.background : Palette.textDim)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(ActionButtonStyle(color: color, isOn: isOn))
    }
}

/// A labelled value on the Status page. The value wraps instead of truncating.
struct StatRow: View {
    let title: String
    let value: String
    var color: Color = Color.white

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            CapsLabel(text: title)
            Text(value)
                .font(.system(.footnote, design: .rounded).weight(.medium))
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.panel))
    }
}
