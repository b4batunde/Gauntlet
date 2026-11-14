import SwiftUI
import GauntletEngine

/// Everything drawn over the 3D scene. Adapts from about 800 x 640 points upward: below
/// 1120 points wide the side panels narrow, the mode switcher drops its labels and the
/// sensor panel starts folded away.
struct DojoHUD: View {
    @ObservedObject var controller: DojoController
    /// nil follows the layout's default (open when there is room).
    @LocalState private var sensorsChoice: Bool?

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 1120
            let sensorsOpen = sensorsChoice ?? !compact
            let leftWidth: CGFloat = compact ? 212 : 246
            let rightWidth: CGFloat = compact ? 232 : 290
            let insets = CameraRig.Insets(left: sensorsOpen ? leftWidth + 18 : 0, right: rightWidth + 18,
                                          top: compact ? 108 : 92, bottom: controller.showHelp ? (compact ? 92 : 64) : 0)
            ZStack(alignment: .top) {
                VStack(spacing: 10) {
                    TopBar(controller: controller)
                    HStack(alignment: .top, spacing: 0) {
                        VStack(alignment: .leading, spacing: 8) {
                            StateStrip(flags: controller.flags, link: controller.link, sensorsOpen: sensorsOpen) {
                                sensorsChoice = !sensorsOpen
                            }
                            if sensorsOpen {
                                SensorPanel(trace: controller.trace, link: controller.link).frame(width: leftWidth)
                            }
                        }
                        Spacer(minLength: 0)
                        ActivityPanel(mode: controller.mode, status: controller.status,
                                      virtualWatch: controller.link.virtualWatch) { controller.perform($0) }
                            .frame(width: rightWidth)
                    }
                    Spacer(minLength: 0)
                    VStack(spacing: 8) {
                        EngageHint(flags: controller.flags, link: controller.link, mode: controller.mode)
                        if controller.showHelp {
                            HelpPanel(virtualWatch: controller.link.virtualWatch || !controller.link.realWatch)
                        }
                    }
                }
                .padding(12)

                ToastStack(toasts: controller.toasts)
                    .padding(.top, 60)
                    .allowsHitTesting(false)

                if controller.showStats {
                    StatsSheet(controller: controller)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .onAppear { controller.setInsets(insets) }
            .onChange(of: insets) { _, new in controller.setInsets(new) }
        }
    }
}

// MARK: - Top bar

struct TopBar: View {
    @ObservedObject var controller: DojoController

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(labels: true)
            bar(labels: false)
        }
    }

    private func bar(labels: Bool) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "applewatch.radiowaves.left.and.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(DojoTheme.accent)
                if labels {
                    Text("DOJO").font(.system(size: 14, weight: .black, design: .rounded)).tracking(3)
                        .foregroundStyle(DojoTheme.textPrimary)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(DojoTheme.panel.opacity(0.90)))

            Spacer(minLength: 0)
            modeSwitcher(labels: labels)
            Spacer(minLength: 0)
            trailing(labels: labels)
        }
    }

    private func modeSwitcher(labels: Bool) -> some View {
        HStack(spacing: 3) {
            ForEach(DojoMode.allCases) { mode in
                let selected = mode == controller.mode
                Button { controller.select(mode) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: mode.symbol).font(.system(size: 12, weight: .bold))
                        if labels || selected {
                            Text(mode.title).font(.system(size: 12, weight: .bold)).lineLimit(1).fixedSize()
                        }
                    }
                    .padding(.horizontal, labels || selected ? 10 : 8)
                    .frame(height: 30)
                    .foregroundStyle(selected ? DojoTheme.background : DojoTheme.textPrimary.opacity(0.85))
                    .background(Capsule().fill(selected ? DojoTheme.accent : Color.white.opacity(0.001)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(mode.blurb)
            }
        }
        .padding(5)
        .background(Capsule().fill(DojoTheme.panel.opacity(0.92)))
        .overlay(Capsule().strokeBorder(DojoTheme.panelStroke, lineWidth: 1))
    }

    private func trailing(labels: Bool) -> some View {
        let link = controller.link
        return HStack(spacing: 6) {
            // Which wrist: yours to choose for the virtual watch, reported by a real one.
            HStack(spacing: 2) {
                ForEach([false, true], id: \.self) { right in
                    let selected = (link.realWatch ? link.rightWrist : controller.virtualRightWrist) == right
                    Button { controller.setVirtualWrist(right: right) } label: {
                        Text(right ? "R" : "L")
                            .font(.system(size: 11.5, weight: .heavy, design: .rounded))
                            .frame(width: 24, height: 24)
                            .foregroundStyle(selected ? DojoTheme.background : DojoTheme.textSecondary)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(selected ? DojoTheme.accent : Color.white.opacity(0.001)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(link.realWatch)
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.08)))
            .help(link.realWatch ? "Wrist reported by your watch" : "Which wrist the virtual watch is worn on")

            if link.realWatch {
                Chip(text: labels ? "WATCH" : "", symbol: "applewatch", tone: DojoTheme.success, filled: true)
                    .help("Your Apple Watch is streaming")
            } else {
                Chip(text: labels ? "VIRTUAL WATCH" : "VIRTUAL", symbol: "computermouse.fill", tone: DojoTheme.warning, filled: true)
                    .help("No watch connected — the mouse is driving a simulated one")
                Button { controller.autopilot.toggle() } label: { Image(systemName: "wand.and.stars") }
                    .buttonStyle(IconButtonStyle(active: controller.autopilot, tone: DojoTheme.secondary))
                    .help("Autopilot demo: let the Dojo play itself (A)")
            }
            Button { controller.showStats.toggle() } label: { Image(systemName: "chart.bar.fill") }
                .buttonStyle(IconButtonStyle(active: controller.showStats))
                .help("Personal bests and history")
            Button { controller.showHelp.toggle() } label: { Image(systemName: "questionmark") }
                .buttonStyle(IconButtonStyle(active: controller.showHelp))
                .help("Controls (H)")
        }
        .padding(.horizontal, 6)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(DojoTheme.panel.opacity(0.90)))
    }
}

// MARK: - Bottom

/// Tells the user why the pointer is not moving, when it is not.
struct EngageHint: View {
    var flags: PointerFlags
    var link: LinkStatus
    var mode: DojoMode

    private var message: (text: String, symbol: String, tone: Color)? {
        if !link.streaming {
            if mode == .live, !link.realWatch { return nil }
            return ("Waiting for the watch…", "antenna.radiowaves.left.and.right", DojoTheme.textSecondary)
        }
        if flags.paused {
            return (link.virtualWatch ? "Paused — press P to resume" : "Paused — resume from your watch", "pause.circle.fill", DojoTheme.warning)
        }
        if !flags.engaged {
            if link.virtualWatch, flags.posture == .dropped { return ("Arm lowered — press Space to raise it", "arrow.up.circle.fill", DojoTheme.accent) }
            if link.virtualWatch, flags.posture == .raised { return ("Arm raised — press U to bring it back", "arrow.down.circle.fill", DojoTheme.accent) }
            return ("Raise your forearm to point", "arrow.up.circle.fill", DojoTheme.accent)
        }
        return nil
    }

    var body: some View {
        if let message {
            Label(message.text, systemImage: message.symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(message.tone)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(DojoTheme.panel.opacity(0.94)))
                .overlay(Capsule().strokeBorder(message.tone.opacity(0.5), lineWidth: 1))
        }
    }
}

/// The always-available cheat sheet for driving the virtual watch (and the camera).
struct HelpPanel: View {
    var virtualWatch: Bool

    private var hints: [(String, String)] {
        if virtualWatch {
            return [("Mouse", "steer the arm"), ("Click", "finger tap"), ("Right-click", "flick out"),
                    ("F / ⌥ Click", "flick in · grab"), ("Scroll", "Digital Crown"), ("Space", "lower / raise arm"),
                    ("U", "arm to ceiling"), ("S", "air-scroll"), ("P", "pause"), ("R", "recenter"),
                    ("A", "autopilot"), ("⌘ Drag", "orbit"), ("⌘ Scroll", "zoom"), ("C", "reset view"), ("H", "hide")]
        }
        return [("Drag", "orbit camera"), ("Scroll / Pinch", "zoom"), ("C", "reset view"), ("P", "pause"),
                ("R", "recenter"), ("H", "hide")]
    }

    var body: some View {
        FlowLayout(spacing: 12, lineSpacing: 7) {
            ForEach(hints, id: \.0) { hint in
                KeyHint(key: hint.0, label: hint.1)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DojoTheme.panel.opacity(0.90)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(DojoTheme.panelStroke, lineWidth: 1))
    }
}

/// Gesture toasts: what was recognised and what it did.
struct ToastStack: View {
    var toasts: [GestureToast]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(toasts) { toast in
                HStack(spacing: 8) {
                    Image(systemName: toast.symbol).font(.system(size: 13, weight: .bold)).foregroundStyle(DojoTheme.accent)
                    Text(toast.title).font(.system(size: 13, weight: .heavy)).foregroundStyle(DojoTheme.textPrimary)
                    if !toast.detail.isEmpty {
                        Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundStyle(DojoTheme.textSecondary)
                        Text(toast.detail).font(.system(size: 13, weight: .semibold)).foregroundStyle(DojoTheme.accent)
                    }
                }
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(DojoTheme.panel.opacity(0.96)))
                .overlay(Capsule().strokeBorder(DojoTheme.accent.opacity(0.45), lineWidth: 1))
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: toasts)
    }
}
