import AppKit
import GauntletEngine

/// The sandbox desktop: three buttons that each want a different kind of click,
/// a puck to drag into a dock, and a list to scroll. No score, no pressure.
final class FreePlayActivity: Activity {
    private struct Tile {
        let kind: ClickKind
        let title: String
        let gesture: String
        let symbol: String
        let tone: Tone
        var rect: CGRect
        var count = 0
        var flashAt: TimeInterval = -10
        var mismatch = ""
        var mismatchAt: TimeInterval = -10
    }

    private enum Layout {
        static let buttons = CGRect(x: 48, y: 122, width: 900, height: 330)
        static let drag = CGRect(x: 48, y: 476, width: 900, height: 476)
        static let scroll = CGRect(x: 972, y: 122, width: 580, height: 830)
        static let list = CGRect(x: 996, y: 196, width: 532, height: 732)
        static let rowHeight: CGFloat = 64
        static let puckRadius: CGFloat = 46
        static let dockRadius: CGFloat = 66
    }

    private static let rowNames = ["Aurora", "Basalt", "Cinder", "Drift", "Ember", "Flux", "Glacier", "Halo", "Ion",
                                   "Jade", "Kelvin", "Lumen", "Mirage", "Nova", "Onyx", "Pulse", "Quartz", "Rift",
                                   "Solstice", "Tundra", "Umbra", "Vertex", "Willow", "Xenon", "Yonder", "Zenith"]
    private static let rowCount = 52

    private var tiles: [Tile]
    private var hovered: Int?
    private var puck = CGPoint(x: 230, y: 720)
    private var dock = CGPoint(x: 720, y: 720)
    private var grabOffset: CGPoint?
    private var docked = 0
    private var dockedAt: TimeInterval = -10
    private var listOffset: CGFloat = 0
    private var scrolled = 0.0
    private var lastInput = "Nothing yet — raise your arm and try a gesture"
    private var rng: SplitMix64

    // Autopilot tour.
    private var tourStage = 0
    private var tourMark = 0.0

    init(seed: UInt64) {
        rng = SplitMix64(seed: seed)
        let specs: [(ClickKind, String, String, String, Tone)] = [
            (.left, "Click", "Finger tap", "cursorarrow.click", .accent),
            (.right, "Right-click", "Flick wrist out", "contextualmenu.and.cursorarrow", .secondary),
            (.double, "Double-click", "Tap twice", "cursorarrow.click.2", .success),
        ]
        let width: CGFloat = 264, gap: CGFloat = 24
        tiles = specs.enumerated().map { index, spec in
            Tile(kind: spec.0, title: spec.1, gesture: spec.2, symbol: spec.3, tone: spec.4,
                 rect: CGRect(x: Layout.buttons.minX + 30 + CGFloat(index) * (width + gap),
                              y: Layout.buttons.minY + 84, width: width, height: 216))
        }
        super.init(mode: .freePlay)
    }

    private var maxOffset: CGFloat { CGFloat(Self.rowCount) * Layout.rowHeight - Layout.list.height }

    override var isAnimating: Bool { animatingUntil > lastNow || grabOffset != nil }
    private var animatingUntil: TimeInterval = 0
    private var lastNow: TimeInterval = 0

    // MARK: Input

    override func handle(_ input: SandboxInput, _ context: ActivityContext) {
        needsRedraw = true
        switch input {
        case .button(.left, isDown: true, clickCount: let clicks, at: let point):
            if point.distance(to: puck) <= Layout.puckRadius + 10 {
                grabOffset = puck - point
                lastInput = "Grabbed the puck"
                emit(.ripple(point, .secondary))
            } else {
                click(clicks >= 2 ? .double : .left, at: point, context)
            }
        case .button(.left, isDown: false, clickCount: _, at: let point):
            guard grabOffset != nil else { return }
            grabOffset = nil
            if puck.distance(to: dock) < Layout.dockRadius - 14 {
                docked += 1
                dockedAt = context.now
                puck = dock
                moveDock()
                lastInput = "Docked!"
                emit(.burst(puck, .success))
                emit(.haptic(.success))
                animatingUntil = context.now + 1
            } else {
                lastInput = "Dropped the puck"
                emit(.ripple(point, .neutral))
            }
        case .button(.right, isDown: true, clickCount: _, at: let point):
            click(.right, at: point, context)
        case .scroll(dx: _, dy: let dy, at: _):
            let before = listOffset
            listOffset = (listOffset - CGFloat(dy)).clamped(0, maxOffset)
            scrolled += Double(abs(listOffset - before))
            lastInput = dy < 0 ? "Scrolling down" : "Scrolling up"
        default:
            break
        }
    }

    private func click(_ kind: ClickKind, at point: CGPoint, _ context: ActivityContext) {
        let name: String
        switch kind {
        case .left: name = "Click"
        case .right: name = "Right-click"
        case .double: name = "Double-click"
        }
        lastInput = "\(name) at \(Int(point.x)), \(Int(point.y))"
        animatingUntil = context.now + 1.5
        guard let index = tiles.firstIndex(where: { $0.rect.contains(point) }) else {
            emit(.ripple(point, .neutral))
            return
        }
        if tiles[index].kind == kind || (tiles[index].kind == .left && kind == .double) {
            tiles[index].count += 1
            tiles[index].flashAt = context.now
            emit(.burst(point, tiles[index].tone))
        } else if !(kind == .left && tiles[index].kind == .double) {
            // The first half of a double-click is a plain click; do not nag about it.
            tiles[index].mismatch = "That was a \(name.lowercased())"
            tiles[index].mismatchAt = context.now
            emit(.ripple(point, .warning))
        } else {
            emit(.ripple(point, .neutral))
        }
    }

    private func moveDock() {
        let area = Layout.drag.insetBy(dx: 110, dy: 110).offsetBy(dx: 0, dy: 24)
        for _ in 0..<24 {
            let candidate = CGPoint(x: CGFloat.random(in: area.minX...area.maxX, using: &rng),
                                    y: CGFloat.random(in: area.minY...area.maxY, using: &rng))
            if candidate.distance(to: puck) > 300 { dock = candidate; return }
        }
        dock = CGPoint(x: puck.x < Layout.drag.midX ? area.maxX : area.minX, y: area.midY)
    }

    override func update(_ context: ActivityContext) {
        lastNow = context.now
        if let offset = grabOffset {
            let area = Layout.drag.insetBy(dx: Layout.puckRadius + 8, dy: Layout.puckRadius + 8)
            let wanted = context.cursor + offset
            puck = CGPoint(x: wanted.x.clamped(area.minX, area.maxX), y: wanted.y.clamped(area.minY, area.maxY))
        }
        let hover = tiles.firstIndex { $0.rect.contains(context.cursor) }
        if hover != hovered { hovered = hover; needsRedraw = true }
        advanceTour(context)
    }

    override func perform(_ command: ActivityCommand, _ context: ActivityContext) {
        guard command == .restart else { return }
        for index in tiles.indices { tiles[index].count = 0 }
        docked = 0
        scrolled = 0
        listOffset = 0
        lastInput = "Counters reset"
        needsRedraw = true
    }

    override func status(_ context: ActivityContext) -> ActivityStatus {
        var status = ActivityStatus()
        status.headline = "Sandbox desktop"
        status.detail = "Tap to click, flick out to right-click, flick in to grab and drop, turn the crown to scroll."
        status.metrics = [
            StatusMetric(label: "Clicks", value: "\(tiles[0].count)", tone: .accent),
            StatusMetric(label: "Right-clicks", value: "\(tiles[1].count)", tone: .secondary),
            StatusMetric(label: "Double-clicks", value: "\(tiles[2].count)", tone: .success),
            StatusMetric(label: "Docked", value: "\(docked)"),
            StatusMetric(label: "Scrolled", value: "\(Int(scrolled)) px"),
        ]
        status.actions = [ActivityAction(command: .restart, title: "Reset counters", symbol: "arrow.counterclockwise")]
        return status
    }

    // MARK: Autopilot tour

    private func advanceTour(_ context: ActivityContext) {
        switch tourStage {
        case 0...2:
            if Double(tiles[tourStage].count) > tourMark { enterTour(tourStage + 1) }
        case 3:
            if grabOffset != nil { enterTour(4) }
        case 4:
            if Double(docked) > tourMark { enterTour(5) } else if grabOffset == nil { tourStage = 3 }
        case 5:
            if scrolled - tourMark > 640 { enterTour(6) }
        default:
            if scrolled - tourMark > 640 || listOffset <= 0 { enterTour(0) }
        }
    }

    private func enterTour(_ stage: Int) {
        tourStage = stage
        switch stage {
        case 0...2: tourMark = Double(tiles[stage].count)
        case 3, 4: tourMark = Double(docked)
        default: tourMark = scrolled
        }
    }

    override func autopilotHint(_ context: ActivityContext) -> AutopilotHint {
        switch tourStage {
        case 0...2: return .click(at: tiles[tourStage].rect.center, tiles[tourStage].kind)
        case 3: return context.snapshot.dragging ? .release : .grab(at: puck)
        case 4: return .carry(to: dock)
        case 5: return .scroll(dy: -(640 - (scrolled - tourMark)))
        default: return .scroll(dy: 640 - (scrolled - tourMark))
        }
    }

    // MARK: Drawing

    override func draw(_ p: Painter, _ context: ActivityContext) {
        p.header("Free Play", subtitle: "Sandbox desktop — nothing here touches your Mac", trailing: "")
        p.text(lastInput, in: CGRect(x: 760, y: 26, width: 792, height: 40), size: 22, weight: .medium,
               color: Palette.textSecondary, align: .right)

        drawButtons(p, context)
        drawDragLab(p, context)
        drawList(p)
    }

    private func drawButtons(_ p: Painter, _ context: ActivityContext) {
        p.card(Layout.buttons)
        p.caption("Buttons — each one wants a different click", at: CGPoint(x: Layout.buttons.minX + 30, y: Layout.buttons.minY + 26))
        for (index, tile) in tiles.enumerated() {
            let tone = tile.tone.ns
            let flash = CGFloat(max(0, 1 - (context.now - tile.flashAt) / 0.6))
            if flash > 0 { p.glow(tile.rect.center, radius: 230, color: tone, alpha: 0.5 * flash) }
            p.roundRect(tile.rect, radius: 28, fill: Palette.panel.mixed(with: tone, 0.10 + 0.55 * flash),
                        stroke: tone.alpha(hovered == index ? 1 : 0.55), lineWidth: hovered == index ? 5 : 2.5)
            p.symbol(tile.symbol, center: CGPoint(x: tile.rect.midX, y: tile.rect.minY + 66), pointSize: 52,
                     color: flash > 0.3 ? .white : tone)
            p.text(tile.title, in: CGRect(x: tile.rect.minX, y: tile.rect.minY + 108, width: tile.rect.width, height: 40),
                   size: 30, weight: .bold, align: .center)
            let nagging = context.now - tile.mismatchAt < 1.4
            p.text(nagging ? tile.mismatch : tile.gesture,
                   in: CGRect(x: tile.rect.minX, y: tile.rect.minY + 150, width: tile.rect.width, height: 30),
                   size: 21, weight: .medium, color: nagging ? Palette.warning : Palette.textSecondary, align: .center)
            p.text("×\(tile.count)", in: CGRect(x: tile.rect.maxX - 110, y: tile.rect.minY + 12, width: 92, height: 34),
                   size: 24, weight: .bold, color: tile.count > 0 ? tone : Palette.textSecondary, align: .right, face: .mono)
        }
    }

    private func drawDragLab(_ p: Painter, _ context: ActivityContext) {
        p.card(Layout.drag)
        p.caption("Drag — flick in to grab, flick in again to drop", at: CGPoint(x: Layout.drag.minX + 30, y: Layout.drag.minY + 26))
        p.text("Docked ×\(docked)", in: CGRect(x: Layout.drag.maxX - 290, y: Layout.drag.minY + 20, width: 260, height: 36),
               size: 24, weight: .bold, color: docked > 0 ? Palette.success : Palette.textSecondary, align: .right, face: .mono)

        let pulse = CGFloat(max(0, 1 - (context.now - dockedAt) / 0.8))
        p.glow(dock, radius: 150, color: Palette.success, alpha: 0.10 + 0.3 * pulse)
        p.circle(dock, Layout.dockRadius, fill: Palette.success.alpha(0.07), stroke: Palette.success.alpha(0.85),
                 lineWidth: 4, dash: [14, 10])
        p.text("DOCK", in: CGRect(x: dock.x - 80, y: dock.y - 16, width: 160, height: 32), size: 19, weight: .bold,
               color: Palette.success.alpha(0.8), align: .center, tracking: 3)

        let held = grabOffset != nil
        p.glow(puck, radius: held ? 130 : 90, color: Palette.secondary, alpha: held ? 0.55 : 0.28)
        p.circle(puck, Layout.puckRadius, fill: Palette.secondary.mixed(with: .white, held ? 0.25 : 0),
                 stroke: NSColor.white.alpha(held ? 0.95 : 0.4), lineWidth: held ? 5 : 3)
        p.symbol(held ? "hand.draw.fill" : "hand.draw", center: puck, pointSize: 36, color: .white)
    }

    private func drawList(_ p: Painter) {
        p.card(Layout.scroll)
        p.caption("Scroll — Digital Crown or air-scroll", at: CGPoint(x: Layout.scroll.minX + 30, y: Layout.scroll.minY + 26))
        let list = Layout.list
        p.clipped(to: list, radius: 16) {
            let first = max(0, Int(listOffset / Layout.rowHeight))
            let last = min(Self.rowCount - 1, first + Int(list.height / Layout.rowHeight) + 1)
            guard first <= last else { return }
            for row in first...last {
                let y = list.minY + CGFloat(row) * Layout.rowHeight - listOffset
                let rect = CGRect(x: list.minX, y: y + 4, width: list.width - 22, height: Layout.rowHeight - 8)
                p.roundRect(rect, radius: 14, fill: NSColor.white.alpha(row % 2 == 0 ? 0.07 : 0.035))
                let tones: [Tone] = [.accent, .secondary, .success, .warning]
                p.circle(CGPoint(x: rect.minX + 30, y: rect.midY), 8, fill: tones[row % tones.count].ns)
                p.text(String(format: "%02d", row + 1), in: CGRect(x: rect.minX + 54, y: rect.minY, width: 56, height: rect.height),
                       size: 22, weight: .semibold, color: Palette.textSecondary, face: .mono)
                p.text(Self.rowNames[row % Self.rowNames.count], in: CGRect(x: rect.minX + 116, y: rect.minY, width: 340, height: rect.height),
                       size: 25, weight: .semibold)
            }
        }
        // Scroll bar.
        let track = CGRect(x: list.maxX - 10, y: list.minY, width: 8, height: list.height)
        p.roundRect(track, radius: 4, fill: NSColor.white.alpha(0.07))
        let visible = list.height / (CGFloat(Self.rowCount) * Layout.rowHeight)
        let thumbHeight = max(40, track.height * visible)
        let travel = track.height - thumbHeight
        let thumbY = track.minY + (maxOffset > 0 ? travel * listOffset / maxOffset : 0)
        p.roundRect(CGRect(x: track.minX, y: thumbY, width: 8, height: thumbHeight), radius: 4, fill: Palette.accent.alpha(0.85))
    }
}

/// Shown on the virtual screen while the watch is steering the real pointer.
final class LiveActivity: Activity {
    private let isRealWatchConnected: () -> Bool
    private var connected = false

    init(isRealWatchConnected: @escaping () -> Bool) {
        self.isRealWatchConnected = isRealWatchConnected
        super.init(mode: .live)
    }

    override func update(_ context: ActivityContext) {
        let now = isRealWatchConnected()
        if now != connected { connected = now; needsRedraw = true }
    }

    override func status(_ context: ActivityContext) -> ActivityStatus {
        var status = ActivityStatus()
        status.phase = connected ? .running : .ready
        status.headline = connected ? "Controlling your Mac" : "No watch connected"
        status.detail = connected
            ? "Pointer output goes to the real cursor. The arm here mirrors your wrist so you can watch your form."
            : "Live mode needs your Apple Watch. The virtual watch stays in the sandbox so it can never fight your mouse."
        return status
    }

    override func draw(_ p: Painter, _ context: ActivityContext) {
        let tone: Tone = connected ? .success : .warning
        p.header("Live", subtitle: "The sandbox is off", tone: tone)
        let center = CGPoint(x: p.size.width / 2, y: 430)
        p.glow(center, radius: 420, color: tone.ns, alpha: 0.18)
        p.symbol(connected ? "cursorarrow.rays" : "applewatch.slash", center: center, pointSize: 150, color: tone.ns)
        p.text(connected ? "Your wrist is moving the real pointer" : "Connect your watch to go live",
               in: CGRect(x: 100, y: 580, width: p.size.width - 200, height: 70), size: 52, weight: .bold, align: .center)
        p.text(connected ? "Switch to any other mode to return to the sandbox." : "Every other mode works right now with the virtual watch.",
               in: CGRect(x: 100, y: 660, width: p.size.width - 200, height: 44), size: 28, weight: .medium,
               color: Palette.textSecondary, align: .center)
    }
}
