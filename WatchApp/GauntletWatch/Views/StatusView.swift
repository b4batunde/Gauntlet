import Foundation
import SwiftUI
import GauntletLink
import GauntletWatchCore

/// Everything about the link and the watch, plus the session controls.
struct StatusView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: WatchSessionController
    @LocalState private var confirmingForget = false

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                StatRow(title: "MAC", value: macName, color: Palette.cyan)
                StatRow(title: "SIGNAL", value: signalText)
                StatRow(title: "STREAM", value: streamText)
                StatRow(title: "BATTERY", value: batteryText)
                StatRow(title: "HEART RATE", value: heartRateText)
                StatRow(title: "WORN ON", value: model.wearing.summary)
                StatRow(title: "KEEP-ALIVE", value: keepAliveText, color: keepAliveColor)
                if let problem = model.motionProblem {
                    StatRow(title: "MOTION", value: problem, color: Palette.amber)
                }

                Toggle(isOn: $model.hapticsEnabled) {
                    Text("Haptics")
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .tint(Palette.cyan)
                .padding(.top, 4)

                ActionButton(title: "End session", symbol: "stop.fill", color: Palette.red) {
                    model.endSession()
                }
                ActionButton(title: confirmingForget ? "Tap to confirm" : "Forget this Mac",
                             symbol: "trash.fill",
                             color: Palette.red,
                             isOn: confirmingForget) {
                    if confirmingForget {
                        confirmingForget = false
                        model.forgetMac()
                    } else {
                        confirmingForget = true
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 4)
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Status")
    }

    private var macName: String {
        if case .connected(let name) = session.state { return name }
        return "Not connected"
    }

    private var signalText: String {
        if model.isSimulated { return "Developer link" }
        let dBm = session.signal
        guard dBm != 0 else { return "Measuring…" }
        let quality = dBm >= -60 ? "Strong" : (dBm >= -75 ? "Good" : "Weak")
        return "\(quality), \(dBm) dBm"
    }

    private var streamText: String {
        "\(session.packetsPerSecond) packets/s at \(session.streamConfig.sampleRateHz) Hz"
    }

    private var batteryText: String {
        guard let percent = model.battery.percent else { return "Unknown" }
        return model.battery.charging ? "\(percent)%, charging" : "\(percent)%"
    }

    private var heartRateText: String {
        if let bpm = model.heartRate { return "\(bpm) BPM" }
        return "Not measured"
    }

    private var keepAliveText: String {
        switch model.keepAlive {
        case .off:
            return model.isSimulated ? "Not needed in the simulator" : "Off"
        case .starting:
            return "Starting…"
        case .active(let name):
            return name
        case .unavailable(let reason):
            if model.isSimulated { return "Not needed in the simulator" }
            if let reason, !reason.isEmpty { return "Unavailable: \(reason)" }
            return "Unavailable"
        }
    }

    private var keepAliveColor: Color {
        switch model.keepAlive {
        case .active: return Palette.green
        case .starting: return Color.white
        case .off, .unavailable: return model.isSimulated ? Color.white : Palette.amber
        }
    }
}
