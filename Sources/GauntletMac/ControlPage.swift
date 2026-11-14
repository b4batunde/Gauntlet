import SwiftUI
import GauntletLink
import GauntletEngine
import GauntletDojo

/// `--showcase` renders the page as it looks in everyday use (no setup banners, Bluetooth label)
/// even when driven by the simulated watch. Used only for capturing demo footage.
private let showcase = CommandLine.arguments.contains("--showcase")

struct ControlPage: View {
    @ObservedObject var model: AppModel
    var openDojo: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UI.spacing) {
                PageHeader(title: "Control", subtitle: "Lift your arm toward the screen and point. Your watch is the mouse.") {
                    PauseButton(model: model, telemetry: model.telemetry)
                }
                HeroCard(model: model, telemetry: model.telemetry)

                if !model.accessibilityGranted, !showcase {
                    Banner(symbol: "hand.raised.fill", color: UI.amber,
                           title: "Allow Gauntlet to control the pointer",
                           text: "macOS needs the Accessibility permission before any app can move the cursor. Until then everything works in the Dojo sandbox only.",
                           action: "Open Settings") { model.requestAccessibility() }
                }
                if !model.bluetoothConfigured, !showcase {
                    Banner(symbol: "antenna.radiowaves.left.and.right.slash", color: UI.amber,
                           title: "Bluetooth is off for this run",
                           text: CommandLine.arguments.contains("--no-bluetooth")
                               ? "Started with --no-bluetooth. Relaunch normally to connect a real watch."
                               : "Launch the installed app in ~/Applications to connect a real watch.",
                           action: nil) {}
                }
                if model.isConnected, !model.settings.calibrated, !showcase {
                    Banner(symbol: "scope", color: UI.violet,
                           title: "Calibrate before first use",
                           text: "Two minutes in the Dojo teaches Gauntlet how you wear the watch and how hard you tap.",
                           action: "Open the Dojo", perform: openDojo)
                }

                HStack(alignment: .top, spacing: UI.spacing) {
                    ArmCard(model: model, telemetry: model.telemetry)
                    SignalCard(model: model, telemetry: model.telemetry).frame(width: 330)
                }
                HStack(alignment: .top, spacing: UI.spacing) {
                    GestureGuide(model: model)
                    ActivityCard(model: model).frame(width: 330)
                }
            }
            .padding(.horizontal, UI.pagePadding)
            .padding(.bottom, UI.pagePadding)
        }
        .scrollIndicators(.never)
    }
}

// MARK: - Header control

private struct PauseButton: View {
    @ObservedObject var model: AppModel
    @ObservedObject var telemetry: Telemetry

    var body: some View {
        let paused = telemetry.snapshot.paused
        HStack(spacing: 8) {
            Button { model.recenter() } label: { Label("Recenter", systemImage: "scope") }
                .buttonStyle(GlassButtonStyle())
            Button { model.togglePause() } label: {
                Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(ProminentButtonStyle(color: paused ? UI.green : UI.accent))
        }
    }
}

// MARK: - Hero

/// What the whole page hangs on: is the watch here, and is it driving the pointer right now?
private struct HeroCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var telemetry: Telemetry

    var body: some View {
        let s = telemetry.snapshot
        let look = appearance(s)
        Glass(padding: 24) {
            HStack(alignment: .center, spacing: 24) {
                StatusOrb(color: look.color, symbol: look.symbol, energy: look.energy)
                VStack(alignment: .leading, spacing: 10) {
                    Text(look.eyebrow.uppercased()).font(UI.eyebrow).tracking(1.4).foregroundStyle(look.color)
                    Text(look.title).font(UI.title(30)).lineLimit(1).minimumScaleFactor(0.6)
                    detail(s)
                }
                Spacer(minLength: 12)
                trailing(s)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: look.title)
    }

    private struct Look {
        var color: Color
        var symbol: String
        var energy: Double
        var eyebrow: String
        var title: String
    }

    private func appearance(_ s: WristSnapshot) -> Look {
        switch model.link {
        case .waiting:
            return Look(color: .gray, symbol: "applewatch", energy: 0.15, eyebrow: "Not connected", title: "Waiting for your watch")
        case .handshaking:
            return Look(color: UI.accent, symbol: "lock.shield", energy: 0.6, eyebrow: "Connecting", title: "Securing the link…")
        case .awaitingApproval(let name, _):
            return Look(color: UI.amber, symbol: "applewatch.radiowaves.left.and.right", energy: 0.7, eyebrow: "Pairing request", title: "Pair with \(name)?")
        case .connected(let name, _):
            if s.paused { return Look(color: UI.amber, symbol: "pause.fill", energy: 0.1, eyebrow: name, title: "Paused") }
            if model.sandboxActive { return Look(color: UI.violet, symbol: "cube.transparent", energy: 0.5, eyebrow: name, title: "In the Dojo") }
            if s.dragging { return Look(color: UI.violet, symbol: "hand.draw.fill", energy: 1, eyebrow: name, title: "Dragging") }
            if s.scrollMode { return Look(color: UI.amber, symbol: "arrow.up.and.down", energy: 0.9, eyebrow: name, title: "Air-scrolling") }
            if s.engaged { return Look(color: UI.accent, symbol: "cursorarrow.rays", energy: 1, eyebrow: name, title: "Pointing") }
            return Look(color: UI.green, symbol: "applewatch", energy: 0.3, eyebrow: name, title: "Ready")
        }
    }

    @ViewBuilder
    private func detail(_ s: WristSnapshot) -> some View {
        switch model.link {
        case .waiting(let status):
            VStack(alignment: .leading, spacing: 6) {
                Text(status).font(UI.body).foregroundStyle(.secondary)
                Text("Open Gauntlet on your Apple Watch and keep it within a few metres.")
                    .font(UI.caption).foregroundStyle(.tertiary)
            }
        case .handshaking:
            Text("Verifying the watch's identity.").font(UI.body).foregroundStyle(.secondary)
        case .awaitingApproval:
            Text("Approve only if your watch shows exactly this code.").font(UI.body).foregroundStyle(.secondary)
        case .connected(_, let via):
            HStack(spacing: 6) {
                Pill(text: showcase ? "Bluetooth" : via, color: UI.green, symbol: "dot.radiowaves.left.and.right")
                Pill(text: s.rightWrist ? "Right wrist" : "Left wrist", color: .secondary, symbol: "hand.raised")
                if !s.engaged, !s.paused, !model.sandboxActive {
                    Pill(text: "Lift to point", color: .secondary, symbol: "arrow.up.forward")
                }
            }
        }
    }

    @ViewBuilder
    private func trailing(_ s: WristSnapshot) -> some View {
        switch model.link {
        case .waiting, .handshaking:
            ProgressView().controlSize(.small)
        case .awaitingApproval(_, let code):
            VStack(alignment: .trailing, spacing: 12) {
                Text(code)
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .foregroundStyle(UI.amber)
                    .shadow(color: UI.amber.opacity(0.5), radius: 12)
                HStack(spacing: 8) {
                    Button("Decline") { model.rejectPairing() }.buttonStyle(GlassButtonStyle())
                    Button("Pair") { model.approvePairing() }.buttonStyle(ProminentButtonStyle(color: UI.amber))
                        .keyboardShortcut(.defaultAction)
                }
            }
        case .connected:
            VStack(alignment: .trailing, spacing: 10) {
                HStack(spacing: 8) {
                    if let battery = s.battery {
                        vital("\(battery)%", battery <= 15 ? "battery.25percent" : "battery.75percent", battery <= 15 ? UI.red : UI.green)
                    }
                    if let hr = s.heartRate { vital("\(hr)", "heart.fill", UI.pink) }
                    if s.rssi != 0 { vital("\(s.rssi)", "wifi", UI.accent) }
                }
                Button("Disconnect") { model.disconnectWatch() }.buttonStyle(GlassButtonStyle())
            }
        }
    }

    private func vital(_ value: String, _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            Text(value).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .background(Color.white.opacity(0.07), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 0.75))
    }
}

// MARK: - Banner

private struct Banner: View {
    var symbol: String
    var color: Color
    var title: String
    var text: String
    var action: String?
    var perform: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            IconBadge(symbol: symbol, color: color, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(UI.headline)
                Text(text).font(UI.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let action {
                Button(action, action: perform).buttonStyle(ProminentButtonStyle(color: color))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(color.opacity(0.28), lineWidth: 1))
    }
}

// MARK: - Live cards

private struct ArmCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var telemetry: Telemetry

    var body: some View {
        let s = telemetry.snapshot
        let raise = model.settings.clutch == .raiseToPoint
        Card("Your arm", symbol: "figure.arms.open") {
            HStack(alignment: .center, spacing: 18) {
                ClutchGauge(elevationDegrees: s.streaming ? s.elevation * 180 / .pi : 0,
                            thresholdDegrees: raise ? model.settings.raiseAngleDeg : nil,
                            engaged: s.engaged, valid: s.streaming && s.poseValid)
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                VStack(spacing: 8) {
                    Metric(label: "Elevation", value: s.streaming ? String(format: "%.0f°", s.elevation * 180 / .pi) : "–",
                           symbol: "arrow.up.right", tint: s.engaged ? UI.accent : .primary)
                    Metric(label: "Wrist twist", value: s.streaming ? String(format: "%.0f°", s.roll * 180 / .pi) : "–",
                           symbol: "arrow.triangle.2.circlepath")
                }
                .frame(width: 150)
            }
            Text(raise ? "The pointer follows while your forearm is above the dashed line. Lower it to the keyboard to let go."
                       : "The pointer follows whenever your arm is not hanging at your side.")
                .font(UI.caption).foregroundStyle(.secondary)
        }
    }
}

private struct SignalCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var telemetry: Telemetry

    var body: some View {
        let s = telemetry.snapshot
        Card("Signal", symbol: "waveform.path.ecg", tint: UI.green) {
            HStack(spacing: 8) {
                Metric(label: "Packets/s", value: s.streaming ? String(format: "%.0f", s.packetRate) : "–", symbol: "bolt.horizontal.fill")
                Metric(label: "Loss", value: s.streaming ? String(format: "%.0f%%", s.packetLoss * 100) : "–", symbol: "drop.fill",
                       tint: s.packetLoss > 0.1 ? UI.amber : .primary)
            }
            chart("Tap energy", note: "dashed = click threshold") {
                Sparkline(values: telemetry.tapHistory, ceiling: max(0.4, model.settings.gestures.tapThreshold * 2),
                          color: UI.accent, marker: model.settings.gestures.tapThreshold)
            }
            chart("Pointer speed", note: nil) {
                Sparkline(values: telemetry.speedHistory, ceiling: 2500, color: UI.violet, marker: nil)
            }
        }
    }

    private func chart<C: View>(_ title: String, note: String?, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if let note { Text(note).font(.system(size: 10)).foregroundStyle(.tertiary) }
            }
            content()
                .frame(height: 44)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }
}

// MARK: - Gesture guide

/// A cheat sheet that always reflects the current bindings.
private struct GestureGuide: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Card("How to drive", symbol: "hand.point.up.left.fill", tint: UI.violet) {
            let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
            LazyVGrid(columns: columns, spacing: 10) {
                tile("arrow.up.forward", UI.accent, "Lift & swing your arm", "Move the pointer")
                tile("hand.pinch.fill", UI.blue, "Tap thumb and finger", model.settings.action(for: .pinchTap).title)
                tile("arrow.clockwise", UI.violet, "Flick wrist outward", model.settings.action(for: .flickOut).title)
                tile("arrow.counterclockwise", UI.pink, "Flick wrist inward", model.settings.action(for: .flickIn).title)
                tile("digitalcrown.horizontal.arrow.clockwise.fill", UI.amber, "Turn the Digital Crown", "Scroll")
                tile("hand.point.up.left.fill", UI.green, "Drag on the watch face", "Fine pointer control")
            }
        }
    }

    private func tile(_ symbol: String, _ color: Color, _ gesture: String, _ result: String) -> some View {
        HStack(spacing: 11) {
            IconBadge(symbol: symbol, color: color, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(gesture).font(.system(size: 12.5, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                Text(result).font(UI.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.06)))
    }
}

private struct ActivityCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Card("Recent", symbol: "clock.arrow.circlepath", tint: UI.amber) {
            if model.log.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles").font(.system(size: 22)).foregroundStyle(.tertiary)
                    Text("Gestures you make appear here.").font(UI.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 26)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.log.prefix(6).enumerated()), id: \.element.id) { index, entry in
                        HStack(spacing: 10) {
                            Image(systemName: entry.symbol).font(.system(size: 12, weight: .medium))
                                .foregroundStyle(UI.accent).frame(width: 20)
                            Text(entry.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(showcase && entry.detail == "Developer link" ? "Bluetooth" : entry.detail).font(UI.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(.vertical, 7)
                        .opacity(1 - Double(index) * 0.11)
                        if index < min(model.log.count, 6) - 1 {
                            Rectangle().fill(.white.opacity(0.06)).frame(height: 1).padding(.leading, 30)
                        }
                    }
                }
            }
        }
    }
}
