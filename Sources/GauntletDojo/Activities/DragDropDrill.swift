import AppKit
import GauntletEngine

/// Grab (flick in), carry, release (flick in again): sort six tokens into their zones against the clock.
final class DragDropDrill: Activity {
    enum Phase { case ready, running, finished }
    enum Shape: CaseIterable { case circle, square, triangle }

    struct Zone {
        var shape: Shape
        var tone: Tone
        var title: String
        var rect: CGRect

        func slot(_ index: Int) -> CGPoint {
            CGPoint(x: rect.midX + (index == 0 ? -96 : 96), y: rect.midY + 22)
        }
    }

    struct Token {
        var zone: Int
        var position: CGPoint
        var home: CGPoint
        var placed = false
        var returning = false
    }

    private static let field = CGRect(x: 70, y: 130, width: 940, height: 820)
    private static let tokenRadius: CGFloat = 48

    private let records: RecordStore
    private var rng: SplitMix64
    private(set) var phase = Phase.ready
    private(set) var zones: [Zone]
    private(set) var tokens: [Token] = []
    private(set) var errors = 0
    private var grabbed: Int?
    private var grabOffset = CGPoint.zero
    private var startedAt: TimeInterval = 0
    private var finishedAt: TimeInterval = 0
    private(set) var elapsed = 0.0
    private var newBest = false
    private var wrongZone: Int?
    private var wrongAt: TimeInterval = -10

    init(records: RecordStore, seed: UInt64) {
        self.records = records
        rng = SplitMix64(seed: seed)
        let specs: [(Shape, Tone, String)] = [(.circle, .accent, "Circles"), (.square, .secondary, "Squares"), (.triangle, .success, "Triangles")]
        zones = specs.enumerated().map { index, spec in
            Zone(shape: spec.0, tone: spec.1, title: spec.2,
                 rect: CGRect(x: 1070, y: 130 + CGFloat(index) * 280, width: 460, height: 258))
        }
        super.init(mode: .drag)
        layoutTokens()
    }

    override var isAnimating: Bool { phase == .running || tokens.contains { $0.returning } || lastNow - wrongAt < 0.5 }
    private var lastNow: TimeInterval = 0

    var placedCount: Int { tokens.filter(\.placed).count }

    private func layoutTokens() {
        tokens = []
        let area = Self.field.insetBy(dx: 90, dy: 90)
        for zone in zones.indices {
            for _ in 0..<2 {
                var spot = CGPoint(x: area.midX, y: area.midY)
                for _ in 0..<80 {
                    let candidate = CGPoint(x: CGFloat.random(in: area.minX...area.maxX, using: &rng),
                                            y: CGFloat.random(in: area.minY...area.maxY, using: &rng))
                    if tokens.allSatisfy({ $0.home.distance(to: candidate) > 190 }) { spot = candidate; break }
                }
                tokens.append(Token(zone: zone, position: spot, home: spot))
            }
        }
        tokens.shuffle(using: &rng)
    }

    private func reset() {
        phase = .ready
        errors = 0
        elapsed = 0
        grabbed = nil
        newBest = false
        layoutTokens()
        needsRedraw = true
    }

    // MARK: Play

    override func handle(_ input: SandboxInput, _ context: ActivityContext) {
        switch input {
        case .button(.left, isDown: true, clickCount: _, at: let point):
            needsRedraw = true
            if phase == .finished {
                if context.now - finishedAt > 1.2 { reset() }
                return
            }
            // Topmost token under the pointer, with a little forgiveness around its edge.
            guard let index = tokens.indices.last(where: {
                !tokens[$0].placed && tokens[$0].position.distance(to: point) <= Self.tokenRadius + 12
            }) else {
                emit(.ripple(point, .neutral))
                return
            }
            if phase == .ready {
                phase = .running
                startedAt = context.now
            }
            grabbed = index
            grabOffset = tokens[index].position - point
            tokens[index].returning = false
            emit(.ripple(point, zones[tokens[index].zone].tone))
        case .button(.left, isDown: false, clickCount: _, at: _):
            guard let index = grabbed else { return }
            grabbed = nil
            needsRedraw = true
            drop(index, context)
        default:
            break
        }
    }

    private func drop(_ index: Int, _ context: ActivityContext) {
        let position = tokens[index].position
        guard let zone = zones.firstIndex(where: { $0.rect.contains(position) }) else { return }
        if zone == tokens[index].zone {
            let slot = tokens.filter { $0.placed && $0.zone == zone }.count
            tokens[index].placed = true
            tokens[index].position = zones[zone].slot(slot)
            emit(.burst(tokens[index].position, zones[zone].tone))
            emit(.haptic(.success))
            if tokens.allSatisfy(\.placed) { finish(context) }
        } else {
            errors += 1
            wrongZone = zone
            wrongAt = context.now
            tokens[index].returning = true
            emit(.ripple(position, .danger))
            emit(.haptic(.failure))
        }
    }

    private func finish(_ context: ActivityContext) {
        phase = .finished
        finishedAt = context.now
        elapsed = context.now - startedAt
        let line = String(format: "%.1f s · %d wrong drop%@", elapsed, errors, errors == 1 ? "" : "s")
        newBest = records.add(DrillRecord(date: Date(), score: elapsed, summary: line), for: .drag)
        emit(.celebrate)
    }

    override func update(_ context: ActivityContext) {
        lastNow = context.now
        if phase == .running { elapsed = context.now - startedAt }
        if let index = grabbed {
            let wanted = context.cursor + grabOffset
            tokens[index].position = CGPoint(x: wanted.x.clamped(Self.tokenRadius, 1600 - Self.tokenRadius),
                                             y: wanted.y.clamped(110 + Self.tokenRadius, 1000 - Self.tokenRadius))
            needsRedraw = true
        }
        for index in tokens.indices where tokens[index].returning {
            let home = tokens[index].home, position = tokens[index].position
            let next = CGPoint(x: position.x + (home.x - position.x) * 0.2, y: position.y + (home.y - position.y) * 0.2)
            tokens[index].position = next
            if next.distance(to: home) < 2 {
                tokens[index].position = home
                tokens[index].returning = false
            }
            needsRedraw = true
        }
    }

    override func perform(_ command: ActivityCommand, _ context: ActivityContext) {
        if command == .restart { reset() }
    }

    // MARK: Reporting

    override func status(_ context: ActivityContext) -> ActivityStatus {
        var status = ActivityStatus()
        if let best = records.best(for: .drag) { status.best = "Best " + DojoMode.drag.formatScore(best.score) }
        switch phase {
        case .ready:
            status.headline = "Grab a token to start"
            status.detail = "Point at a token, flick your wrist in to grab it, carry it to the zone with its shape, flick in again to drop."
        case .running:
            status.phase = .running
            status.headline = grabbed == nil ? "Grab the next token" : "Carry it to its zone"
            status.progress = Double(placedCount) / Double(tokens.count)
            status.metrics = [
                StatusMetric(label: "Time", value: String(format: "%.1f s", elapsed), tone: .accent),
                StatusMetric(label: "Placed", value: "\(placedCount) / \(tokens.count)", tone: .success),
                StatusMetric(label: "Wrong drops", value: "\(errors)", tone: errors > 0 ? .danger : .neutral),
            ]
            status.actions = [ActivityAction(command: .restart, title: "Restart", symbol: "arrow.counterclockwise")]
        case .finished:
            status.phase = .finished
            status.headline = newBest ? "New personal best!" : "All sorted"
            status.newBest = newBest
            status.metrics = [
                StatusMetric(label: "Time", value: String(format: "%.1f s", elapsed), tone: .accent),
                StatusMetric(label: "Wrong drops", value: "\(errors)", tone: errors > 0 ? .danger : .neutral),
            ]
            status.actions = [ActivityAction(command: .restart, title: "Play again", symbol: "arrow.counterclockwise", prominent: true)]
        }
        status.virtualTip = "F or ⌥-click grabs and drops"
        return status
    }

    override func autopilotHint(_ context: ActivityContext) -> AutopilotHint {
        if phase == .finished {
            return context.now - finishedAt > 3 ? .click(at: Self.field.center, .left) : .idle
        }
        if let index = grabbed {
            let zone = tokens[index].zone
            let slot = tokens.filter { $0.placed && $0.zone == zone }.count
            return .carry(to: zones[zone].slot(slot) - grabOffset)
        }
        if context.snapshot.dragging { return .release }
        guard let next = tokens.first(where: { !$0.placed && !$0.returning }) else { return .idle }
        return .grab(at: next.position)
    }

    // MARK: Drawing

    override func draw(_ p: Painter, _ context: ActivityContext) {
        p.header("Drag & Drop", subtitle: "Flick in to grab, carry, flick in again to drop",
                 trailing: phase == .ready ? "" : String(format: "%.1f s", elapsed))

        for (index, zone) in zones.enumerated() {
            let tone = zone.tone.ns
            let carrying = grabbed.map { tokens[$0].zone == index } ?? false
            let hovering = carrying && grabbed.map { zone.rect.contains(tokens[$0].position) } == true
            let wrong = wrongZone == index ? CGFloat(max(0, 1 - (context.now - wrongAt) / 0.5)) : 0
            if hovering { p.glow(zone.rect.center, radius: 380, color: tone, alpha: 0.3) }
            p.roundRect(zone.rect, radius: 30, fill: tone.alpha(hovering ? 0.22 : 0.08).mixed(with: Palette.danger, wrong * 0.6),
                        stroke: wrong > 0 ? Palette.danger : tone.alpha(carrying ? 1 : 0.6),
                        lineWidth: carrying ? 5 : 3, dash: carrying ? [] : [16, 10])
            drawShape(p, zone.shape, center: CGPoint(x: zone.rect.minX + 44, y: zone.rect.minY + 42), size: 15, color: tone, filled: true)
            p.text(zone.title.uppercased(), in: CGRect(x: zone.rect.minX + 72, y: zone.rect.minY + 24, width: 300, height: 36),
                   size: 22, weight: .bold, color: tone, tracking: 2.4)
            for slot in 0..<2 {
                p.circle(zone.slot(slot), Self.tokenRadius + 6, stroke: tone.alpha(0.25), lineWidth: 2, dash: [5, 7])
            }
        }

        // Held token last, so it floats above the rest.
        let order = tokens.indices.sorted { ($0 == grabbed ? 1 : 0) < ($1 == grabbed ? 1 : 0) }
        for index in order {
            let token = tokens[index]
            let tone = zones[token.zone].tone.ns
            let held = index == grabbed
            let radius = Self.tokenRadius * (held ? 1.12 : 1)
            p.glow(token.position, radius: radius * (held ? 2.6 : 1.9), color: tone, alpha: held ? 0.5 : 0.22)
            p.circle(token.position, radius, fill: Palette.panel.mixed(with: tone, token.placed ? 0.35 : 0.16),
                     stroke: tone, lineWidth: held ? 6 : 4)
            drawShape(p, zones[token.zone].shape, center: token.position, size: radius * 0.42,
                      color: token.placed ? .white : tone, filled: true)
        }

        if phase == .ready {
            p.text("Flick your wrist IN over a token to grab it", in: CGRect(x: 70, y: 900, width: 940, height: 44),
                   size: 26, weight: .medium, color: Palette.textSecondary, align: .center)
        }
        if phase == .finished { drawResults(p) }
    }

    private func drawShape(_ p: Painter, _ shape: Shape, center: CGPoint, size: CGFloat, color: NSColor, filled: Bool) {
        switch shape {
        case .circle:
            p.circle(center, size, fill: color)
        case .square:
            p.roundRect(CGRect(x: center.x - size, y: center.y - size, width: size * 2, height: size * 2), radius: size * 0.25, fill: color)
        case .triangle:
            p.polygon([CGPoint(x: center.x, y: center.y - size * 1.1), CGPoint(x: center.x + size * 1.1, y: center.y + size * 0.85),
                       CGPoint(x: center.x - size * 1.1, y: center.y + size * 0.85)], fill: color)
        }
    }

    private func drawResults(_ p: Painter) {
        let card = CGRect(x: 150, y: 300, width: 780, height: 400)
        p.card(card, radius: 40, tint: Palette.accent.alpha(0.6))
        p.text("SORTED IN", in: CGRect(x: card.minX, y: card.minY + 40, width: card.width, height: 34), size: 24, weight: .bold,
               color: Palette.accent, align: .center, tracking: 3)
        p.text(String(format: "%.1f s", elapsed), in: CGRect(x: card.minX, y: card.minY + 80, width: card.width, height: 140),
               size: 120, weight: .heavy, align: .center, face: .mono)
        p.text(errors == 0 ? "No wrong drops" : "\(errors) wrong drop\(errors == 1 ? "" : "s")",
               in: CGRect(x: card.minX, y: card.minY + 232, width: card.width, height: 40), size: 30, weight: .semibold,
               color: errors == 0 ? Palette.success : Palette.warning, align: .center)
        p.text(newBest ? "New personal best!" : "Tap anywhere to play again",
               in: CGRect(x: card.minX, y: card.maxY - 88, width: card.width, height: 44), size: 28, weight: .bold,
               color: newBest ? Palette.success : Palette.textSecondary, align: .center)
    }
}
