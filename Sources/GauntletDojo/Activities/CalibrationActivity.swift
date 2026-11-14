import AppKit
import simd
import GauntletEngine

/// The calibration wizard's face: it draws each step on the virtual screen, narrates it in the
/// HUD panel and picks the hologram demo. The measuring itself lives in `CalibrationWizard`.
final class CalibrationActivity: Activity {
    let wizard: CalibrationWizard
    private let settingsDidChange: () -> Void
    private var needsNotify = false
    private var stepFlashAt: TimeInterval = -10
    private var now: TimeInterval = 0

    init(engine: WristEngine, sink: SandboxSink, settingsDidChange: @escaping () -> Void) {
        wizard = CalibrationWizard(engine: engine, screenSize: sink.screenSize, travel: { sink.travel })
        self.settingsDidChange = settingsDidChange
        super.init(mode: .calibration)
        wizard.onStepCompleted = { [weak self] _ in self?.stepCompleted() }
        wizard.onFinished = { [weak self] in self?.finished() }
    }

    override var isAnimating: Bool { true }

    override var ghostDemo: GhostDemo? {
        switch wizard.step {
        case .hold: return .hold
        case .raise: return wizard.subPhase == 0 ? .raise : .hold
        case .sweepHorizontal: return .sweepHorizontal
        case .sweepVertical: return .sweepVertical
        case .taps: return .tap
        case .quiet: return .wander
        case .flicks: return .flick
        case .done: return nil
        }
    }

    // MARK: Lifecycle

    override func begin(_ context: ActivityContext) {
        now = context.now
        wizard.start(now: context.now)
    }

    override func end(_ context: ActivityContext) {
        wizard.cancel()
        notifyIfNeeded()
    }

    override func update(_ context: ActivityContext) {
        now = context.now
        wizard.update(context.snapshot, now: context.now)
    }

    override func handle(_ event: EngineEvent, _ context: ActivityContext) {
        wizard.handle(event, now: context.now)
    }

    override func perform(_ command: ActivityCommand, _ context: ActivityContext) {
        switch command {
        case .restart: wizard.start(now: context.now)
        case .skip: wizard.skip(now: context.now)
        case .flipAxis: wizard.flipAxis(); needsNotify = true
        }
        needsRedraw = true
    }

    private func stepCompleted() {
        stepFlashAt = now
        needsNotify = needsNotify || wizard.changedSettings
        emit(.burst(CGPoint(x: 800, y: 560), .success))
        emit(.haptic(.success))
    }

    private func finished() {
        needsNotify = true
        notifyIfNeeded()
        emit(.celebrate)
    }

    /// Settings are only handed to the host at rest — never while the flick step has its listening threshold in place.
    private func notifyIfNeeded() {
        guard needsNotify else { return }
        needsNotify = false
        settingsDidChange()
    }

    // MARK: Narration

    private var prompt: String {
        switch wizard.step {
        case .hold: return "Point at the screen and hold still"
        case .raise: return wizard.subPhase == 0 ? "Raise your arm toward the ceiling" : "Got it — lower your arm back to the screen"
        case .sweepHorizontal: return wizard.subPhase == 0 ? "Point at the LEFT edge and pause" : "Sweep to the RIGHT edge and pause"
        case .sweepVertical: return wizard.subPhase == 0 ? "Point at the TOP edge and pause" : "Sweep down to the BOTTOM edge and pause"
        case .taps: return "Tap thumb and finger together"
        case .quiet: return "Now move around — without tapping"
        case .flicks: return "Flick your wrist out, then in"
        case .done: return "You are calibrated"
        }
    }

    private var explanation: String {
        switch wizard.step {
        case .hold: return "Hold your arm the way you will normally point. This records your resting angle."
        case .raise: return "This tells Gauntlet which way round the watch sits on your wrist."
        case .sweepHorizontal: return "Use a comfortable swing, not a stretch. It sets how far the pointer travels."
        case .sweepVertical: return "Checks the vertical reach, and that lowering to the bottom edge does not release the pointer."
        case .taps: return "Tap the way you naturally would, about once a second."
        case .quiet: return "Wave the pointer about for five seconds so taps can be told apart from movement."
        case .flicks: return "A quick twist and spring back, like shaking water off your hand. A few each way."
        case .done: return "Your settings are saved. Head to Free Play or a drill and feel the difference."
        }
    }

    private var virtualTip: String? {
        switch wizard.step {
        case .hold: return "keep the mouse still"
        case .raise: return wizard.subPhase == 0 ? "press U to raise the arm" : "press U again to lower it"
        case .sweepHorizontal: return "move the mouse left, pause, then right, pause"
        case .sweepVertical: return "move the mouse up, pause, then down, pause"
        case .taps: return "click"
        case .quiet: return "wiggle the mouse"
        case .flicks: return "right-click = out, F or ⌥-click = in"
        case .done: return nil
        }
    }

    private static func quality(_ separation: Double) -> String {
        if separation >= 2.5 { return "excellent" }
        if separation >= 1.6 { return "good" }
        if separation > 1.2 { return "marginal" }
        return "not usable"
    }

    private func result(for step: CalibrationWizard.Step) -> String {
        let report = wizard.report
        switch step {
        case .hold:
            return report.restElevationDeg.map { String(format: "resting at %.0f°", $0) } ?? ""
        case .raise:
            return report.axisCorrected.map { $0 ? "axis was backwards — fixed" : "axis correct" } ?? ""
        case .sweepHorizontal:
            guard let range = report.headingRangeDeg, let sensitivity = report.sensitivity else { return "" }
            return String(format: "%.0f° swing → %.2f× speed", range, sensitivity)
        case .sweepVertical:
            guard let range = report.verticalRangeDeg else { return "" }
            var text = String(format: "%.0f° reach", range)
            if let coverage = report.verticalCoverage { text += String(format: " · %.0f%% of height", coverage * 100) }
            if let clutch = report.clutchAngleDeg { text += String(format: " · clutch %.0f°", clutch) }
            return text
        case .taps:
            guard let weakest = wizard.tapPeaks.min(), wizard.step.rawValue > step.rawValue else { return "" }
            return String(format: "%d taps, weakest %.2f g", wizard.tapPeaks.count, weakest)
        case .quiet:
            guard let separation = report.tapSeparation, let threshold = report.tapThreshold else { return "" }
            return String(format: "%.1f× clear of movement — %@ (%.2f g)", separation, Self.quality(separation), threshold)
        case .flicks:
            return report.flickRate.map { String(format: "triggers at %.1f rad/s", $0) } ?? ""
        case .done:
            return ""
        }
    }

    override func status(_ context: ActivityContext) -> ActivityStatus {
        var status = ActivityStatus()
        let step = wizard.step
        status.phase = step == .done ? .finished : .running
        status.headline = prompt
        status.detail = explanation
        status.progress = step == .done ? nil : wizard.progress
        status.virtualTip = virtualTip
        status.steps = CalibrationWizard.Step.allCases.filter { $0 != .done }.map { item in
            var row = StatusStep(id: item.rawValue, title: item.title)
            if wizard.skipped.contains(item) {
                row.state = .skipped
                row.result = "skipped"
            } else if item.rawValue < step.rawValue {
                row.state = .done
                row.result = result(for: item)
            } else if item == step {
                row.state = .current
            }
            return row
        }

        if !wizard.isStreaming {
            status.note = "Waiting for data from the watch…"
        } else if wizard.report.tapUsable == false {
            let separation = wizard.report.tapSeparation ?? 0
            status.note = String(format: "Your taps could not be told apart from arm movement (%.1f× separation; at least 1.2× is needed). "
                                 + "Finger-tap clicking is now off. Click with a wrist flick or by tapping the watch face instead.", separation)
        } else if wizard.report.verticalInverted {
            status.note = "That downward sweep read as going up. If the pointer moves the wrong way vertically, press Flip axis."
        } else if step == .sweepHorizontal || step == .sweepVertical, !context.snapshot.engaged {
            status.note = "The pointer is released — lift your forearm a little. If it never engages, press Flip axis."
            status.noteTone = .accent
        }

        if step == .done {
            let settings = context.settings
            status.metrics = [
                StatusMetric(label: "Pointer speed", value: String(format: "%.2f×", settings.sensitivity), tone: .accent),
                StatusMetric(label: "Finger tap", value: settings.gestures.tapEnabled ? String(format: "%.2f g", settings.gestures.tapThreshold) : "off",
                             tone: settings.gestures.tapEnabled ? .success : .warning),
                StatusMetric(label: "Wrist flick", value: String(format: "%.1f rad/s", settings.gestures.flickRate), tone: .secondary),
                StatusMetric(label: "Engages above", value: String(format: "%.0f°", settings.raiseAngleDeg)),
            ]
            status.actions = [ActivityAction(command: .restart, title: "Run again", symbol: "arrow.counterclockwise")]
        } else {
            status.actions = [ActivityAction(command: .skip, title: "Skip step", symbol: "forward.end")]
        }
        if step.rawValue >= CalibrationWizard.Step.sweepHorizontal.rawValue {
            status.actions.append(ActivityAction(command: .flipAxis, title: "Flip axis", symbol: "arrow.up.arrow.down"))
        }
        return status
    }

    override func autopilotHint(_ context: ActivityContext) -> AutopilotHint {
        let neutral = VirtualControls.neutralElevation
        switch wizard.step {
        case .hold: return .pose(heading: 0, elevation: neutral)
        case .raise: return wizard.subPhase == 0 ? .raise : .pose(heading: 0, elevation: neutral)
        case .sweepHorizontal: return .pose(heading: wizard.subPhase == 0 ? 0.34 : -0.34, elevation: neutral)
        case .sweepVertical: return .pose(heading: 0, elevation: wizard.subPhase == 0 ? 0.7 : 0.22)
        case .taps: return .gesture(.pinchTap, serial: wizard.tapPeaks.count)
        case .quiet: return .wander
        case .flicks:
            let count = wizard.flicksOut.count + wizard.flicksIn.count
            return .gesture(count % 2 == 0 ? .flickOut : .flickIn, serial: count)
        case .done: return .idle
        }
    }

    // MARK: Drawing

    override func draw(_ p: Painter, _ context: ActivityContext) {
        let step = wizard.step
        let total = CalibrationWizard.Step.allCases.count - 1
        p.header("Calibration", subtitle: "Fitting Gauntlet to your arm",
                 trailing: step == .done ? "Done" : "Step \(step.rawValue + 1) of \(total)", tone: .secondary)

        // Progress rail.
        let railWidth: CGFloat = 1200, gap: CGFloat = 14
        let segment = (railWidth - gap * CGFloat(total - 1)) / CGFloat(total)
        for index in 0..<total {
            let rect = CGRect(x: 200 + CGFloat(index) * (segment + gap), y: 128, width: segment, height: 12)
            let item = CalibrationWizard.Step(rawValue: index) ?? .hold
            if wizard.skipped.contains(item) {
                p.roundRect(rect, radius: 6, fill: Palette.warning.alpha(0.5))
            } else if index < step.rawValue {
                p.roundRect(rect, radius: 6, fill: Palette.success)
            } else if index == step.rawValue {
                p.bar(rect, progress: wizard.progress, color: Palette.secondary)
            } else {
                p.roundRect(rect, radius: 6, fill: NSColor.white.alpha(0.10))
            }
        }

        let flash = CGFloat(max(0, 1 - (context.now - stepFlashAt) / 0.7))
        if flash > 0 { p.glow(CGPoint(x: 800, y: 560), radius: 700, color: Palette.success, alpha: 0.22 * flash) }

        p.text(prompt, in: CGRect(x: 100, y: 176, width: 1400, height: 96), size: 62, weight: .heavy, align: .center)
        let stage = CGRect(x: 200, y: 300, width: 1200, height: 500)
        switch step {
        case .hold: drawHold(p, stage, context)
        case .raise: drawRaise(p, stage, context)
        case .sweepHorizontal: drawSweep(p, stage, horizontal: true)
        case .sweepVertical: drawSweep(p, stage, horizontal: false)
        case .taps: drawTaps(p, stage, context)
        case .quiet: drawQuiet(p, stage, context)
        case .flicks: drawFlicks(p, stage)
        case .done: drawSummary(p, stage, context)
        }
        p.text(explanation, in: CGRect(x: 200, y: 836, width: 1200, height: 100), size: 29, weight: .medium,
               color: Palette.textSecondary, align: .center)
    }

    private func bigRing(_ p: Painter, center: CGPoint, progress: Double, tone: NSColor, symbol: String, label: String) {
        p.glow(center, radius: 330, color: tone, alpha: 0.18)
        p.circle(center, 150, stroke: NSColor.white.alpha(0.10), lineWidth: 22)
        p.ring(center, 150, progress: progress, color: tone, lineWidth: 22)
        p.symbol(symbol, center: CGPoint(x: center.x, y: center.y - 20), pointSize: 96, color: tone)
        p.text(label, in: CGRect(x: center.x - 150, y: center.y + 50, width: 300, height: 44), size: 34, weight: .bold,
               align: .center, face: .mono)
    }

    private func drawHold(_ p: Painter, _ stage: CGRect, _ context: ActivityContext) {
        let elevation = degrees(context.snapshot.elevation)
        bigRing(p, center: stage.center, progress: wizard.progress, tone: Palette.secondary, symbol: "scope",
                label: context.snapshot.streaming ? String(format: "%.0f°", elevation) : "no data")
    }

    private func drawRaise(_ p: Painter, _ stage: CGRect, _ context: ActivityContext) {
        if wizard.subPhase == 0 {
            bigRing(p, center: stage.center, progress: wizard.progress / 0.7, tone: Palette.secondary, symbol: "arrow.up",
                    label: String(format: "%+.0f°", degrees(wizard.liveSpan)))
        } else {
            let corrected = wizard.report.axisCorrected == true
            bigRing(p, center: stage.center, progress: 1, tone: Palette.success,
                    symbol: corrected ? "arrow.triangle.2.circlepath" : "checkmark",
                    label: corrected ? "axis fixed" : "axis OK")
        }
    }

    private func drawSweep(_ p: Painter, _ stage: CGRect, horizontal: Bool) {
        let tone = Palette.secondary
        let span = wizard.liveSpan
        let fraction = CGFloat((span / (horizontal ? 0.7 : 0.55)).clamped(0, 1))
        let started = wizard.subPhase == 1
        if horizontal {
            let track = CGRect(x: stage.minX + 60, y: stage.midY - 22, width: stage.width - 120, height: 44)
            p.roundRect(track, radius: 22, fill: NSColor.white.alpha(0.08), stroke: NSColor.white.alpha(0.2), lineWidth: 2)
            if started {
                p.roundRect(CGRect(x: track.minX, y: track.minY, width: max(44, track.width * fraction), height: 44), radius: 22, fill: tone)
            }
            p.symbol("arrow.left.to.line", center: CGPoint(x: track.minX - 4, y: track.minY - 60), pointSize: 54,
                     color: started ? Palette.success : tone)
            p.symbol("arrow.right.to.line", center: CGPoint(x: track.maxX + 4, y: track.minY - 60), pointSize: 54,
                     color: started ? tone : NSColor.white.alpha(0.3))
        } else {
            let track = CGRect(x: stage.midX - 22, y: stage.minY + 10, width: 44, height: stage.height - 60)
            p.roundRect(track, radius: 22, fill: NSColor.white.alpha(0.08), stroke: NSColor.white.alpha(0.2), lineWidth: 2)
            if started {
                p.roundRect(CGRect(x: track.minX, y: track.minY, width: 44, height: max(44, track.height * fraction)), radius: 22, fill: tone)
            }
            p.symbol("arrow.up.to.line", center: CGPoint(x: track.minX - 70, y: track.minY + 30), pointSize: 54,
                     color: started ? Palette.success : tone)
            p.symbol("arrow.down.to.line", center: CGPoint(x: track.minX - 70, y: track.maxY - 30), pointSize: 54,
                     color: started ? tone : NSColor.white.alpha(0.3))
        }
        let label = started ? String(format: "%.0f° swept", degrees(span)) : "waiting for you at the \(horizontal ? "left" : "top") edge"
        let labelRect = horizontal
            ? CGRect(x: stage.minX, y: stage.midY + 60, width: stage.width, height: 60)
            : CGRect(x: stage.midX + 70, y: stage.midY - 30, width: 480, height: 60)
        p.text(label, in: labelRect, size: 44, weight: .bold, color: started ? Palette.textPrimary : Palette.textSecondary,
               align: horizontal ? .center : .left, face: .mono)
    }

    private func drawTaps(_ p: Painter, _ stage: CGRect, _ context: ActivityContext) {
        let wanted = CalibrationWizard.Tuning.tapsWanted
        let spacing: CGFloat = 130
        let startX = stage.midX - spacing * CGFloat(wanted - 1) / 2
        let strongest = max(0.3, wizard.tapPeaks.max() ?? 0.3)
        for index in 0..<wanted {
            let center = CGPoint(x: startX + CGFloat(index) * spacing, y: stage.midY - 20)
            if index < wizard.tapPeaks.count {
                let peak = wizard.tapPeaks[index]
                let radius = 26 + 26 * CGFloat(peak / strongest)
                p.glow(center, radius: radius * 2.2, color: Palette.secondary, alpha: 0.4)
                p.circle(center, radius, fill: Palette.secondary)
                p.text(String(format: "%.2f", peak), in: CGRect(x: center.x - 60, y: center.y + 70, width: 120, height: 30),
                       size: 22, weight: .semibold, color: Palette.textSecondary, align: .center, face: .mono)
            } else {
                let next = index == wizard.tapPeaks.count
                p.circle(center, 40, stroke: NSColor.white.alpha(next ? 0.9 : 0.22), lineWidth: next ? 5 : 3, dash: next ? [] : [8, 8])
            }
        }
        p.text("\(wizard.tapPeaks.count) / \(wanted)", in: CGRect(x: stage.minX, y: stage.maxY - 110, width: stage.width, height: 70),
               size: 60, weight: .heavy, align: .center, face: .mono)
        // Live energy, so a tap that was too soft is visibly too soft.
        let level = CGFloat((context.snapshot.tapEnvelope / 0.4).clamped(0, 1))
        p.bar(CGRect(x: stage.midX - 260, y: stage.minY + 20, width: 520, height: 12), progress: Double(level), color: Palette.accent)
    }

    private func drawQuiet(_ p: Painter, _ stage: CGRect, _ context: ActivityContext) {
        let remaining = max(0, CalibrationWizard.Tuning.quietTime * (1 - wizard.progress))
        let moving = simd_length(context.snapshot.gyro) > CalibrationWizard.Tuning.movingRate
        bigRing(p, center: stage.center, progress: wizard.progress, tone: moving ? Palette.secondary : Palette.warning,
                symbol: "hand.wave.fill", label: moving ? String(format: "%.1f s", remaining) : "keep moving")
        p.text("\(wizard.noisePeaks.count) movement bumps heard", in: CGRect(x: stage.minX, y: stage.maxY - 50, width: stage.width, height: 40),
               size: 26, weight: .medium, color: Palette.textSecondary, align: .center)
    }

    private func drawFlicks(_ p: Painter, _ stage: CGRect) {
        let wanted = CalibrationWizard.Tuning.flicksEachWay
        let rows: [(String, String, [Double], NSColor)] = [
            ("OUT", "arrow.clockwise", wizard.flicksOut, Palette.secondary),
            ("IN", "arrow.counterclockwise", wizard.flicksIn, Palette.success),
        ]
        for (number, row) in rows.enumerated() {
            let y = stage.minY + 130 + CGFloat(number) * 200
            p.symbol(row.1, center: CGPoint(x: stage.minX + 250, y: y), pointSize: 70, color: row.3)
            p.text(row.0, in: CGRect(x: stage.minX + 320, y: y - 30, width: 160, height: 60), size: 48, weight: .heavy, color: row.3)
            for index in 0..<wanted {
                let center = CGPoint(x: stage.minX + 560 + CGFloat(index) * 130, y: y)
                if index < row.2.count {
                    p.glow(center, radius: 90, color: row.3, alpha: 0.4)
                    p.circle(center, 40, fill: row.3)
                    p.text(String(format: "%.1f", row.2[index]), in: CGRect(x: center.x - 50, y: center.y - 18, width: 100, height: 36),
                           size: 24, weight: .bold, color: Palette.background, align: .center, face: .mono)
                } else {
                    p.circle(center, 40, stroke: NSColor.white.alpha(0.25), lineWidth: 3, dash: [8, 8])
                }
            }
            if row.2.count > wanted {
                p.text("+\(row.2.count - wanted)", in: CGRect(x: stage.minX + 950, y: y - 24, width: 120, height: 48), size: 34,
                       weight: .bold, color: row.3, face: .mono)
            }
        }
        p.text("peak twist rate, rad/s", in: CGRect(x: stage.minX, y: stage.maxY - 60, width: stage.width, height: 36), size: 24,
               weight: .medium, color: Palette.textSecondary, align: .center)
    }

    private func drawSummary(_ p: Painter, _ stage: CGRect, _ context: ActivityContext) {
        let card = stage.insetBy(dx: 60, dy: 0)
        p.card(card, radius: 40, tint: Palette.success.alpha(0.6))
        p.symbol("checkmark.seal.fill", center: CGPoint(x: card.minX + 150, y: card.midY), pointSize: 150,
                 color: Palette.background, backing: Palette.success)
        let steps: [CalibrationWizard.Step] = [.hold, .raise, .sweepHorizontal, .sweepVertical, .quiet, .flicks]
        for (index, step) in steps.enumerated() {
            let y = card.minY + 38 + CGFloat(index) * 72
            let skipped = wizard.skipped.contains(step)
            let text = skipped ? "skipped" : result(for: step)
            let warn = step == .quiet && wizard.report.tapUsable == false
            p.text(step == .quiet ? "Finger tap" : step.title, in: CGRect(x: card.minX + 300, y: y, width: 330, height: 60), size: 27,
                   weight: .semibold, color: Palette.textSecondary)
            p.text(text.isEmpty ? "—" : text, in: CGRect(x: card.minX + 620, y: y, width: card.width - 640, height: 60), size: 24,
                   weight: .bold, color: skipped || warn ? Palette.warning : Palette.textPrimary)
        }
    }
}
