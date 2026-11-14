import Foundation
import CoreGraphics
import GauntletEngine
import GauntletProtocol

/// The Dojo without any pixels: the sandbox sink, the current activity and the plumbing between
/// the engine and both. Main-thread only; `pump` is its heartbeat (the UI calls it every frame,
/// the self-check calls it after every simulated packet).
final class DojoSession {
    static let screenSize = CGSize(width: 1600, height: 1000)

    let host: DojoHost
    let engine: WristEngine
    let sink: SandboxSink
    let records: RecordStore

    private(set) var mode: DojoMode
    private(set) var activity: Activity

    /// A gesture was recognised (for toasts and the avatar's hand).
    var onGesture: ((GestureKind, PointerAction) -> Void)?
    /// Visual feedback for the 3D scene.
    var onFeedback: ((Feedback) -> Void)?
    /// Every engine event, after the activity has seen it (for the live sensor meters).
    var onEvent: ((EngineEvent) -> Void)?

    private let inbox = EventInbox()
    private var token: ObserverToken?
    private var active = false
    private var sandboxRouted = false
    private var seed: UInt64

    init(host: DojoHost, records: RecordStore, mode: DojoMode = .freePlay, seed: UInt64? = nil,
         clock: @escaping () -> TimeInterval = { WristEngine.now() }) {
        self.host = host
        self.engine = host.engine
        self.records = records
        self.mode = mode
        self.seed = seed ?? UInt64.random(in: 1...UInt64.max)
        sink = SandboxSink(screenSize: Self.screenSize, clock: clock)
        activity = Activity(mode: mode)
        activity = makeActivity(mode)
    }

    deinit {
        if sandboxRouted { host.setSandboxSink(nil) }
    }

    // MARK: Lifecycle

    /// Start listening to the engine and take over pointer output (when the mode is sandboxed).
    func activate(now: TimeInterval) {
        guard !active else { return }
        active = true
        let inbox = self.inbox
        token = engine.addObserver { inbox.push($0) }
        routeOutput()
        activity.begin(context(now: now))
    }

    /// Stop listening and always hand pointer output back to the host.
    func deactivate(now: TimeInterval) {
        guard active else { return }
        active = false
        activity.end(context(now: now))
        releaseDrag()
        token = nil
        _ = inbox.drain()
        if sandboxRouted {
            sandboxRouted = false
            host.setSandboxSink(nil)
        }
    }

    func setMode(_ newMode: DojoMode, now: TimeInterval) {
        guard newMode != mode else { return }
        activity.end(context(now: now))
        releaseDrag()
        mode = newMode
        activity = makeActivity(newMode)
        if active {
            routeOutput()
            activity.begin(context(now: now))
        }
    }

    func perform(_ command: ActivityCommand, now: TimeInterval) {
        activity.perform(command, context(now: now))
        forwardFeedback()
    }

    func context(now: TimeInterval) -> ActivityContext {
        ActivityContext(now: now, cursor: sink.cursor, snapshot: engine.snapshot(), settings: engine.currentSettings)
    }

    // MARK: Heartbeat

    @discardableResult
    func pump(now: TimeInterval) -> ActivityContext {
        let drained = sink.drain()
        let settings = engine.currentSettings
        let context = ActivityContext(now: now, cursor: drained.cursor, snapshot: engine.snapshot(), settings: settings)
        guard active else { return context }

        if drained.edgeBumps > 0 { host.playHaptic(.edge) }
        for input in drained.inputs {
            if case .button(_, isDown: true, clickCount: _, at: let point) = input, mode == .calibration || mode == .simon {
                onFeedback?(.ripple(point, .neutral))       // these screens ignore clicks; still acknowledge them
            }
            activity.handle(input, context)
        }
        for event in inbox.drain() {
            if case .gesture(let kind, _) = event { onGesture?(kind, settings.action(for: kind)) }
            activity.handle(event, context)
            onEvent?(event)
        }
        activity.update(context)
        forwardFeedback()
        return context
    }

    private func forwardFeedback() {
        for feedback in activity.drainFeedback() {
            if case .haptic(let pattern) = feedback {
                host.playHaptic(pattern)
            } else {
                onFeedback?(feedback)
            }
        }
    }

    // MARK: Pieces

    private func routeOutput() {
        let wanted = mode.usesSandbox
        guard wanted != sandboxRouted else { return }
        sandboxRouted = wanted
        host.setSandboxSink(wanted ? sink : nil)
    }

    /// A drag must never outlive the activity that started it.
    private func releaseDrag() {
        if engine.snapshot().dragging { engine.perform(.toggleDrag) }
    }

    private func makeActivity(_ mode: DojoMode) -> Activity {
        seed &+= 0x9E37_79B9
        switch mode {
        case .freePlay:
            return FreePlayActivity(seed: seed)
        case .calibration:
            return CalibrationActivity(engine: engine, sink: sink, settingsDidChange: { [host] in host.settingsDidChange() })
        case .targets:
            return TargetRushDrill(records: records, seed: seed)
        case .drag:
            return DragDropDrill(records: records, seed: seed)
        case .scroll:
            return ScrollSeekerDrill(records: records, seed: seed)
        case .simon:
            return GestureSimonDrill(records: records, seed: seed)
        case .live:
            return LiveActivity(isRealWatchConnected: { [host] in host.isRealWatchConnected() })
        }
    }
}
