import AppKit
import SwiftUI
import GauntletEngine
import GauntletProtocol

/// Who is feeding the engine, as the HUD shows it.
struct LinkStatus: Equatable {
    var streaming = false
    var virtualWatch = false
    var realWatch = false
    var rightWrist = false
    var battery: Int?
    var heartRate: Int?
    var packetRate = 0
}

struct PointerFlags: Equatable {
    var engaged = false
    var paused = false
    var dragging = false
    var scrollMode = false
    var posture = VirtualPosture.pointing
}

struct GestureToast: Identifiable, Equatable {
    let id: Int
    var symbol: String
    var title: String
    var detail: String
    var expires: TimeInterval
}

/// Rolling sensor history for the HUD's live meters. Main-thread only; the meters read it
/// directly from a timeline view, so nothing here is published.
final class SensorTrace {
    struct Peak {
        var age = 0
        var value: Double
        var accepted: Bool
    }

    static let capacity = 180
    private var ring = [Double](repeating: 0, count: SensorTrace.capacity)
    private var head = 0
    private var pendingPeak = 0.0
    private(set) var peaks: [Peak] = []
    private(set) var snapshot = WristSnapshot()
    private(set) var settings = EngineSettings()

    func record(_ snapshot: WristSnapshot, settings: EngineSettings) {
        self.snapshot = snapshot
        self.settings = settings
        // A tap lasts a few samples; make sure its peak is not lost between frames.
        ring[head] = max(snapshot.tapEnvelope, pendingPeak)
        pendingPeak = 0
        head = (head + 1) % Self.capacity
        for index in peaks.indices { peaks[index].age += 1 }
        peaks.removeAll { $0.age >= Self.capacity }
    }

    func note(_ candidate: TapCandidate) {
        pendingPeak = max(pendingPeak, candidate.peak)
        peaks.append(Peak(value: candidate.peak, accepted: candidate.accepted))
    }

    /// Oldest first.
    var envelope: [Double] { Array(ring[head...] + ring[..<head]) }
}

/// Runs the Dojo for one `DojoView`: owns the session, the virtual watch, the 3D scene and the
/// state the HUD observes. Everything here happens on the main thread, paced by a 60 Hz timer.
final class DojoController: ObservableObject, DojoInputTarget {
    let host: DojoHost
    let session: DojoSession
    let trace = SensorTrace()
    private(set) lazy var scene = DojoScene(engine: host.engine, sink: session.sink)

    @Published private(set) var mode: DojoMode
    @Published private(set) var status = ActivityStatus()
    @Published private(set) var link = LinkStatus()
    @Published private(set) var flags = PointerFlags()
    @Published private(set) var toasts: [GestureToast] = []
    @Published private(set) var virtualRightWrist: Bool
    /// Bumped when a drill stores a result, so the stats sheet refreshes.
    @Published private(set) var recordsRevision = 0
    @Published var autopilot: Bool
    @Published var showHelp: Bool { didSet { defaults.set(showHelp, forKey: Keys.showHelp) } }
    @Published var showStats = false

    private enum Keys {
        static let showHelp = "dojo.showHelp"
        static let rightWrist = "dojo.virtualRightWrist"
    }

    private let defaults = UserDefaults.standard
    private let driver: VirtualWatchDriver
    private let renderer = ScreenRenderer(size: DojoSession.screenSize)
    private var timer: Timer?
    private var keyMonitor: Any?
    private weak var sceneView: NSView?
    private var running = false
    private var lastRender: TimeInterval = 0
    private var lastStatus: TimeInterval = 0
    private var lastTick: TimeInterval = 0
    private var toastSerial = 0
    private var viewSize = CGSize(width: 1280, height: 800)
    private var insets = CameraRig.Insets()
    private var historyCount = 0

    init(host: DojoHost, options: DojoOptions) {
        self.host = host
        mode = options.initialMode
        autopilot = options.autopilot
        showStats = options.showStats
        showHelp = defaults.object(forKey: Keys.showHelp) as? Bool ?? true
        virtualRightWrist = defaults.bool(forKey: Keys.rightWrist)
        let session = DojoSession(host: host, records: RecordStore(), mode: options.initialMode)
        self.session = session
        let sink = session.sink
        driver = VirtualWatchDriver(engine: host.engine, cursor: { sink.cursor })
        driver.setRightWrist(virtualRightWrist)

        session.onGesture = { [weak self] kind, action in self?.gestureRecognised(kind, action) }
        session.onFeedback = { [weak self] feedback in self?.scene.enqueue(feedback) }
        session.onEvent = { [weak self] event in
            if case .tapCandidate(let candidate) = event { self?.trace.note(candidate) }
        }
    }

    deinit {
        timer?.invalidate()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        driver.stop(sayGoodbye: true)
    }

    // MARK: Lifecycle

    func start() {
        guard !running else { return }
        running = true
        session.activate(now: WristEngine.now())
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.pump() }
        timer.tolerance = 0.002
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        }
        pump()
    }

    /// Called when the view goes away: stop simulating and hand the pointer back to the host.
    func stop() {
        guard running else { return }
        running = false
        timer?.invalidate()
        timer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        driver.stop(sayGoodbye: !host.isRealWatchConnected())
        session.deactivate(now: WristEngine.now())
    }

    func attach(view: NSView) { sceneView = view }

    // MARK: Commands from the HUD

    func select(_ newMode: DojoMode) {
        guard newMode != mode else { return }
        session.setMode(newMode, now: WristEngine.now())
        mode = newMode
        lastStatus = 0
        pump()
    }

    func perform(_ command: ActivityCommand) {
        session.perform(command, now: WristEngine.now())
        lastStatus = 0
    }

    func setVirtualWrist(right: Bool) {
        guard right != virtualRightWrist else { return }
        virtualRightWrist = right
        defaults.set(right, forKey: Keys.rightWrist)
        driver.setRightWrist(right)
    }

    func resetRecords() {
        session.records.reset()
        recordsRevision += 1
    }

    func setInsets(_ newInsets: CameraRig.Insets) {
        guard newInsets != insets else { return }
        insets = newInsets
        scene.setLayout(viewSize: viewSize, insets: insets)
    }

    // MARK: Heartbeat

    private func pump() {
        guard running else { return }
        let now = WristEngine.now()

        // The virtual watch steps aside the moment a real one is streaming, and returns when it leaves.
        // It never runs in Live mode: there its output would fight the user's own mouse.
        let real = host.isRealWatchConnected()
        let wantVirtual = !real && mode != .live
        if wantVirtual != driver.isRunning {
            if wantVirtual { driver.start() } else { driver.stop(sayGoodbye: !real) }
        }
        if now - lastTick > 0.25 {
            lastTick = now
            host.engine.tick(now: now)          // notice a silent stream even if the host is not ticking
        }

        session.records.isRecording = !(autopilot && wantVirtual)
        let context = session.pump(now: now)
        let activity = session.activity
        let crownGain = context.settings.crownScrollGain * (context.settings.scrollInverted ? -1 : 1)
        driver.setAutopilot(autopilot && wantVirtual ? activity.autopilotHint(context) : nil, crownPixelsPerUnit: crownGain)
        trace.record(context.snapshot, settings: context.settings)

        if activity.needsRedraw || (activity.isAnimating && now - lastRender >= 1.0 / 30) {
            activity.needsRedraw = false
            lastRender = now
            if let image = renderer.render(activity, context) { scene.setScreenImage(image) }
        }
        scene.setMode(mode, ghost: activity.ghostDemo)

        if now - lastStatus >= 0.1 {
            lastStatus = now
            publish(context, real: real, virtual: wantVirtual)
        }
        if let first = toasts.first, first.expires < now {
            toasts.removeAll { $0.expires < now }
        }
    }

    private func publish(_ context: ActivityContext, real: Bool, virtual: Bool) {
        let snap = context.snapshot
        let newStatus = session.activity.status(context)
        if newStatus != status { status = newStatus }
        let newLink = LinkStatus(streaming: snap.streaming, virtualWatch: virtual, realWatch: real, rightWrist: snap.rightWrist,
                                 battery: snap.battery, heartRate: snap.heartRate, packetRate: Int(snap.packetRate.rounded()))
        if newLink != link { link = newLink }
        let newFlags = PointerFlags(engaged: snap.engaged, paused: snap.paused, dragging: snap.dragging,
                                    scrollMode: snap.scrollMode, posture: driver.posture)
        if newFlags != flags { flags = newFlags }
        let count = DojoMode.drills.reduce(0) { $0 + session.records.history(for: $1).count }
        if count != historyCount { historyCount = count; recordsRevision += 1 }
    }

    private func gestureRecognised(_ kind: GestureKind, _ action: PointerAction) {
        if kind == .pinchTap || kind == .handDoubleTap { scene.pinch() }
        toastSerial += 1
        // One at a time: the band between the top bar and the screen has room for a single line.
        toasts = [GestureToast(id: toastSerial, symbol: kind.symbol, title: kind.title,
                               detail: action == .none ? "" : action.title, expires: WristEngine.now() + 1.5)]
    }

    // MARK: Mouse (DojoInputTarget)

    var mouseDrivesCamera: Bool { !driver.isRunning }

    func pointerMoved(u: Double, v: Double) { driver.steer(u: u, v: v) }

    func primaryClick(option: Bool) {
        if option { driver.flick(outward: false) } else { driver.tap() }
    }

    func secondaryClick() { driver.flick(outward: true) }

    func crownScrolled(deltaY: Double, precise: Bool) {
        // Trackpads report points, wheels report lines.
        driver.crown(delta: deltaY * (precise ? 0.0012 : 0.03))
    }

    func cameraOrbit(dx: CGFloat, dy: CGFloat) { scene.camera.orbit(dx: dx, dy: dy) }
    func cameraZoom(by factor: CGFloat) { scene.camera.zoom(by: factor) }

    func viewResized(to size: CGSize) {
        guard size != viewSize else { return }
        viewSize = size
        scene.setLayout(viewSize: viewSize, insets: insets)
    }

    // MARK: Keyboard

    /// Returns true when the key was ours.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let window = sceneView?.window, event.window === window else { return false }
        if window.firstResponder is NSText { return false }
        if !event.modifierFlags.intersection([.command, .control]).isEmpty { return false }
        let virtual = driver.isRunning
        if event.keyCode == 126, virtual { driver.toggle(.raised); return true }       // up arrow
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case " " where virtual: driver.toggle(.dropped)
        case "u" where virtual: driver.toggle(.raised)
        case "f" where virtual: driver.flick(outward: false)
        case "t" where virtual: driver.tap()
        case "s" where virtual: driver.action(.toggleScrollMode)
        case "p": if virtual { driver.action(.togglePause) } else { host.engine.setPaused(!host.engine.snapshot().paused) }
        case "r": if virtual { driver.action(.recenter) } else { host.engine.recenter() }
        case "a" where virtual: autopilot.toggle()
        case "c": scene.camera.reset()
        case "h", "?": showHelp.toggle()
        default: return false
        }
        return true
    }
}
