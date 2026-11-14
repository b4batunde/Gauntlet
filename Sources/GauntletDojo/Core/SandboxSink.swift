import Foundation
import CoreGraphics
import GauntletEngine

/// Something the engine did to the virtual screen, stamped with where the cursor was.
enum SandboxInput: Equatable {
    case button(MouseButton, isDown: Bool, clickCount: Int, at: CGPoint)
    case scroll(dx: Double, dy: Double, at: CGPoint)
    case shortcut
}

struct ScreenEdges: OptionSet, Equatable {
    let rawValue: Int
    static let left = ScreenEdges(rawValue: 1)
    static let right = ScreenEdges(rawValue: 2)
    static let top = ScreenEdges(rawValue: 4)
    static let bottom = ScreenEdges(rawValue: 8)
}

/// The Dojo's stand-in for the macOS cursor: a pointer confined to the virtual screen.
///
/// The engine calls in from whichever thread feeds it; the render thread reads `cursor`
/// every frame; the main thread drains the queued input. Everything sits behind one lock.
final class SandboxSink: PointerSink, @unchecked Sendable {
    struct Drained {
        var cursor: CGPoint
        var inputs: [SandboxInput]
        /// Edge bumps since the last drain (already rate-limited).
        var edgeBumps: Int
        var pinned: ScreenEdges
    }

    let screenSize: CGSize

    private let lock = NSLock()
    private let clock: () -> TimeInterval
    private var position: CGPoint
    private var odometer = SIMD2<Double>.zero
    private var inputs: [SandboxInput] = []
    private var pinned: ScreenEdges = []
    private var overflow = 0.0
    private var lastBump: TimeInterval = -10
    private var bumps = 0

    /// Push this far past an edge before it counts as "pinned", and at most one bump per interval.
    private static let bumpOverflow = 24.0
    private static let bumpInterval = 0.6

    init(screenSize: CGSize, clock: @escaping () -> TimeInterval = { WristEngine.now() }) {
        self.screenSize = screenSize
        self.clock = clock
        position = CGPoint(x: screenSize.width / 2, y: screenSize.height / 2)
    }

    var cursor: CGPoint {
        lock.lock(); defer { lock.unlock() }
        return position
    }

    /// Edges the pointer is currently pressed against.
    var pinnedEdges: ScreenEdges {
        lock.lock(); defer { lock.unlock() }
        return pinned
    }

    /// Total pointer travel the engine has asked for, ignoring the screen bounds.
    var travel: SIMD2<Double> {
        lock.lock(); defer { lock.unlock() }
        return odometer
    }

    func warp(to point: CGPoint) {
        lock.lock()
        position = CGPoint(x: point.x.clamped(0, screenSize.width - 1), y: point.y.clamped(0, screenSize.height - 1))
        pinned = []
        overflow = 0
        lock.unlock()
    }

    func drain() -> Drained {
        lock.lock(); defer { lock.unlock() }
        let result = Drained(cursor: position, inputs: inputs, edgeBumps: bumps, pinned: pinned)
        inputs.removeAll(keepingCapacity: true)
        bumps = 0
        return result
    }

    // MARK: PointerSink

    func movePointer(dx: Double, dy: Double) {
        let now = clock()
        lock.lock(); defer { lock.unlock() }
        odometer += SIMD2(dx, dy)
        let maxX = Double(screenSize.width) - 1, maxY = Double(screenSize.height) - 1
        var x = Double(position.x) + dx, y = Double(position.y) + dy
        var edges: ScreenEdges = []
        var excess = 0.0
        if x < 0 { excess += -x; x = 0; edges.insert(.left) }
        if x > maxX { excess += x - maxX; x = maxX; edges.insert(.right) }
        if y < 0 { excess += -y; y = 0; edges.insert(.top) }
        if y > maxY { excess += y - maxY; y = maxY; edges.insert(.bottom) }
        position = CGPoint(x: x, y: y)
        pinned = edges
        if edges.isEmpty {
            overflow = 0
        } else {
            overflow += excess
            if overflow > Self.bumpOverflow, now - lastBump > Self.bumpInterval {
                lastBump = now
                overflow = 0
                bumps += 1
            }
        }
    }

    func button(_ button: MouseButton, isDown: Bool, clickCount: Int) {
        lock.lock(); defer { lock.unlock() }
        inputs.append(.button(button, isDown: isDown, clickCount: clickCount, at: position))
    }

    func scroll(dx: Double, dy: Double) {
        lock.lock(); defer { lock.unlock() }
        inputs.append(.scroll(dx: dx, dy: dy, at: position))
    }

    func shortcut(_ shortcut: SystemShortcut) {
        lock.lock(); defer { lock.unlock() }
        inputs.append(.shortcut)
    }
}

/// Engine events cross from the feeding thread to the main thread through this queue.
final class EventInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [EngineEvent] = []

    func push(_ event: EngineEvent) {
        if case .haptic = event { return }      // the host plays engine haptics itself
        lock.lock()
        if events.count < 4096 { events.append(event) }
        lock.unlock()
    }

    func drain() -> [EngineEvent] {
        lock.lock(); defer { lock.unlock() }
        let out = events
        events.removeAll(keepingCapacity: true)
        return out
    }
}
