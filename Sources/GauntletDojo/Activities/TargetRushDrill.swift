import AppKit
import GauntletEngine

/// Fitts's-law pointing drill: targets of varying size and distance, one at a time.
///
/// Each hit contributes an index of difficulty `log2(D / W + 1)` bits and a movement time;
/// the score is the mean of their ratios — throughput, in bits per second.
final class TargetRushDrill: Activity {
    static let targetCount = 12
    static let startCenter = CGPoint(x: 800, y: 540)
    private static let startRadius: CGFloat = 78
    private static let area = CGRect(x: 70, y: 130, width: 1460, height: 820)
    private static let radii: [CGFloat] = [34, 46, 62, 86]

    enum Phase { case ready, running, finished }

    struct Target {
        var center: CGPoint
        var radius: CGFloat
        var shownAt: TimeInterval
        /// Index of difficulty, bits.
        var difficulty: Double
    }

    struct Summary {
        var throughput: Double
        var meanTime: Double
        var hits: Int
        var misses: Int
    }

    private let records: RecordStore
    private var rng: SplitMix64
    private(set) var phase = Phase.ready
    private(set) var target: Target?
    private(set) var hits = 0
    private(set) var misses = 0
    private(set) var summary: Summary?
    private var trials: [(difficulty: Double, time: Double)] = []
    private var newBest = false
    private var finishedAt: TimeInterval = 0
    private var missAt: TimeInterval = -10
    private var lastHit: CGPoint?
    private var floaters: [Floater] = []

    init(records: RecordStore, seed: UInt64) {
        self.records = records
        rng = SplitMix64(seed: seed)
        super.init(mode: .targets)
    }

    override var isAnimating: Bool { true }

    // MARK: Play

    override func handle(_ input: SandboxInput, _ context: ActivityContext) {
        guard case .button(.left, isDown: true, clickCount: _, at: let point) = input else { return }
        needsRedraw = true
        switch phase {
        case .ready:
            if point.distance(to: Self.startCenter) <= Self.startRadius + 8 {
                start(from: point, context)
            } else {
                emit(.ripple(point, .neutral))
            }
        case .running:
            guard let current = target else { return }
            if point.distance(to: current.center) <= current.radius {
                hit(current, at: point, context)
            } else {
                misses += 1
                missAt = context.now
                floaters.append(Floater(text: "Miss", origin: point, tone: .danger, bornAt: context.now))
                emit(.ripple(point, .danger))
                emit(.haptic(.failure))
            }
        case .finished:
            if context.now - finishedAt > 1.2 { reset() }
        }
    }

    private func start(from point: CGPoint, _ context: ActivityContext) {
        phase = .running
        hits = 0
        misses = 0
        trials = []
        summary = nil
        newBest = false
        lastHit = point
        emit(.burst(point, .accent))
        target = makeTarget(from: point, now: context.now)
    }

    private func hit(_ current: Target, at point: CGPoint, _ context: ActivityContext) {
        let time = max(0.05, context.now - current.shownAt)
        trials.append((current.difficulty, time))
        hits += 1
        lastHit = current.center
        floaters.append(Floater(text: String(format: "%.0f ms", time * 1000), origin: current.center, tone: .success, bornAt: context.now))
        emit(.burst(current.center, .success))
        if hits >= Self.targetCount {
            finish(context)
        } else {
            emit(.haptic(.click))
            target = makeTarget(from: point, now: context.now)
        }
    }

    private func finish(_ context: ActivityContext) {
        phase = .finished
        finishedAt = context.now
        target = nil
        let throughput = trials.map { $0.difficulty / $0.time }.reduce(0, +) / Double(max(1, trials.count))
        let meanTime = trials.map(\.time).reduce(0, +) / Double(max(1, trials.count))
        let result = Summary(throughput: throughput, meanTime: meanTime, hits: hits, misses: misses)
        summary = result
        let line = String(format: "%.2f bits/s · %.0f ms · %d miss%@", throughput, meanTime * 1000, misses, misses == 1 ? "" : "es")
        newBest = records.add(DrillRecord(date: Date(), score: throughput, summary: line), for: .targets)
        emit(.celebrate)
        emit(.haptic(.success))
    }

    private func reset() {
        phase = .ready
        target = nil
        lastHit = nil
        floaters = []
    }

    /// A target somewhere new: random size, random distance from where the pointer is now.
    private func makeTarget(from origin: CGPoint, now: TimeInterval) -> Target {
        let radius = Self.radii.randomElement(using: &rng) ?? 50
        let field = Self.area.insetBy(dx: radius + 10, dy: radius + 10)
        var center = CGPoint(x: field.midX, y: field.midY)
        for attempt in 0..<60 {
            let reach = attempt < 40 ? CGFloat.random(in: 260...920, using: &rng) : CGFloat.random(in: 200...500, using: &rng)
            let angle = CGFloat.random(in: 0..<(2 * .pi), using: &rng)
            let candidate = CGPoint(x: origin.x + cos(angle) * reach, y: origin.y + sin(angle) * reach)
            if field.contains(candidate) { center = candidate; break }
        }
        let distance = max(1, Double(origin.distance(to: center)))
        return Target(center: center, radius: radius, shownAt: now, difficulty: log2(distance / Double(radius * 2) + 1))
    }

    override func perform(_ command: ActivityCommand, _ context: ActivityContext) {
        if command == .restart { reset(); needsRedraw = true }
    }

    override func update(_ context: ActivityContext) {
        floaters.prune(now: context.now)
    }

    // MARK: Reporting

    override func status(_ context: ActivityContext) -> ActivityStatus {
        var status = ActivityStatus()
        if let best = records.best(for: .targets) { status.best = "Best " + DojoMode.targets.formatScore(best.score) }
        switch phase {
        case .ready:
            status.headline = "Tap the START target"
            status.detail = "\(Self.targetCount) targets of different sizes. Aim, settle, tap — misses cost nothing but time."
        case .running:
            status.phase = .running
            status.headline = "Target \(min(hits + 1, Self.targetCount)) of \(Self.targetCount)"
            status.progress = Double(hits) / Double(Self.targetCount)
            let mean = trials.isEmpty ? 0 : trials.map(\.time).reduce(0, +) / Double(trials.count)
            status.metrics = [
                StatusMetric(label: "Hits", value: "\(hits)", tone: .success),
                StatusMetric(label: "Misses", value: "\(misses)", tone: misses > 0 ? .danger : .neutral),
                StatusMetric(label: "Mean time", value: trials.isEmpty ? "—" : String(format: "%.0f ms", mean * 1000)),
            ]
            status.actions = [ActivityAction(command: .restart, title: "Restart", symbol: "arrow.counterclockwise")]
        case .finished:
            status.phase = .finished
            status.headline = newBest ? "New personal best!" : "Run complete"
            status.newBest = newBest
            if let summary {
                status.metrics = [
                    StatusMetric(label: "Throughput", value: String(format: "%.2f bits/s", summary.throughput), tone: .accent),
                    StatusMetric(label: "Mean time", value: String(format: "%.0f ms", summary.meanTime * 1000)),
                    StatusMetric(label: "Hits", value: "\(summary.hits)", tone: .success),
                    StatusMetric(label: "Misses", value: "\(summary.misses)", tone: summary.misses > 0 ? .danger : .neutral),
                ]
            }
            status.detail = "Throughput combines speed and precision: bits of pointing difficulty resolved per second."
            status.actions = [ActivityAction(command: .restart, title: "Play again", symbol: "arrow.counterclockwise", prominent: true)]
        }
        return status
    }

    override func autopilotHint(_ context: ActivityContext) -> AutopilotHint {
        switch phase {
        case .ready: return .click(at: Self.startCenter, .left)
        case .running: return target.map { .click(at: $0.center, .left) } ?? .idle
        case .finished: return context.now - finishedAt > 3 ? .click(at: Self.startCenter, .left) : .idle
        }
    }

    // MARK: Drawing

    override func draw(_ p: Painter, _ context: ActivityContext) {
        let counter = phase == .ready ? "" : "\(hits) / \(Self.targetCount)"
        p.header("Target Rush", subtitle: "Tap each target as fast and cleanly as you can", trailing: counter)

        switch phase {
        case .ready:
            let pulse = CGFloat(0.5 + 0.5 * sin(context.now * 3))
            p.glow(Self.startCenter, radius: 260, color: Palette.accent, alpha: 0.22 + 0.1 * pulse)
            p.circle(Self.startCenter, Self.startRadius + 14 + 8 * pulse, stroke: Palette.accent.alpha(0.45), lineWidth: 3)
            p.circle(Self.startCenter, Self.startRadius, fill: Palette.accent.alpha(0.18), stroke: Palette.accent, lineWidth: 6)
            p.text("START", in: CGRect(x: Self.startCenter.x - 100, y: Self.startCenter.y - 24, width: 200, height: 48),
                   size: 32, weight: .heavy, align: .center, tracking: 3)
            p.text("Point here and tap your thumb and finger together",
                   in: CGRect(x: 300, y: Self.startCenter.y + 130, width: 1000, height: 40), size: 27, weight: .medium,
                   color: Palette.textSecondary, align: .center)
        case .running:
            if let target { drawTarget(p, target, context) }
        case .finished:
            drawResults(p)
        }

        let missFlash = CGFloat(max(0, 1 - (context.now - missAt) / 0.3))
        if missFlash > 0 {
            p.roundRect(p.bounds.insetBy(dx: 8, dy: 8), radius: 30, stroke: Palette.danger.alpha(missFlash), lineWidth: 14)
        }
        for floater in floaters { floater.draw(p, now: context.now) }
    }

    private func drawTarget(_ p: Painter, _ target: Target, _ context: ActivityContext) {
        if let from = lastHit {
            p.line(from, target.center, Palette.accent.alpha(0.16), width: 3, dash: [6, 14])
        }
        let age = context.now - target.shownAt
        let appear = CGFloat(min(1, age / 0.12))
        let radius = target.radius * (0.6 + 0.4 * appear)
        let pulse = CGFloat(0.5 + 0.5 * sin(age * 6))
        let hovered = context.cursor.distance(to: target.center) <= target.radius
        let tone = hovered ? Palette.success : Palette.accent
        p.glow(target.center, radius: radius * 2.6, color: tone, alpha: 0.30)
        p.circle(target.center, radius + 9 + 7 * pulse, stroke: tone.alpha(0.4), lineWidth: 3)
        p.circle(target.center, radius, fill: tone.alpha(0.20), stroke: tone, lineWidth: 6)
        p.circle(target.center, radius * 0.58, stroke: tone.alpha(0.75), lineWidth: 4)
        p.circle(target.center, max(5, radius * 0.17), fill: .white)
    }

    private func drawResults(_ p: Painter) {
        guard let summary else { return }
        let card = CGRect(x: 380, y: 210, width: 840, height: 560)
        p.glow(card.center, radius: 620, color: Palette.accent, alpha: 0.16)
        p.card(card, radius: 40, tint: Palette.accent.alpha(0.6))
        p.text("THROUGHPUT", in: CGRect(x: card.minX, y: card.minY + 44, width: card.width, height: 34), size: 24, weight: .bold,
               color: Palette.accent, align: .center, tracking: 3)
        p.text(String(format: "%.2f", summary.throughput), in: CGRect(x: card.minX, y: card.minY + 86, width: card.width, height: 150),
               size: 136, weight: .heavy, align: .center, face: .mono)
        p.text("bits per second", in: CGRect(x: card.minX, y: card.minY + 236, width: card.width, height: 40),
               size: 28, weight: .medium, color: Palette.textSecondary, align: .center)
        let cells: [(String, String, NSColor)] = [
            ("HITS", "\(summary.hits)", Palette.success),
            ("MISSES", "\(summary.misses)", summary.misses > 0 ? Palette.danger : Palette.textPrimary),
            ("MEAN TIME", String(format: "%.0f ms", summary.meanTime * 1000), Palette.textPrimary),
        ]
        let cellWidth = card.width / CGFloat(cells.count)
        for (index, cell) in cells.enumerated() {
            let x = card.minX + CGFloat(index) * cellWidth
            p.text(cell.1, in: CGRect(x: x, y: card.minY + 316, width: cellWidth, height: 60), size: 46, weight: .bold,
                   color: cell.2, align: .center, face: .mono)
            p.text(cell.0, in: CGRect(x: x, y: card.minY + 378, width: cellWidth, height: 30), size: 19, weight: .bold,
                   color: Palette.textSecondary, align: .center, tracking: 2)
        }
        p.text(newBest ? "New personal best!" : "Tap anywhere to play again",
               in: CGRect(x: card.minX, y: card.maxY - 104, width: card.width, height: 50), size: 32, weight: .bold,
               color: newBest ? Palette.success : Palette.textSecondary, align: .center)
    }
}
