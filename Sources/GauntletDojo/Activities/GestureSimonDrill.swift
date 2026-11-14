import AppKit
import GauntletEngine

/// "Simon says" for gestures: perform the gesture shown; measures recognition accuracy and reaction time.
final class GestureSimonDrill: Activity {
    enum Phase: Equatable {
        case ready
        case waiting(until: TimeInterval)
        case prompting(since: TimeInterval)
        case finished(at: TimeInterval)
    }

    enum Outcome: Equatable {
        case correct(time: Double)
        case wrong(GestureKind)
        case missed
    }

    static let promptCount = 12
    private static let timeout = 4.0
    private static let kinds: [GestureKind] = [.pinchTap, .flickOut, .flickIn]

    private let records: RecordStore
    private var rng: SplitMix64
    private(set) var phase = Phase.ready
    private(set) var prompts: [GestureKind] = []
    private(set) var outcomes: [Outcome] = []
    private(set) var falseStarts = 0
    private var runs = 0
    private var lastOutcomeAt: TimeInterval = -10
    private var earlyAt: TimeInterval = -10
    private var newBest = false
    private var now: TimeInterval = 0

    init(records: RecordStore, seed: UInt64) {
        self.records = records
        rng = SplitMix64(seed: seed)
        super.init(mode: .simon)
    }

    override var isAnimating: Bool { true }

    var correctCount: Int { outcomes.filter { if case .correct = $0 { return true } else { return false } }.count }

    var meanReaction: Double {
        let times = outcomes.compactMap { outcome -> Double? in
            if case .correct(let time) = outcome { return time } else { return nil }
        }
        return times.isEmpty ? 0 : times.reduce(0, +) / Double(times.count)
    }

    var accuracy: Double { outcomes.isEmpty ? 0 : Double(correctCount) / Double(outcomes.count) }

    /// Folds the several ways of "tapping" into one; nil for gestures the drill does not use.
    private static func normalise(_ kind: GestureKind) -> GestureKind? {
        switch kind {
        case .pinchTap, .handDoubleTap, .screenTap, .dwell: return .pinchTap
        case .flickOut: return .flickOut
        case .flickIn: return .flickIn
        case .screenDoubleTap, .screenLongPress: return nil
        }
    }

    // MARK: Play

    private func start(_ context: ActivityContext) {
        runs += 1
        prompts = (0..<Self.promptCount).map { Self.kinds[$0 % Self.kinds.count] }.shuffled(using: &rng)
        outcomes = []
        falseStarts = 0
        newBest = false
        phase = .waiting(until: context.now + 1.0)
        emit(.haptic(.notify))
    }

    override func handle(_ event: EngineEvent, _ context: ActivityContext) {
        guard case .gesture(let raw, _) = event, let kind = Self.normalise(raw) else { return }
        needsRedraw = true
        switch phase {
        case .ready:
            if kind == .pinchTap { start(context) }
        case .waiting:
            falseStarts += 1
            earlyAt = context.now
        case .prompting(let since):
            let wanted = prompts[outcomes.count]
            if kind == wanted {
                record(.correct(time: max(0.05, context.now - since)), context)
            } else {
                record(.wrong(kind), context)
            }
        case .finished(let at):
            if kind == .pinchTap, context.now - at > 1.5 { phase = .ready }
        }
    }

    private func record(_ outcome: Outcome, _ context: ActivityContext) {
        outcomes.append(outcome)
        lastOutcomeAt = context.now
        let center = CGPoint(x: 800, y: 440)
        if case .correct = outcome {
            emit(.burst(center, .success))
            emit(.haptic(.success))
        } else {
            emit(.ripple(center, .danger))
            emit(.haptic(.failure))
        }
        if outcomes.count >= prompts.count {
            finish(context)
        } else {
            phase = .waiting(until: context.now + Double.random(in: 1.0...1.9, using: &rng))
        }
    }

    private func finish(_ context: ActivityContext) {
        phase = .finished(at: context.now)
        // Accuracy first; reaction time only separates equally accurate runs.
        let score = accuracy * 100 - min(meanReaction, 3) * 5
        let line = String(format: "%.0f%% correct · %.0f ms", accuracy * 100, meanReaction * 1000)
        newBest = records.add(DrillRecord(date: Date(), score: score, summary: line), for: .simon)
        emit(.celebrate)
    }

    override func update(_ context: ActivityContext) {
        now = context.now
        switch phase {
        case .waiting(let until):
            if context.now >= until { phase = .prompting(since: context.now); emit(.haptic(.notify)) }
        case .prompting(let since):
            if context.now - since > Self.timeout { record(.missed, context) }
        default:
            break
        }
    }

    override func perform(_ command: ActivityCommand, _ context: ActivityContext) {
        if command == .restart { phase = .ready; outcomes = []; prompts = []; needsRedraw = true }
    }

    // MARK: Reporting

    override func status(_ context: ActivityContext) -> ActivityStatus {
        var status = ActivityStatus()
        if let best = records.best(for: .simon) { status.best = "Best " + best.summary }
        switch phase {
        case .ready:
            status.headline = "Tap to start"
            status.detail = "\(Self.promptCount) prompts: tap, flick out or flick in. Wait for each prompt — early gestures count against you."
        case .waiting, .prompting:
            status.phase = .running
            status.headline = "Prompt \(min(outcomes.count + 1, Self.promptCount)) of \(Self.promptCount)"
            status.progress = Double(outcomes.count) / Double(Self.promptCount)
            status.metrics = [
                StatusMetric(label: "Correct", value: "\(correctCount) / \(outcomes.count)", tone: .success),
                StatusMetric(label: "Reaction", value: correctCount == 0 ? "—" : String(format: "%.0f ms", meanReaction * 1000), tone: .accent),
                StatusMetric(label: "Too early", value: "\(falseStarts)", tone: falseStarts > 0 ? .warning : .neutral),
            ]
            status.actions = [ActivityAction(command: .restart, title: "Restart", symbol: "arrow.counterclockwise")]
        case .finished:
            status.phase = .finished
            status.headline = newBest ? "New personal best!" : "Run complete"
            status.newBest = newBest
            status.metrics = [
                StatusMetric(label: "Accuracy", value: String(format: "%.0f%%", accuracy * 100), tone: .success),
                StatusMetric(label: "Reaction", value: String(format: "%.0f ms", meanReaction * 1000), tone: .accent),
                StatusMetric(label: "Too early", value: "\(falseStarts)", tone: falseStarts > 0 ? .warning : .neutral),
            ]
            status.actions = [ActivityAction(command: .restart, title: "Play again", symbol: "arrow.counterclockwise", prominent: true)]
        }
        if !context.snapshot.engaged, context.snapshot.streaming {
            status.note = "Gestures only register while the pointer is engaged — raise your arm."
        }
        status.virtualTip = "click = tap, right-click = flick out, F = flick in"
        return status
    }

    override func autopilotHint(_ context: ActivityContext) -> AutopilotHint {
        switch phase {
        case .ready: return .gesture(.pinchTap, serial: -1 - runs)
        case .waiting: return .idle
        case .prompting: return .gesture(prompts[outcomes.count], serial: runs * 100 + outcomes.count)
        case .finished(let at): return context.now - at > 3 ? .gesture(.pinchTap, serial: -1000 - runs) : .idle
        }
    }

    // MARK: Drawing

    private static func tone(_ kind: GestureKind) -> Tone {
        switch kind {
        case .flickOut: return .secondary
        case .flickIn: return .success
        default: return .accent
        }
    }

    private static func word(_ kind: GestureKind) -> String {
        switch kind {
        case .flickOut: return "FLICK OUT"
        case .flickIn: return "FLICK IN"
        default: return "TAP"
        }
    }

    private static func howTo(_ kind: GestureKind) -> String {
        switch kind {
        case .flickOut: return "Twist your wrist outward and let it spring back"
        case .flickIn: return "Twist your wrist inward and let it spring back"
        default: return "Touch thumb and finger together"
        }
    }

    private static func glyph(_ kind: GestureKind) -> String {
        kind == .pinchTap ? "hand.pinch.fill" : kind.symbol
    }

    override func draw(_ p: Painter, _ context: ActivityContext) {
        let counter: String
        if case .ready = phase { counter = "" } else { counter = "\(outcomes.count) / \(Self.promptCount)" }
        p.header("Gesture Simon", subtitle: "Do what the screen says, as fast as you can", trailing: counter)
        let card = CGRect(x: 360, y: 150, width: 880, height: 580)

        switch phase {
        case .ready:
            p.card(card, radius: 44)
            p.text("Tap to start", in: CGRect(x: card.minX, y: card.minY + 46, width: card.width, height: 80), size: 64,
                   weight: .heavy, align: .center)
            for (index, kind) in Self.kinds.enumerated() {
                let x = card.minX + card.width * (CGFloat(index) + 0.5) / 3
                let tone = Self.tone(kind).ns
                p.circle(CGPoint(x: x, y: card.minY + 280), 78, fill: tone.alpha(0.14), stroke: tone.alpha(0.8), lineWidth: 3)
                p.symbol(Self.glyph(kind), center: CGPoint(x: x, y: card.minY + 280), pointSize: 64, color: tone)
                p.text(Self.word(kind), in: CGRect(x: x - 140, y: card.minY + 380, width: 280, height: 36), size: 26,
                       weight: .heavy, color: tone, align: .center, tracking: 2)
            }
            p.text("\(Self.promptCount) prompts · wait for each one", in: CGRect(x: card.minX, y: card.maxY - 100, width: card.width, height: 40),
                   size: 26, weight: .medium, color: Palette.textSecondary, align: .center)

        case .waiting:
            p.card(card, radius: 44)
            drawLastOutcome(p, card, context)
            let dots = Int(context.now * 3) % 3 + 1
            p.text("Get ready" + String(repeating: ".", count: dots), in: CGRect(x: card.minX, y: card.maxY - 140, width: card.width, height: 60),
                   size: 40, weight: .semibold, color: Palette.textSecondary, align: .center)
            if context.now - earlyAt < 1 {
                p.text("Too early!", in: CGRect(x: card.minX, y: card.minY + 40, width: card.width, height: 50), size: 36,
                       weight: .bold, color: Palette.warning, align: .center)
            }

        case .prompting(let since):
            let kind = prompts[outcomes.count]
            let tone = Self.tone(kind).ns
            let age = context.now - since
            let pop = CGFloat(min(1, age / 0.12))
            p.glow(CGPoint(x: card.midX, y: card.minY + 200), radius: 520, color: tone, alpha: 0.30)
            p.roundRect(card, radius: 44, fill: Palette.panel.mixed(with: tone, 0.16), stroke: tone, lineWidth: 5)
            p.symbol(Self.glyph(kind), center: CGPoint(x: card.midX, y: card.minY + 170), pointSize: 150 * (0.7 + 0.3 * pop), color: tone, weight: .bold)
            p.text(Self.word(kind), in: CGRect(x: card.minX, y: card.minY + 300, width: card.width, height: 130), size: 112,
                   weight: .heavy, align: .center, tracking: 4)
            p.text(Self.howTo(kind), in: CGRect(x: card.minX, y: card.minY + 432, width: card.width, height: 44), size: 30,
                   weight: .medium, color: Palette.textSecondary, align: .center)
            p.bar(CGRect(x: card.minX + 60, y: card.maxY - 60, width: card.width - 120, height: 14),
                  progress: 1 - age / Self.timeout, color: tone)

        case .finished:
            p.card(card, radius: 44, tint: Palette.accent.alpha(0.6))
            p.text("ACCURACY", in: CGRect(x: card.minX, y: card.minY + 44, width: card.width, height: 34), size: 24, weight: .bold,
                   color: Palette.accent, align: .center, tracking: 3)
            p.text(String(format: "%.0f%%", accuracy * 100), in: CGRect(x: card.minX, y: card.minY + 84, width: card.width, height: 150),
                   size: 136, weight: .heavy, align: .center, face: .mono)
            p.text(correctCount == 0 ? "No gesture recognised in time" : String(format: "Mean reaction %.0f ms", meanReaction * 1000),
                   in: CGRect(x: card.minX, y: card.minY + 250, width: card.width, height: 44), size: 34, weight: .semibold, align: .center)
            p.text(falseStarts == 0 ? "No false starts" : "\(falseStarts) too early",
                   in: CGRect(x: card.minX, y: card.minY + 306, width: card.width, height: 40), size: 28, weight: .medium,
                   color: falseStarts == 0 ? Palette.success : Palette.warning, align: .center)
            p.text(newBest ? "New personal best!" : "Tap to play again",
                   in: CGRect(x: card.minX, y: card.maxY - 100, width: card.width, height: 44), size: 30, weight: .bold,
                   color: newBest ? Palette.success : Palette.textSecondary, align: .center)
        }
        drawPips(p)
    }

    private func drawLastOutcome(_ p: Painter, _ card: CGRect, _ context: ActivityContext) {
        guard let last = outcomes.last, context.now - lastOutcomeAt < 2.2 else {
            p.symbol("hourglass", center: CGPoint(x: card.midX, y: card.minY + 220), pointSize: 110, color: NSColor.white.alpha(0.25))
            return
        }
        let center = CGPoint(x: card.midX, y: card.minY + 190)
        switch last {
        case .correct(let time):
            p.symbol("checkmark.circle.fill", center: center, pointSize: 130, color: Palette.background, backing: Palette.success)
            p.text(String(format: "%.0f ms", time * 1000), in: CGRect(x: card.minX, y: card.minY + 290, width: card.width, height: 80),
                   size: 68, weight: .heavy, color: Palette.success, align: .center, face: .mono)
        case .wrong(let kind):
            p.symbol("xmark.circle.fill", center: center, pointSize: 130, color: Palette.background, backing: Palette.danger)
            p.text("That was a \(Self.word(kind).lowercased())", in: CGRect(x: card.minX, y: card.minY + 300, width: card.width, height: 60),
                   size: 44, weight: .bold, color: Palette.danger, align: .center)
        case .missed:
            p.symbol("clock.badge.xmark", center: center, pointSize: 120, color: Palette.warning, backing: Palette.warning)
            p.text("Not recognised in time", in: CGRect(x: card.minX, y: card.minY + 300, width: card.width, height: 60),
                   size: 44, weight: .bold, color: Palette.warning, align: .center)
        }
    }

    /// One pip per prompt along the bottom.
    private func drawPips(_ p: Painter) {
        guard !prompts.isEmpty else { return }
        let spacing: CGFloat = 76
        let startX = 800 - spacing * CGFloat(prompts.count - 1) / 2
        for index in prompts.indices {
            let center = CGPoint(x: startX + CGFloat(index) * spacing, y: 830)
            if index < outcomes.count {
                let color: NSColor
                switch outcomes[index] {
                case .correct: color = Palette.success
                case .wrong: color = Palette.danger
                case .missed: color = Palette.warning
                }
                p.circle(center, 22, fill: color)
                p.symbol(Self.glyph(prompts[index]), center: center, pointSize: 20, color: Palette.background, weight: .bold)
            } else {
                let current = index == outcomes.count
                p.circle(center, 22, stroke: NSColor.white.alpha(current ? 0.9 : 0.25), lineWidth: current ? 4 : 2.5)
            }
        }
    }
}
