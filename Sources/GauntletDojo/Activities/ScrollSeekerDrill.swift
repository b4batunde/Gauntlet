import AppKit
import GauntletEngine

/// Scroll a long list until the highlighted row sits in the focus band, and hold it there.
/// Works with the Digital Crown or with air-scroll.
final class ScrollSeekerDrill: Activity {
    enum Phase { case ready, running, finished }

    static let rowCount = 160
    static let rounds = 5
    private static let rowHeight: CGFloat = 64
    private static let viewport = CGRect(x: 330, y: 126, width: 940, height: 832)
    /// How far (in rows) the target may sit from the band's centre and still count.
    private static let tolerance = 0.45
    private static let holdTime = 0.5

    private let records: RecordStore
    private var rng: SplitMix64
    private(set) var phase = Phase.ready
    private(set) var offset: CGFloat
    private(set) var targetRow: Int
    private(set) var round = 0
    private(set) var overshoots = 0
    private var times: [Double] = []
    private var shownAt: TimeInterval = 0
    private var insideSince: TimeInterval?
    private var lastSide = 0
    private var finishedAt: TimeInterval = 0
    private var lockedAt: TimeInterval = -10
    private var newBest = false
    private var now: TimeInterval = 0

    init(records: RecordStore, seed: UInt64) {
        self.records = records
        rng = SplitMix64(seed: seed)
        offset = Self.offset(centering: Self.rowCount / 2)
        targetRow = Self.rowCount / 2
        super.init(mode: .scroll)
        targetRow = nextTarget(goingUp: Bool.random(using: &rng))
    }

    override var isAnimating: Bool { phase == .running || now - lockedAt < 0.8 }

    private static var maxOffset: CGFloat { CGFloat(rowCount) * rowHeight - viewport.height }

    private static func offset(centering row: Int) -> CGFloat {
        ((CGFloat(row) + 0.5) * rowHeight - viewport.height / 2).clamped(0, maxOffset)
    }

    /// Row (fractional) currently at the centre of the focus band.
    private var centerRow: Double { Double((offset + Self.viewport.height / 2) / Self.rowHeight) - 0.5 }

    /// Rows from the band to the target; positive when the target is further down the list.
    var rowsToTarget: Double { Double(targetRow) - centerRow }

    var meanTime: Double { times.isEmpty ? 0 : times.reduce(0, +) / Double(times.count) }

    private func nextTarget(goingUp: Bool) -> Int {
        let here = Int(centerRow.rounded())
        let jump = Int.random(in: 14...42, using: &rng)
        var row = goingUp ? here - jump : here + jump
        if row < 8 || row > Self.rowCount - 9 { row = goingUp ? here + jump : here - jump }
        return row.clamped(8, Self.rowCount - 9)
    }

    private func reset() {
        phase = .ready
        round = 0
        overshoots = 0
        times = []
        insideSince = nil
        newBest = false
        targetRow = nextTarget(goingUp: Bool.random(using: &rng))
        needsRedraw = true
    }

    // MARK: Play

    override func handle(_ input: SandboxInput, _ context: ActivityContext) {
        switch input {
        case .scroll(dx: _, dy: let dy, at: _):
            guard phase != .finished else { return }
            if phase == .ready {
                phase = .running
                shownAt = context.now
                lastSide = 0
            }
            offset = (offset - CGFloat(dy)).clamped(0, Self.maxOffset)
            needsRedraw = true
        case .button(.left, isDown: true, clickCount: _, at: let point):
            if phase == .finished, context.now - finishedAt > 1.2 { reset() } else { emit(.ripple(point, .neutral)) }
        default:
            break
        }
    }

    override func update(_ context: ActivityContext) {
        now = context.now
        guard phase == .running else { return }
        let error = rowsToTarget
        // Passing straight through the band and out the other side is an overshoot.
        let side = error > 0.6 ? 1 : (error < -0.6 ? -1 : 0)
        if side != 0 {
            if lastSide != 0, side != lastSide { overshoots += 1 }
            lastSide = side
        }
        guard abs(error) <= Self.tolerance else { insideSince = nil; return }
        guard let since = insideSince else { insideSince = context.now; return }
        if context.now - since >= Self.holdTime { lock(since, context) }
    }

    private func lock(_ arrivedAt: TimeInterval, _ context: ActivityContext) {
        times.append(max(0.05, arrivedAt - shownAt))
        round += 1
        insideSince = nil
        lockedAt = context.now
        let bandCenter = CGPoint(x: Self.viewport.midX, y: Self.viewport.midY)
        emit(.burst(bandCenter, .success))
        emit(.haptic(.success))
        if round >= Self.rounds {
            phase = .finished
            finishedAt = context.now
            let line = String(format: "%.2f s per row · %d overshoot%@", meanTime, overshoots, overshoots == 1 ? "" : "s")
            newBest = records.add(DrillRecord(date: Date(), score: meanTime, summary: line), for: .scroll)
            emit(.celebrate)
        } else {
            targetRow = nextTarget(goingUp: round % 2 == 0 ? Bool.random(using: &rng) : rowsToTarget >= 0)
            shownAt = context.now
            lastSide = 0
        }
        needsRedraw = true
    }

    override func perform(_ command: ActivityCommand, _ context: ActivityContext) {
        if command == .restart { reset() }
    }

    // MARK: Reporting

    override func status(_ context: ActivityContext) -> ActivityStatus {
        var status = ActivityStatus()
        if let best = records.best(for: .scroll) { status.best = "Best " + DojoMode.scroll.formatScore(best.score) }
        switch phase {
        case .ready:
            status.headline = "Scroll to the glowing row"
            status.detail = "Turn the Digital Crown, or switch on air-scroll and tilt your arm. Park the row in the band and hold it."
        case .running:
            status.phase = .running
            status.headline = "Row \(round + 1) of \(Self.rounds)"
            status.progress = Double(round) / Double(Self.rounds)
            let rows = max(1, Int(abs(rowsToTarget).rounded()))
            let inBand = abs(rowsToTarget) <= Self.tolerance
            status.metrics = [
                StatusMetric(label: "Distance", value: inBand ? "in the band" : "\(rows) row\(rows == 1 ? "" : "s") \(rowsToTarget > 0 ? "down" : "up")", tone: .accent),
                StatusMetric(label: "Overshoots", value: "\(overshoots)", tone: overshoots > 0 ? .warning : .neutral),
                StatusMetric(label: "Mean time", value: times.isEmpty ? "—" : String(format: "%.2f s", meanTime)),
            ]
            status.actions = [ActivityAction(command: .restart, title: "Restart", symbol: "arrow.counterclockwise")]
        case .finished:
            status.phase = .finished
            status.headline = newBest ? "New personal best!" : "Run complete"
            status.newBest = newBest
            status.metrics = [
                StatusMetric(label: "Mean time", value: String(format: "%.2f s / row", meanTime), tone: .accent),
                StatusMetric(label: "Overshoots", value: "\(overshoots)", tone: overshoots > 0 ? .warning : .neutral),
            ]
            status.actions = [ActivityAction(command: .restart, title: "Play again", symbol: "arrow.counterclockwise", prominent: true)]
        }
        status.virtualTip = "scroll wheel is the crown; S toggles air-scroll"
        return status
    }

    override func autopilotHint(_ context: ActivityContext) -> AutopilotHint {
        if phase == .finished {
            return context.now - finishedAt > 3 ? .click(at: Self.viewport.center, .left) : .idle
        }
        let pixels = Double(offset - Self.offset(centering: targetRow))
        return abs(pixels) < 10 ? .idle : .scroll(dy: pixels)
    }

    // MARK: Drawing

    override func draw(_ p: Painter, _ context: ActivityContext) {
        p.header("Scroll Seeker", subtitle: "Bring the glowing row into the band and hold it",
                 trailing: phase == .ready ? "" : "\(min(round + (phase == .finished ? 0 : 1), Self.rounds)) / \(Self.rounds)")
        let viewport = Self.viewport
        p.card(viewport.insetBy(dx: -14, dy: -10), radius: 28)

        p.clipped(to: viewport, radius: 18) {
            let first = max(0, Int(offset / Self.rowHeight))
            let last = min(Self.rowCount - 1, first + Int(viewport.height / Self.rowHeight) + 1)
            guard first <= last else { return }
            for row in first...last {
                let y = viewport.minY + CGFloat(row) * Self.rowHeight - offset
                let rect = CGRect(x: viewport.minX + 6, y: y + 4, width: viewport.width - 12, height: Self.rowHeight - 8)
                let isTarget = row == targetRow && phase != .finished
                if isTarget {
                    p.roundRect(rect, radius: 14, fill: Palette.accent.alpha(0.30), stroke: Palette.accent, lineWidth: 4)
                    p.text("TARGET", in: CGRect(x: rect.maxX - 200, y: rect.minY, width: 176, height: rect.height), size: 22,
                           weight: .heavy, color: Palette.accent, align: .right, tracking: 3)
                } else {
                    p.roundRect(rect, radius: 14, fill: NSColor.white.alpha(row % 2 == 0 ? 0.06 : 0.03))
                }
                p.text(String(format: "%03d", row + 1), in: CGRect(x: rect.minX + 26, y: rect.minY, width: 90, height: rect.height),
                       size: 25, weight: .bold, color: isTarget ? .white : Palette.textSecondary, face: .mono)
                // Bars of varying length stand in for content.
                let width = CGFloat(120 + (row * 73) % 330)
                p.roundRect(CGRect(x: rect.minX + 130, y: rect.midY - 7, width: width, height: 14), radius: 7,
                            fill: NSColor.white.alpha(isTarget ? 0.75 : 0.14))
            }
        }

        // Focus band.
        let inside = phase == .running && abs(rowsToTarget) <= Self.tolerance
        let flash = CGFloat(max(0, 1 - (context.now - lockedAt) / 0.7))
        let bandTone = (inside || flash > 0) ? Palette.success : NSColor.white.alpha(0.75)
        let band = CGRect(x: viewport.minX - 22, y: viewport.midY - Self.rowHeight / 2 - 6, width: viewport.width + 44, height: Self.rowHeight + 12)
        if flash > 0 { p.glow(band.center, radius: 560, color: Palette.success, alpha: 0.35 * flash) }
        p.roundRect(band, radius: 20, stroke: bandTone, lineWidth: inside ? 6 : 4)
        if inside, let since = insideSince {
            p.ring(CGPoint(x: band.maxX + 50, y: band.midY), 26, progress: (context.now - since) / Self.holdTime, color: Palette.success, lineWidth: 8)
        }

        drawGuide(p)
        if phase == .finished { drawResults(p) }
    }

    /// Left margin: which way to scroll and how far.
    private func drawGuide(_ p: Painter) {
        guard phase != .finished else { return }
        let rows = rowsToTarget
        let count = max(1, Int(abs(rows).rounded()))
        let center = CGPoint(x: 172, y: Self.viewport.midY)
        if abs(rows) <= Self.tolerance {
            p.symbol("checkmark.circle.fill", center: center, pointSize: 96, color: Palette.background, backing: Palette.success)
            p.text("Hold it…", in: CGRect(x: 40, y: center.y + 76, width: 264, height: 40), size: 28, weight: .bold,
                   color: Palette.success, align: .center)
        } else {
            let down = rows > 0
            p.symbol(down ? "chevron.down.circle.fill" : "chevron.up.circle.fill", center: center, pointSize: 96,
                     color: Palette.background, backing: Palette.accent)
            p.text("\(count)", in: CGRect(x: 40, y: center.y + 70, width: 264, height: 76), size: 70, weight: .heavy, align: .center, face: .mono)
            p.text(count == 1 ? "row \(down ? "down" : "up")" : "rows \(down ? "down" : "up")",
                   in: CGRect(x: 40, y: center.y + 146, width: 264, height: 34), size: 24, weight: .semibold,
                   color: Palette.textSecondary, align: .center)
        }
        // Right margin: rounds done.
        for index in 0..<Self.rounds {
            let dot = CGPoint(x: 1430, y: Self.viewport.midY - 120 + CGFloat(index) * 60)
            let done = index < round
            p.circle(dot, 15, fill: done ? Palette.success : nil, stroke: done ? nil : NSColor.white.alpha(0.3), lineWidth: 3)
            if done, index < times.count {
                p.text(String(format: "%.1f s", times[index]), in: CGRect(x: dot.x + 28, y: dot.y - 16, width: 120, height: 32),
                       size: 22, weight: .semibold, color: Palette.textSecondary, face: .mono)
            }
        }
    }

    private func drawResults(_ p: Painter) {
        let card = CGRect(x: 410, y: 300, width: 780, height: 400)
        p.roundRect(card, radius: 40, fill: Palette.panel.alpha(0.96), stroke: Palette.accent.alpha(0.6), lineWidth: 2)
        p.text("MEAN SEEK TIME", in: CGRect(x: card.minX, y: card.minY + 40, width: card.width, height: 34), size: 24,
               weight: .bold, color: Palette.accent, align: .center, tracking: 3)
        p.text(String(format: "%.2f s", meanTime), in: CGRect(x: card.minX, y: card.minY + 80, width: card.width, height: 140),
               size: 120, weight: .heavy, align: .center, face: .mono)
        p.text(overshoots == 0 ? "No overshoots" : "\(overshoots) overshoot\(overshoots == 1 ? "" : "s")",
               in: CGRect(x: card.minX, y: card.minY + 232, width: card.width, height: 40), size: 30, weight: .semibold,
               color: overshoots == 0 ? Palette.success : Palette.warning, align: .center)
        p.text(newBest ? "New personal best!" : "Tap anywhere to play again",
               in: CGRect(x: card.minX, y: card.maxY - 88, width: card.width, height: 44), size: 28, weight: .bold,
               color: newBest ? Palette.success : Palette.textSecondary, align: .center)
    }
}
