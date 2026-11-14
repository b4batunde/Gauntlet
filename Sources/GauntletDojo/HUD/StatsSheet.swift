import SwiftUI
import GauntletEngine

/// Personal bests, recent history and the current calibration, in one compact card.
struct StatsSheet: View {
    @ObservedObject var controller: DojoController

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .contentShape(Rectangle())
                .onTapGesture { controller.showStats = false }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Personal bests", systemImage: "trophy.fill")
                        .font(.system(size: 17, weight: .heavy, design: .rounded))
                        .foregroundStyle(DojoTheme.textPrimary)
                    Spacer()
                    Button { controller.showStats = false } label: { Image(systemName: "xmark") }
                        .buttonStyle(IconButtonStyle())
                }
                ForEach(DojoMode.drills) { mode in
                    row(for: mode)
                }
                Divider().overlay(Color.white.opacity(0.1))
                calibration
                HStack {
                    Text("Bests are kept on this Mac.").font(.system(size: 11, weight: .medium)).foregroundStyle(DojoTheme.textSecondary)
                    Spacer()
                    Button { controller.resetRecords() } label: { Label("Reset records", systemImage: "trash") }
                        .buttonStyle(HUDButtonStyle(tone: DojoTheme.danger))
                }
            }
            .padding(18)
            .frame(width: 520)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(DojoTheme.panel))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(DojoTheme.accent.opacity(0.35), lineWidth: 1))
        }
        .id(controller.recordsRevision)
    }

    private func row(for mode: DojoMode) -> some View {
        let records = controller.session.records
        let history = records.history(for: mode)
        let best = records.best(for: mode)
        return HStack(spacing: 12) {
            Image(systemName: mode.symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(DojoTheme.accent)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DojoTheme.accent.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(mode.title).font(.system(size: 13, weight: .heavy)).foregroundStyle(DojoTheme.textPrimary)
                Text(history.last.map { "Last: \($0.summary)" } ?? "Not played yet")
                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(DojoTheme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Sparkline(values: history.suffix(14).map(\.score), higherIsBetter: mode.higherIsBetter)
                .frame(width: 84, height: 26)
            VStack(alignment: .trailing, spacing: 2) {
                Text(best.map { mode.formatScore($0.score) } ?? "—")
                    .font(.system(size: 14, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(best == nil ? DojoTheme.textSecondary : DojoTheme.warning)
                Text("\(history.count) run\(history.count == 1 ? "" : "s")")
                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(DojoTheme.textSecondary)
            }
            .frame(width: 104, alignment: .trailing)
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.22)))
    }

    private var calibration: some View {
        let settings = controller.host.engine.currentSettings
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("CALIBRATION").font(.system(size: 10.5, weight: .heavy)).tracking(1.5).foregroundStyle(DojoTheme.textSecondary)
                Chip(text: settings.calibrated ? "DONE" : "NOT YET", symbol: settings.calibrated ? "checkmark" : "exclamationmark",
                     tone: settings.calibrated ? DojoTheme.success : DojoTheme.warning)
            }
            FlowLayout(spacing: 16, lineSpacing: 6) {
                fact("Pointer speed", String(format: "%.2f×", settings.sensitivity))
                fact("Finger tap", settings.gestures.tapEnabled ? String(format: "%.2f g", settings.gestures.tapThreshold) : "off")
                fact("Wrist flick", String(format: "%.1f rad/s", settings.gestures.flickRate))
                fact("Engages above", String(format: "%.0f°", settings.raiseAngleDeg))
                fact("Forearm axis", settings.forearmAxisFlipped ? "flipped" : "default")
            }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(DojoTheme.textSecondary)
            Text(value).font(.system(size: 11.5, weight: .heavy).monospacedDigit()).foregroundStyle(DojoTheme.textPrimary)
        }
        .fixedSize()
    }
}

/// Tiny trend line of recent scores; the latest point is dotted, the best is highlighted.
struct Sparkline: View {
    var values: [Double]
    var higherIsBetter: Bool

    var body: some View {
        Canvas { context, size in
            guard values.count > 1, let low = values.min(), let high = values.max() else {
                let dash = Path(CGRect(x: 0, y: size.height / 2, width: size.width, height: 1))
                context.fill(dash, with: .color(Color.white.opacity(0.12)))
                return
            }
            let span = max(high - low, 1e-9)
            func point(_ index: Int) -> CGPoint {
                // Better is always drawn higher.
                var t = (values[index] - low) / span
                if !higherIsBetter { t = 1 - t }
                return CGPoint(x: CGFloat(index) / CGFloat(values.count - 1) * (size.width - 6) + 3,
                               y: size.height - 3 - CGFloat(t) * (size.height - 6))
            }
            var line = Path()
            line.move(to: point(0))
            for index in 1..<values.count { line.addLine(to: point(index)) }
            context.stroke(line, with: .color(DojoTheme.accent), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            let last = point(values.count - 1)
            context.fill(Path(ellipseIn: CGRect(x: last.x - 3, y: last.y - 3, width: 6, height: 6)), with: .color(DojoTheme.accent))
        }
    }
}
