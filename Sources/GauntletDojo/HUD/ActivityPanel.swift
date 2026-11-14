import SwiftUI

/// Right-hand card: what to do now, how it is going, and the buttons for the current activity.
struct ActivityPanel: View {
    var mode: DojoMode
    var status: ActivityStatus
    var virtualWatch: Bool
    var perform: (ActivityCommand) -> Void

    private var tint: Color {
        switch status.phase {
        case .ready: return DojoTheme.textSecondary
        case .running: return DojoTheme.accent
        case .finished: return DojoTheme.success
        }
    }

    var body: some View {
        HUDPanel(title: mode.title, symbol: mode.symbol, tint: tint) {
            Text(status.headline.isEmpty ? mode.title : status.headline)
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .foregroundStyle(status.newBest ? DojoTheme.success : DojoTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(status.detail.isEmpty ? mode.blurb : status.detail)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(DojoTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let progress = status.progress {
                ProgressLine(value: progress, tone: mode == .calibration ? DojoTheme.secondary : DojoTheme.accent)
            }
            if !status.steps.isEmpty { steps }
            if !status.metrics.isEmpty { metrics }
            if let note = status.note { noteBox(note) }
            if virtualWatch, let tip = status.virtualTip {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "computermouse.fill").font(.system(size: 10, weight: .bold))
                    Text("Virtual watch: \(tip)").font(.system(size: 11, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(DojoTheme.warning)
            }
            if let best = status.best {
                Label(best, systemImage: "trophy.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DojoTheme.warning)
                    .lineLimit(1)
            }
            if !status.actions.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(status.actions) { action in
                        Button { perform(action.command) } label: {
                            Label(action.title, systemImage: action.symbol)
                        }
                        .buttonStyle(HUDButtonStyle(tone: DojoTheme.accent, prominent: action.prominent))
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(status.steps) { step in
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: icon(step.state))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(color(step.state))
                        .frame(width: 13)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(step.title)
                            .font(.system(size: 11.5, weight: step.state == .current ? .heavy : .semibold))
                            .foregroundStyle(step.state == .pending ? DojoTheme.textSecondary : DojoTheme.textPrimary)
                        if !step.result.isEmpty {
                            Text(step.result).font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(step.state == .skipped ? DojoTheme.warning : DojoTheme.success)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func icon(_ state: StatusStep.State) -> String {
        switch state {
        case .pending: return "circle"
        case .current: return "arrow.right.circle.fill"
        case .done: return "checkmark.circle.fill"
        case .skipped: return "forward.end.circle"
        }
    }

    private func color(_ state: StatusStep.State) -> Color {
        switch state {
        case .pending: return DojoTheme.textSecondary.opacity(0.6)
        case .current: return DojoTheme.secondary
        case .done: return DojoTheme.success
        case .skipped: return DojoTheme.warning
        }
    }

    private var metrics: some View {
        VStack(spacing: 4) {
            ForEach(status.metrics) { metric in
                HStack {
                    Text(metric.label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(DojoTheme.textSecondary)
                    Spacer(minLength: 6)
                    Text(metric.value).font(.system(size: 12.5, weight: .heavy, design: .rounded).monospacedDigit())
                        .foregroundStyle(metric.tone.color)
                }
                .lineLimit(1)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 9)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black.opacity(0.25)))
    }

    private func noteBox(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10.5, weight: .bold))
            Text(text).font(.system(size: 11, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(status.noteTone.color)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(status.noteTone.color.opacity(0.13)))
    }
}
