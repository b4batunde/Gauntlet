import Foundation
import CoreGraphics
import GauntletEngine
import GauntletProtocol

/// Feeds the engine from the built-in `VirtualWatch` when no real watch is connected.
///
/// A background timer produces one packet (2 samples x 10 ms) every 20 ms, exactly like the
/// real stream. The mouse — or the autopilot — only moves the arm's targets; the simulation
/// produces the gyro/accelerometer data and the engine does the rest.
final class VirtualWatchDriver: @unchecked Sendable {
    static let packetInterval = 0.02

    private let engine: WristEngine
    private let cursor: () -> CGPoint
    private let queue = DispatchQueue(label: "dojo.virtual-watch", qos: .userInteractive)
    private let lock = NSLock()

    // Everything below is guarded by `lock`.
    private let watch = VirtualWatch(seed: 0xD0D0_CAFE)
    private var controls = VirtualControls()
    private var autopilot = Autopilot()
    private var hint: AutopilotHint?
    private var crownPixelsPerUnit = 900.0
    private var timer: DispatchSourceTimer?
    private var startWall = 0.0
    private var sent = 0
    private var lastStatus = 0.0

    init(engine: WristEngine, cursor: @escaping () -> CGPoint) {
        self.engine = engine
        self.cursor = cursor
        watch.snap(heading: 0, elevation: VirtualControls.neutralElevation)
    }

    deinit { timer?.cancel() }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return timer != nil
    }

    var posture: VirtualPosture {
        lock.lock(); defer { lock.unlock() }
        return controls.posture
    }

    func start() {
        lock.lock()
        guard timer == nil else { lock.unlock(); return }
        startWall = WristEngine.now()
        sent = 0
        lastStatus = 0
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: Self.packetInterval, leeway: .milliseconds(1))
        source.setEventHandler { [weak self] in self?.tick() }
        timer = source
        lock.unlock()
        source.resume()
    }

    /// - Parameter sayGoodbye: tell the engine the stream is over. Skip it when a real watch is
    ///   taking over, so its stream is not interrupted.
    func stop(sayGoodbye: Bool) {
        lock.lock()
        let source = timer
        timer = nil
        lock.unlock()
        guard let source else { return }
        source.cancel()
        if sayGoodbye { engine.ingest(.bye) }
    }

    // MARK: Puppeteering (any thread)

    /// Mouse position over the 3D view, 0...1 on both axes (v grows upward).
    func steer(u: Double, v: Double) {
        mutate { c in
            c.heading = (0.5 - u.clamped(0, 1)) * VirtualControls.headingSpan
            let range = VirtualControls.elevationRange
            c.elevation = range.lowerBound + v.clamped(0, 1) * (range.upperBound - range.lowerBound)
        }
    }

    func tap() { mutate { $0.tap = true } }
    func flick(outward: Bool) { mutate { $0.flicks.append(outward) } }
    func crown(delta: Double) { mutate { $0.crown += delta } }
    func action(_ code: WatchActionCode) { mutate { $0.actions.append(code) } }

    /// Toggles between pointing and the given posture.
    func toggle(_ posture: VirtualPosture) {
        mutate { $0.posture = ($0.posture == posture) ? .pointing : posture }
    }

    func setRightWrist(_ right: Bool) {
        lock.lock()
        watch.rightWrist = right
        watch.crownLeft = right            // keep the crown on the hand side, as most people wear it
        lock.unlock()
    }

    /// Pass a hint to let the autopilot play; nil gives control back to the mouse.
    func setAutopilot(_ hint: AutopilotHint?, crownPixelsPerUnit: Double) {
        lock.lock()
        if self.hint == nil, hint != nil { autopilot = Autopilot() }
        self.hint = hint
        self.crownPixelsPerUnit = crownPixelsPerUnit
        lock.unlock()
    }

    private func mutate(_ body: (inout VirtualControls) -> Void) {
        lock.lock()
        if hint == nil { body(&controls) }      // the autopilot owns the arm while it plays
        lock.unlock()
    }

    // MARK: Simulation

    private func tick() {
        let now = WristEngine.now()
        let pose = engine.snapshot()
        let pointer = cursor()
        var messages: [WatchMessage] = []

        lock.lock()
        guard timer != nil else { lock.unlock(); return }
        var due = Int(((now - startWall) / Self.packetInterval).rounded(.down)) - sent + 1
        if due > 5 {                            // slept or stalled: resume, do not replay the gap
            startWall = now
            sent = 0
            due = 1
        }
        for _ in 0..<max(0, due) {
            if let hint {
                let context = Autopilot.Context(cursor: pointer, engaged: pose.engaged, dragging: pose.dragging,
                                                crownPixelsPerUnit: crownPixelsPerUnit)
                autopilot.step(dt: Self.packetInterval, hint: hint, context: context, controls: &controls)
            }
            let discrete = controls.apply(to: watch)
            messages.append(watch.nextPacket())
            messages.append(contentsOf: discrete)
            sent += 1
        }
        if now - lastStatus >= 1 {
            lastStatus = now
            messages.append(watch.status())
        }
        lock.unlock()

        for message in messages { engine.ingest(message, now: now) }
    }
}
