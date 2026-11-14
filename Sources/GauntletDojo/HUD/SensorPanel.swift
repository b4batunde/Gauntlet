import SwiftUI
import GauntletEngine

/// Live view of what the engine sees: tap energy against its threshold, the raise-to-point
/// clutch, and wrist roll against the flick threshold. Redrawn from `SensorTrace` 30 times a second.
struct SensorPanel: View {
    let trace: SensorTrace
    var link: LinkStatus

    var body: some View {
        HUDPanel(title: "Live sensors", symbol: "waveform.path.ecg") {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                let snapshot = trace.snapshot
                let settings = trace.settings
                VStack(alignment: .leading, spacing: 10) {
                    tapMeter(settings)
                    Divider().overlay(Color.white.opacity(0.08))
                    clutchMeter(snapshot, settings)
                    Divider().overlay(Color.white.opacity(0.08))
                    rollMeter(snapshot, settings)
                }
            }
            Divider().overlay(Color.white.opacity(0.08))
            HStack(spacing: 10) {
                Label(link.streaming ? "\(link.packetRate) pkt/s" : "no data", systemImage: "antenna.radiowaves.left.and.right")
                if let battery = link.battery { Label("\(battery)%", systemImage: "battery.75percent") }
                if let heartRate = link.heartRate { Label("\(heartRate)", systemImage: "heart.fill") }
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(DojoTheme.textSecondary)
            .lineLimit(1)
        }
    }

    private func rowTitle(_ title: String, _ value: String, tone: Color = DojoTheme.textSecondary) -> some View {
        HStack {
            Text(title).font(.system(size: 11, weight: .bold)).foregroundStyle(DojoTheme.textPrimary)
            Spacer(minLength: 4)
            Text(value).font(.system(size: 10.5, weight: .semibold).monospacedDigit()).foregroundStyle(tone)
        }
        .lineLimit(1)
    }

    // MARK: Tap energy

    private func tapMeter(_ settings: EngineSettings) -> some View {
        let threshold = settings.gestures.tapThreshold
        let enabled = settings.gestures.tapEnabled
        return VStack(alignment: .leading, spacing: 5) {
            rowTitle("Tap energy", enabled ? String(format: "threshold %.2f g", threshold) : "taps off",
                     tone: enabled ? DojoTheme.warning : DojoTheme.danger)
            Canvas { context, size in
                let values = trace.envelope
                let top = max(0.4, threshold * 2.4)
                func y(_ value: Double) -> CGFloat { size.height - CGFloat(min(value, top) / top) * (size.height - 3) }
                guard values.count > 1 else { return }

                var area = Path()
                area.move(to: CGPoint(x: 0, y: size.height))
                for (index, value) in values.enumerated() {
                    area.addLine(to: CGPoint(x: CGFloat(index) / CGFloat(values.count - 1) * size.width, y: y(value)))
                }
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .linearGradient(
                    Gradient(colors: [DojoTheme.accent.opacity(0.95), DojoTheme.accent.opacity(0.15)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

                var line = Path()
                line.move(to: CGPoint(x: 0, y: y(threshold)))
                line.addLine(to: CGPoint(x: size.width, y: y(threshold)))
                context.stroke(line, with: .color(enabled ? DojoTheme.warning : DojoTheme.textSecondary),
                               style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))

                // Every tap-shaped transient: green if it clicked, grey if it was rejected.
                for peak in trace.peaks {
                    let x = size.width * (1 - CGFloat(peak.age) / CGFloat(SensorTrace.capacity))
                    let dot = CGRect(x: x - 3.5, y: y(peak.value) - 3.5, width: 7, height: 7)
                    context.fill(Path(ellipseIn: dot), with: .color(peak.accepted ? DojoTheme.success : Color.white.opacity(0.55)))
                }
            }
            .frame(height: 54)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.28)))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: Clutch

    private func clutchMeter(_ snapshot: WristSnapshot, _ settings: EngineSettings) -> some View {
        let raiseToPoint = settings.clutch == .raiseToPoint
        let thresholdDeg = raiseToPoint ? settings.raiseAngleDeg : settings.restAngleDeg + 8
        let elevationDeg = degrees(snapshot.elevation)
        let engaged = snapshot.engaged
        let tone = engaged ? DojoTheme.accent : DojoTheme.textSecondary
        return VStack(alignment: .leading, spacing: 5) {
            rowTitle(raiseToPoint ? "Raise to point" : "Clutch", String(format: "engages above %.0f°", thresholdDeg))
            HStack(spacing: 10) {
                Canvas { context, size in
                    // A protractor: 0° is level (pointing right), angles open upward.
                    let center = CGPoint(x: 10, y: size.height - 16)
                    let radius = min(size.width - 18, size.height - 20)
                    func point(_ deg: Double, _ r: CGFloat) -> CGPoint {
                        CGPoint(x: center.x + r * CGFloat(cos(radians(deg))), y: center.y - r * CGFloat(sin(radians(deg))))
                    }
                    func arc(from: Double, to: Double) -> Path {
                        var path = Path()
                        path.addArc(center: center, radius: radius, startAngle: .degrees(-from), endAngle: .degrees(-to), clockwise: true)
                        return path
                    }
                    context.stroke(arc(from: -20, to: 90), with: .color(Color.white.opacity(0.14)), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    context.stroke(arc(from: max(-20, min(90, thresholdDeg)), to: 90), with: .color(DojoTheme.accent.opacity(engaged ? 0.9 : 0.35)),
                                   style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    var tick = Path()
                    tick.move(to: point(thresholdDeg, radius - 9))
                    tick.addLine(to: point(thresholdDeg, radius + 7))
                    context.stroke(tick, with: .color(DojoTheme.warning), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

                    let shown = max(-20, min(90, elevationDeg))
                    var arm = Path()
                    arm.move(to: center)
                    arm.addLine(to: point(shown, radius - 3))
                    context.stroke(arm, with: .color(tone), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    context.fill(Path(ellipseIn: CGRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9)), with: .color(tone))
                }
                .frame(width: 84, height: 70)
                VStack(alignment: .leading, spacing: 3) {
                    Text(snapshot.streaming ? String(format: "%.0f°", elevationDeg) : "—")
                        .font(.system(size: 24, weight: .heavy, design: .rounded).monospacedDigit())
                        .foregroundStyle(tone)
                    Text(!snapshot.streaming ? "no signal" : (snapshot.paused ? "paused" : (engaged ? "pointer engaged" : "pointer released")))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(DojoTheme.textSecondary)
                    if !snapshot.poseValid, snapshot.streaming {
                        Text("arm vertical").font(.system(size: 10, weight: .semibold)).foregroundStyle(DojoTheme.warning)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Roll and flick

    private func rollMeter(_ snapshot: WristSnapshot, _ settings: EngineSettings) -> some View {
        let rollDeg = degrees(snapshot.roll)
        let rate = abs(snapshot.rates.z)
        let flickRate = settings.gestures.flickRate
        return VStack(alignment: .leading, spacing: 5) {
            rowTitle("Wrist twist", String(format: "flick above %.1f rad/s", flickRate))
            HStack(spacing: 10) {
                Canvas { context, size in
                    // The watch seen from the hand: it tips as the wrist rolls.
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    context.stroke(Path(ellipseIn: CGRect(x: center.x - 19, y: center.y - 19, width: 38, height: 38)),
                                   with: .color(Color.white.opacity(0.14)), lineWidth: 2)
                    context.translateBy(x: center.x, y: center.y)
                    context.rotate(by: .degrees(rollDeg))
                    let body = Path(roundedRect: CGRect(x: -11, y: -5, width: 22, height: 10), cornerRadius: 3.5)
                    context.fill(body, with: .color(DojoTheme.secondary))
                    context.fill(Path(roundedRect: CGRect(x: -3, y: -8, width: 6, height: 3), cornerRadius: 1), with: .color(DojoTheme.accent))
                }
                .frame(width: 44, height: 42)
                VStack(alignment: .leading, spacing: 5) {
                    Text(String(format: "%+.0f°", rollDeg))
                        .font(.system(size: 15, weight: .heavy, design: .rounded).monospacedDigit())
                        .foregroundStyle(DojoTheme.textPrimary)
                    Canvas { context, size in
                        let top = max(8, flickRate * 1.6)
                        let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)
                        context.fill(track, with: .color(Color.white.opacity(0.10)))
                        let width = size.width * CGFloat(min(1, rate / top))
                        if width > 1 {
                            context.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: max(size.height, width), height: size.height), cornerRadius: size.height / 2),
                                         with: .color(rate >= flickRate ? DojoTheme.secondary : DojoTheme.secondary.opacity(0.5)))
                        }
                        let x = size.width * CGFloat(flickRate / top)
                        context.fill(Path(CGRect(x: x - 1, y: -2, width: 2, height: size.height + 4)), with: .color(DojoTheme.warning))
                    }
                    .frame(height: 6)
                }
            }
        }
    }
}

/// Always-visible strip of pointer state chips, with the switch that opens the sensor panel.
struct StateStrip: View {
    var flags: PointerFlags
    var link: LinkStatus
    var sensorsOpen: Bool
    var toggleSensors: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggleSensors) {
                Image(systemName: sensorsOpen ? "chevron.up" : "waveform.path.ecg")
            }
            .buttonStyle(IconButtonStyle(active: false))
            .help(sensorsOpen ? "Hide live sensors" : "Show live sensors")

            if !link.streaming {
                Chip(text: "NO SIGNAL", symbol: "wifi.slash", tone: DojoTheme.textSecondary)
            } else if flags.paused {
                Chip(text: "PAUSED", symbol: "pause.fill", tone: DojoTheme.warning, filled: true)
            } else if flags.engaged {
                Chip(text: "ENGAGED", symbol: "scope", tone: DojoTheme.accent, filled: true)
            } else {
                Chip(text: "RELEASED", symbol: "arrow.down.to.line", tone: DojoTheme.textSecondary)
            }
            if flags.dragging { Chip(text: "DRAG", symbol: "hand.draw.fill", tone: DojoTheme.secondary, filled: true) }
            if flags.scrollMode { Chip(text: "AIR-SCROLL", symbol: "arrow.up.arrow.down", tone: DojoTheme.success, filled: true) }
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(DojoTheme.panel.opacity(0.90)))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(DojoTheme.panelStroke, lineWidth: 1))
    }
}
