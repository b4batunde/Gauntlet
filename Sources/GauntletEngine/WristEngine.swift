import Foundation
import simd
import GauntletProtocol

/// Keeps an engine observer alive; the observer is removed when the token is released.
public final class ObserverToken {
    private let onCancel: () -> Void
    init(onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    public func cancel() { onCancel() }
    deinit { onCancel() }
}

/// Turns the watch's sensor stream into pointer movement, clicks and scrolling.
///
/// Thread-safe: feed it from any queue, read `snapshot()` from any other.
/// Output (sink calls and events) is delivered on the thread that called in, outside the lock.
public final class WristEngine: @unchecked Sendable {

    // MARK: Lifecycle

    /// `gestureStore` defaults to the user's saved custom gestures; pass `CustomGestureStore(url: nil)` in tests.
    public init(settings: EngineSettings = EngineSettings(),
                gestureStore: CustomGestureStore = CustomGestureStore()) {
        self.settings = settings
        self.customGestureStore = gestureStore
    }

    public static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: Public API

    /// Where pointer output goes. Swap freely at runtime (real cursor <-> Dojo sandbox).
    public var sink: PointerSink? {
        get { lock.lock(); defer { lock.unlock() }; return sinkRef }
        set {
            var out = Outbox()
            lock.lock()
            releaseHeldButton(&out, haptic: false)      // never carry a held button across sinks
            let old = sinkRef
            sinkRef = newValue
            lock.unlock()
            out.deliver(sink: old, observers: [])
        }
    }

    public var currentSettings: EngineSettings {
        lock.lock(); defer { lock.unlock() }
        return settings
    }

    public func updateSettings(_ mutate: (inout EngineSettings) -> Void) {
        lock.lock()
        mutate(&settings)
        lock.unlock()
    }

    public func snapshot() -> WristSnapshot {
        lock.lock(); defer { lock.unlock() }
        var s = snap
        s.time = clock
        return s
    }

    public func addObserver(_ handler: @escaping (EngineEvent) -> Void) -> ObserverToken {
        let id = UUID()
        lock.lock()
        observers[id] = handler
        lock.unlock()
        return ObserverToken { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.observers[id] = nil
            self.lock.unlock()
        }
    }

    /// Feed one decoded message from the watch.
    public func ingest(_ message: WatchMessage, now: TimeInterval = WristEngine.now()) {
        run { out in
            switch message {
            case .motion(let packet): self.processMotion(packet, now: now, &out)
            case .touch(let touch): self.processTouch(touch, now: now, &out)
            case .crown(let crown): self.processCrown(crown, &out)
            case .action(let action): self.processAction(action, now: now, &out)
            case .status(let status):
                self.snap.battery = status.battery
                self.snap.heartRate = status.heartRate
                self.snap.rssi = status.rssi
            case .hello, .authProof, .audio:
                break           // handshake is the link's job; audio goes to June, not the engine
            case .bye:
                self.stopStream(&out)
            }
        }
    }

    /// Call a few times a second so a silent link is noticed and held buttons are released.
    public func tick(now: TimeInterval = WristEngine.now()) {
        run { out in
            if self.snap.streaming, now - self.lastPacketWall > 0.7 { self.stopStream(&out) }
        }
    }

    /// The link dropped: release everything immediately.
    public func linkDidDisconnect() {
        run { out in self.stopStream(&out) }
    }

    public func setPaused(_ paused: Bool) {
        run { out in self.setPausedLocked(paused, &out) }
    }

    /// Hold the pointer still until `wallTime` (used while the user is typing).
    public func suppressPointer(until wallTime: TimeInterval) {
        lock.lock()
        suppressedUntil = max(suppressedUntil, wallTime)
        lock.unlock()
    }

    /// Declare the current pointing direction to be "straight ahead".
    public func recenter() {
        lock.lock()
        snap.heading = 0
        lock.unlock()
    }

    /// Run an action directly (menu items, the Dojo, keyboard shortcuts).
    public func perform(_ action: PointerAction, now: TimeInterval = WristEngine.now()) {
        run { out in self.performLocked(action, now: now, &out) }
    }

    // MARK: Custom gestures (public API)

    /// Saved custom gestures. Edit names, actions and enabled flags through it.
    public let customGestureStore: CustomGestureStore

    /// Consumes the next pinch tap or system Double Tap when it returns true (June's confirm and
    /// "Paste reply?" chip). Called synchronously **while the engine lock is held**: it must be quick,
    /// must not block, and must never call back into the engine.
    public var tapInterceptor: (() -> Bool)? {
        get { lock.lock(); defer { lock.unlock() }; return tapInterceptorRef }
        set { lock.lock(); tapInterceptorRef = newValue; lock.unlock() }
    }

    /// Opens a recording session. Then call `recordSample()` once per repetition (3 to 5 times).
    public func beginRecording(name: String) {
        run { out in
            self.endCaptureLocked(&out)
            self.recordingName = name
            self.recordingSamples = []
            self.captureMode = .recording
            self.snap.recordingGesture = true
            self.snap.recordingSampleCount = 0
        }
    }

    /// Captures one repetition: waits up to 4 s for the movement to start and ends it when the
    /// wrist goes still. Reported through `EngineEvent.recordingSample`.
    public func recordSample() {
        run { out in
            guard self.captureMode == .recording else { return }
            self.recorder.begin(time: self.clock, window: 4.0, onsetRate: 1.2)
            self.haptic(.notify, &out)
        }
    }

    public func discardLastSample() {
        lock.lock()
        if captureMode == .recording, !recordingSamples.isEmpty {
            recordingSamples.removeLast()
            snap.recordingSampleCount = recordingSamples.count
        }
        lock.unlock()
    }

    /// Learns the gesture from the samples and saves it. Returns nil (and keeps the session open)
    /// when there are fewer than 3 samples or they are too different from each other.
    public func finishRecording(action: CustomAction) -> CustomGesture? {
        lock.lock()
        guard captureMode == .recording, recordingSamples.count >= 3,
              let threshold = GestureMath.threshold(for: recordingSamples) else {
            lock.unlock()
            return nil
        }
        let gesture = CustomGesture(id: UUID(), name: recordingName.isEmpty ? "Gesture" : recordingName,
                                    action: action, enabled: true, createdAt: Date(),
                                    templates: recordingSamples, threshold: threshold)
        recorder.cancel()
        captureMode = .none
        recordingSamples = []
        recordingName = ""
        snap.recordingGesture = false
        snap.recordingSampleCount = 0
        snap.capturingGesture = false
        lock.unlock()
        // Outside the engine lock: the store's onChange may call back into the engine.
        customGestureStore.update(gesture)
        return gesture
    }

    public func cancelRecording() {
        run { out in
            guard self.captureMode == .recording else { return }
            self.endCaptureLocked(&out)
        }
    }

    /// Same as the watch-face Gesture button: the next movement (within 2.5 s) is matched against
    /// the saved gestures. Reported through `customGestureArmed`, then `customGestureMatch` or `customGestureMiss`.
    public func armCustomGesture() {
        run { out in self.armLocked(&out) }
    }

    // MARK: Internals

    private let lock = NSLock()
    private var settings: EngineSettings
    private var sinkRef: PointerSink?
    private var observers: [UUID: (EngineEvent) -> Void] = [:]

    private var snap = WristSnapshot()
    private var clock: TimeInterval = 0              // sample clock: regular, immune to radio jitter
    private var lastPacketWall: TimeInterval = 0
    private var lastSeq: UInt8?
    private var suppressedUntil: TimeInterval = 0

    private var rateFilter = AdaptiveLowPass2()
    private var tap = TapDetector()
    private var flick = FlickDetector()
    private var freezeUntil: TimeInterval = 0        // sample clock
    private var touchHoldUntil: TimeInterval = 0     // sample clock
    private var clutchOpen = false

    private var recentMoves: [(time: TimeInterval, delta: SIMD2<Double>)] = []
    private var heldButton: MouseButton?
    private var lastClickTime: TimeInterval = -10
    private var lastClickButton: MouseButton = .left
    private var lastClickCount = 0
    private var travelSinceClick = 0.0

    private var dwellOffset = SIMD2<Double>.zero
    private var dwellStart: TimeInterval = 0
    private var dwellArmed = false

    private var tapInterceptorRef: (() -> Bool)?
    private enum CaptureMode { case none, recording, armed, ambient }
    private var captureMode = CaptureMode.none
    private var recorder = MotionRecorder()
    private var recordingName = ""
    private var recordingSamples: [[SIMD3<Double>]] = []
    /// Always-on mode ignores movement until then, so one gesture never fires twice.
    private var ambientQuietUntil: TimeInterval = 0

    private var windowStart: TimeInterval = 0
    private var windowReceived = 0
    private var windowLost = 0

    private enum Output {
        case move(SIMD2<Double>)
        case button(MouseButton, Bool, Int)
        case scroll(SIMD2<Double>)
        case shortcut(SystemShortcut)
    }

    private struct Outbox {
        var outputs: [Output] = []
        var events: [EngineEvent] = []

        func deliver(sink: PointerSink?, observers: [(EngineEvent) -> Void]) {
            if let sink {
                for o in outputs {
                    switch o {
                    case .move(let d): sink.movePointer(dx: d.x, dy: d.y)
                    case .button(let b, let down, let count): sink.button(b, isDown: down, clickCount: count)
                    case .scroll(let d): sink.scroll(dx: d.x, dy: d.y)
                    case .shortcut(let s): sink.shortcut(s)
                    }
                }
            }
            for e in events { for o in observers { o(e) } }
        }
    }

    private func run(_ body: (inout Outbox) -> Void) {
        var out = Outbox()
        lock.lock()
        body(&out)
        let sink = sinkRef
        let obs = out.events.isEmpty ? [] : Array(observers.values)
        lock.unlock()
        out.deliver(sink: sink, observers: obs)
    }

    // MARK: Motion

    private func processMotion(_ p: MotionPacket, now: TimeInterval, _ out: inout Outbox) {
        let dt = p.sampleIntervalMs == 0 ? 0.01 : max(0.002, min(0.05, Double(p.sampleIntervalMs) / 1000))

        if !snap.streaming {
            snap.streaming = true
            clock = now
            lastSeq = nil
            rateFilter.reset(); tap.reset(); flick.reset()
            freezeUntil = 0; touchHoldUntil = 0
            windowStart = now; windowReceived = 0; windowLost = 0
            out.events.append(.streamStarted)
        }

        // Sequence gaps: account for lost time so detectors keep a truthful clock.
        if let last = lastSeq {
            let gap = Int(p.seq &- last &- 1)
            if gap > 0, gap < 128 {
                windowLost += gap
                let skipped = Double(gap * max(1, p.samples.count)) * dt
                clock += skipped
                if skipped > 0.25 { rateFilter.reset() }
            }
        }
        lastSeq = p.seq
        windowReceived += 1
        lastPacketWall = now
        if now - windowStart >= 0.5 {
            let elapsed = now - windowStart
            snap.packetRate = Double(windowReceived) / elapsed
            let total = windowReceived + windowLost
            snap.packetLoss = total > 0 ? Double(windowLost) / Double(total) : 0
            windowStart = now; windowReceived = 0; windowLost = 0
        }
        // The sample clock should shadow wall time; resync if the radio stalled.
        if abs(clock - now) > 0.5 { clock = now }

        snap.rightWrist = p.flags.contains(.rightWrist)
        snap.crownLeft = p.flags.contains(.crownLeft)
        snap.gravity = p.gravity
        snap.quaternion = p.quaternion

        let axis = forearmAxis(rightWrist: snap.rightWrist, crownLeft: snap.crownLeft,
                               flipped: settings.forearmAxisFlipped)
        let frame = PointingFrame.make(gravity: p.gravity, forearm: axis)
        snap.poseValid = frame != nil
        if let frame {
            snap.elevation = frame.elevation
            snap.roll = frame.roll()
        }
        updateEngagement(frame: frame, axis: axis, gravity: p.gravity, &out)

        // Always-on custom gestures listen whenever nothing else is capturing.
        if captureMode == .none, snap.engaged, customGestureStore.alwaysOn,
           customGestureStore.gestures.contains(where: { $0.enabled }) {
            captureMode = .ambient
            recorder.begin(time: clock, window: .infinity, onsetRate: 3.0)
        } else if captureMode == .ambient, !snap.engaged || !customGestureStore.alwaysOn {
            recorder.cancel()
            captureMode = .none
        }

        let tuning = settings.gestures
        let minCutoff = 4.0 + (0.6 - 4.0) * max(0, min(1, settings.smoothing))
        var move = SIMD2<Double>.zero
        var scroll = SIMD2<Double>.zero
        let typingSuppressed = now < suppressedUntil

        for s in p.samples {
            clock += dt

            // Custom gestures: a deliberate capture (recording or armed) owns the wrist while it runs.
            if recorder.active, clock >= ambientQuietUntil || captureMode != .ambient,
               let result = recorder.feed(s.gyro, time: clock, dt: dt) {
                handleCapture(result, dt: dt, pending: &move, &out)
            }
            let holding = recorder.capturing && (captureMode == .recording || captureMode == .armed)
            snap.capturingGesture = recorder.capturing && captureMode != .ambient
            let suppressed = typingSuppressed || holding

            var yaw = 0.0, pitch = 0.0, roll = 0.0
            if let frame {
                yaw = simd_dot(s.gyro, frame.up)
                pitch = simd_dot(s.gyro, frame.right)
                roll = simd_dot(s.gyro, frame.forward)
                let c = cos(frame.elevation)
                if c > 0.2 { snap.heading += yaw / c * dt }
            }
            snap.rates = SIMD3(yaw, pitch, roll)
            snap.gyro = s.gyro
            snap.accel = s.accel

            // Finger tap
            if var candidate = tap.process(accel: s.accel, gyroMagnitude: simd_length(s.gyro),
                                           time: clock, dt: dt, tuning: tuning) {
                if !snap.engaged || snap.touching || flick.isBusy || suppressed { candidate.accepted = false }
                out.events.append(.tapCandidate(candidate))
                if candidate.accepted {
                    rollBack(window: 0.07, pending: &move, &out)
                    freezeUntil = clock + 0.12
                    fire(.pinchTap, strength: candidate.peak, now: now, &out)
                }
            }
            snap.tapEnvelope = tap.envelope

            // Wrist flick
            if frame != nil,
               let f = flick.process(roll: roll, yaw: yaw, pitch: pitch, time: clock, dt: dt, tuning: tuning) {
                let outward = (f.sign > 0) == snap.rightWrist
                out.events.append(.flickCandidate(outward: outward, peakRate: f.peakRate))
                if snap.engaged, !suppressed {
                    rollBack(window: 0.09, pending: &move, &out)
                    freezeUntil = clock + 0.18
                    fire(outward ? .flickOut : .flickIn, strength: f.peakRate, now: now, &out)
                }
            }
            if flick.isBusy { freezeUntil = max(freezeUntil, clock + 0.10) }

            // Pointer / air scroll
            let v = rateFilter.filter(SIMD2(yaw, pitch), dt: dt, minCutoff: minCutoff, beta: 6.0)
            guard snap.engaged, frame != nil, !suppressed,
                  clock >= freezeUntil, clock >= touchHoldUntil, !snap.touching else { continue }
            let speed = simd_length(v)
            guard speed > settings.deadZone else { continue }
            let live = (speed - settings.deadZone) / speed
            if snap.scrollMode {
                let sign: Double = settings.scrollInverted ? -1 : 1
                scroll.y += v.y * live * settings.airScrollGain * dt * sign
                scroll.x += v.x * live * settings.airScrollGain * dt * sign * 0.5
            } else {
                let boost = smoothstep(0.05, settings.boostSpeed, speed)
                let multiplier = settings.precisionMultiplier
                    + (settings.boostMultiplier - settings.precisionMultiplier) * boost
                let gain = settings.baseGain * settings.sensitivity * multiplier
                var d = SIMD2(-v.x, -v.y) * (live * gain * dt)
                if settings.invertX { d.x = -d.x }
                if settings.invertY { d.y = -d.y }
                move += d
            }
        }

        let span = Double(max(1, p.samples.count)) * dt
        if simd_length(move) > 1e-4 {
            emitMove(move, &out)
            snap.pointerVelocity = move / span
        } else {
            snap.pointerVelocity = .zero
        }
        if simd_length(scroll) > 1e-3 { out.outputs.append(.scroll(scroll)) }

        processDwell(move: move, now: now, &out)
    }

    private func emitMove(_ d: SIMD2<Double>, _ out: inout Outbox) {
        out.outputs.append(.move(d))
        recentMoves.append((clock, d))
        // Enough history to undo a whole always-on custom gesture (up to ~2 s at 50 packets/s).
        if recentMoves.count > 120 { recentMoves.removeFirst(recentMoves.count - 120) }
        travelSinceClick += simd_length(d)
    }

    /// Undo pointer travel from the last `window` seconds — the gesture itself jolts the wrist,
    /// and the click should land where the user was aiming before it.
    private func rollBack(window: TimeInterval, pending: inout SIMD2<Double>, _ out: inout Outbox) {
        let cutoff = clock - window
        var undo = SIMD2<Double>.zero
        recentMoves.removeAll { entry in
            if entry.time > cutoff { undo -= entry.delta; return true }
            return false
        }
        pending = .zero
        if simd_length(undo) > 1e-4 { out.outputs.append(.move(undo)) }
    }

    private func updateEngagement(frame: PointingFrame?, axis: SIMD3<Double>, gravity: SIMD3<Double>,
                                  _ out: inout Outbox) {
        if let frame {
            let degrees = frame.elevation * 180 / .pi
            switch settings.clutch {
            case .always:
                if clutchOpen { if degrees < settings.restAngleDeg { clutchOpen = false } }
                else if degrees > settings.restAngleDeg + 8 { clutchOpen = true }
            case .raiseToPoint:
                if clutchOpen { if degrees < settings.raiseAngleDeg - 6 { clutchOpen = false } }
                else if degrees > settings.raiseAngleDeg { clutchOpen = true }
            }
        } else {
            // Forearm vertical. Hanging straight down always releases.
            let g = simd_length(gravity)
            if g > 0.3, simd_dot(axis, -gravity / g) < -0.9 { clutchOpen = false }
        }
        setEngaged(!snap.paused && clutchOpen, &out)
    }

    private func setEngaged(_ engaged: Bool, _ out: inout Outbox) {
        guard engaged != snap.engaged else { return }
        snap.engaged = engaged
        out.events.append(.engagedChanged(engaged))
        haptic(engaged ? .engage : .disengage, &out)
        if !engaged {
            releaseHeldButton(&out, haptic: false)
            rateFilter.reset()
            dwellArmed = false
        }
    }

    private func processDwell(move: SIMD2<Double>, now: TimeInterval, _ out: inout Outbox) {
        guard settings.gestures.dwellEnabled, snap.engaged, !snap.scrollMode else { dwellArmed = false; return }
        dwellOffset += move
        if simd_length(dwellOffset) > settings.gestures.dwellRadius {
            dwellOffset = .zero
            dwellStart = clock
            dwellArmed = true
        } else if dwellArmed, clock - dwellStart >= settings.gestures.dwellTime {
            dwellArmed = false
            fire(.dwell, strength: 1, now: now, &out)
        }
    }

    // MARK: Touch, crown, actions

    private func processTouch(_ t: TouchEvent, now: TimeInterval, _ out: inout Outbox) {
        switch t.phase {
        case .began:
            snap.touching = true
        case .moved:
            snap.touching = true
            guard !snap.paused else { return }
            // Mild acceleration: slow drags are 1:1 with the gain, quick swipes travel further.
            let distance = (t.dx * t.dx + t.dy * t.dy).squareRoot()
            let accel = 1 + min(2.0, distance / 6)
            let d = SIMD2(t.dx, t.dy) * (settings.touchGain * accel)
            if simd_length(d) > 1e-4 { emitMove(d, &out) }
        case .ended, .cancelled:
            snap.touching = false
            touchHoldUntil = clock + 0.25
        }
    }

    private func processCrown(_ c: CrownEvent, _ out: inout Outbox) {
        guard !snap.paused else { return }
        let sign: Double = settings.scrollInverted ? -1 : 1
        let dy = c.delta * settings.crownScrollGain * sign
        if abs(dy) > 1e-3 { out.outputs.append(.scroll(SIMD2(0, dy))) }
    }

    private func processAction(_ a: WatchAction, now: TimeInterval, _ out: inout Outbox) {
        switch a.code {
        case .togglePause:
            setPausedLocked(!snap.paused, &out)
            return
        case .recenter:
            snap.heading = 0
            haptic(.notify, &out)
            return
        case .voiceHold:
            out.events.append(.voiceHold(isDown: a.argument != 0))
            return
        default:
            break
        }
        guard !snap.paused else { return }
        switch a.code {
        case .screenTap: fire(.screenTap, strength: 1, now: now, &out)
        case .screenDoubleTap: fire(.screenDoubleTap, strength: 1, now: now, &out)
        case .screenLongPress: fire(.screenLongPress, strength: 1, now: now, &out)
        case .handDoubleTap: fire(.handDoubleTap, strength: 1, now: now, &out)
        case .toggleDrag: performLocked(.toggleDrag, now: now, &out)
        case .toggleScrollMode: performLocked(.toggleScrollMode, now: now, &out)
        case .rightClick: performLocked(.rightClick, now: now, &out)
        case .leftClick: performLocked(.leftClick, now: now, &out)
        case .armGesture: armLocked(&out)
        case .togglePause, .recenter, .voiceHold: break
        }
    }

    private func fire(_ gesture: GestureKind, strength: Double, now: TimeInterval, _ out: inout Outbox) {
        // June's confirm / paste chip gets first claim on a tap.
        if gesture == .pinchTap || gesture == .handDoubleTap, let intercept = tapInterceptorRef, intercept() {
            haptic(.success, &out)
            return
        }
        snap.lastGesture = gesture
        snap.lastGestureTime = clock
        out.events.append(.gesture(gesture, strength: strength))
        performLocked(settings.action(for: gesture), now: now, &out)
    }

    private func performLocked(_ action: PointerAction, now: TimeInterval, _ out: inout Outbox) {
        switch action {
        case .none:
            return
        case .leftClick:
            if heldButton != nil { releaseHeldButton(&out, haptic: true) } else { click(.left, now: now, &out) }
        case .rightClick:
            click(.right, now: now, &out)
        case .middleClick:
            click(.middle, now: now, &out)
        case .doubleClick:
            releaseHeldButton(&out, haptic: false)
            out.outputs.append(.button(.left, true, 1)); out.outputs.append(.button(.left, false, 1))
            out.outputs.append(.button(.left, true, 2)); out.outputs.append(.button(.left, false, 2))
            lastClickTime = now; lastClickButton = .left; lastClickCount = 2; travelSinceClick = 0
            haptic(.doubleClick, &out)
        case .toggleDrag:
            if heldButton != nil {
                releaseHeldButton(&out, haptic: true)
            } else {
                heldButton = .left
                snap.dragging = true
                out.outputs.append(.button(.left, true, 1))
                out.events.append(.draggingChanged(true))
                haptic(.dragStart, &out)
            }
        case .toggleScrollMode:
            snap.scrollMode.toggle()
            out.events.append(.scrollModeChanged(snap.scrollMode))
            haptic(.notify, &out)
        case .toggleEngage:
            setPausedLocked(!snap.paused, &out)
        case .missionControl:
            out.outputs.append(.shortcut(.missionControl))
            haptic(.notify, &out)
        }
        out.events.append(.action(action))
    }

    private func click(_ button: MouseButton, now: TimeInterval, _ out: inout Outbox) {
        releaseHeldButton(&out, haptic: false)
        var count = 1
        if button == lastClickButton, now - lastClickTime < 0.45, travelSinceClick < 8 {
            count = min(3, lastClickCount + 1)
        }
        out.outputs.append(.button(button, true, count))
        out.outputs.append(.button(button, false, count))
        lastClickTime = now; lastClickButton = button; lastClickCount = count; travelSinceClick = 0
        switch button {
        case .left: haptic(count >= 2 ? .doubleClick : .click, &out)
        case .right, .middle: haptic(.rightClick, &out)
        }
    }

    private func releaseHeldButton(_ out: inout Outbox, haptic playHaptic: Bool) {
        guard let button = heldButton else { return }
        heldButton = nil
        snap.dragging = false
        out.outputs.append(.button(button, false, 1))
        out.events.append(.draggingChanged(false))
        if playHaptic { haptic(.dragEnd, &out) }
    }

    private func setPausedLocked(_ paused: Bool, _ out: inout Outbox) {
        guard paused != snap.paused else { return }
        snap.paused = paused
        out.events.append(.pausedChanged(paused))
        if paused {
            setEngaged(false, &out)
            if snap.scrollMode { snap.scrollMode = false; out.events.append(.scrollModeChanged(false)) }
        }
        // Resuming re-engages on the next motion packet, once the clutch agrees.
    }

    // MARK: Custom gestures (internals, under the lock)

    private func armLocked(_ out: inout Outbox) {
        guard captureMode != .recording else { return }      // never interrupt a recording session
        guard customGestureStore.gestures.contains(where: { $0.enabled }) else {
            haptic(.failure, &out)
            out.events.append(.customGestureMiss(bestConfidence: 0))
            return
        }
        captureMode = .armed
        recorder.begin(time: clock, window: 2.5, onsetRate: 1.2)
        snap.customGestureArmed = true
        out.events.append(.customGestureArmed(true))
        haptic(.notify, &out)
    }

    /// Leaves whatever capture is running, announcing the end of an armed window.
    private func endCaptureLocked(_ out: inout Outbox) {
        recorder.cancel()
        if captureMode == .armed { out.events.append(.customGestureArmed(false)) }
        captureMode = .none
        recordingSamples = []
        recordingName = ""
        snap.customGestureArmed = false
        snap.capturingGesture = false
        snap.recordingGesture = false
        snap.recordingSampleCount = 0
    }

    private func handleCapture(_ result: MotionRecorder.Result, dt: Double, pending: inout SIMD2<Double>,
                               _ out: inout Outbox) {
        switch captureMode {
        case .none:
            recorder.cancel()

        case .recording:
            guard case .finished(let raw) = result else {
                out.events.append(.recordingSample(index: recordingSamples.count + 1, accepted: false, quality: 0))
                haptic(.failure, &out)
                return
            }
            let template = GestureMath.template(raw)
            var quality = 1.0
            if !recordingSamples.isEmpty {
                var total = 0.0
                for other in recordingSamples { total += GestureMath.distance(template, other) }
                let mean = total / Double(recordingSamples.count)
                quality = max(0, min(1, 1 - mean / GestureMath.sampleRejectDistance))
            }
            let accepted = recordingSamples.isEmpty || quality > 0
            if accepted {
                recordingSamples.append(template)
                snap.recordingSampleCount = recordingSamples.count
            }
            out.events.append(.recordingSample(index: recordingSamples.count + (accepted ? 0 : 1),
                                               accepted: accepted, quality: quality))
            haptic(accepted ? .success : .failure, &out)

        case .armed:
            captureMode = .none
            snap.customGestureArmed = false
            snap.capturingGesture = false
            if case .finished(let raw) = result {
                _ = matchAndPerform(GestureMath.template(raw), strictness: 1, announceMiss: true, &out)
            } else {
                out.events.append(.customGestureMiss(bestConfidence: 0))
                haptic(.failure, &out)
            }
            out.events.append(.customGestureArmed(false))

        case .ambient:
            if case .finished(let raw) = result,
               matchAndPerform(GestureMath.template(raw), strictness: GestureMath.alwaysOnStrictness,
                               announceMiss: false, &out) {
                // Without arming, the gesture also moved the pointer: put it back where it was,
                // then ignore movement briefly so the same motion cannot fire again.
                rollBack(window: Double(raw.count) * dt + MotionRecorder.quietTime + 0.1, pending: &pending, &out)
                ambientQuietUntil = clock + 0.6
            }
            recorder.begin(time: clock, window: .infinity, onsetRate: 3.0)
        }
    }

    /// Returns true when a gesture matched and its action ran.
    private func matchAndPerform(_ trace: [SIMD3<Double>], strictness: Double, announceMiss: Bool,
                                 _ out: inout Outbox) -> Bool {
        var best: CustomGesture?
        var bestRatio = Double.infinity
        var bestConfidence = 0.0
        for g in customGestureStore.gestures where g.enabled && !g.templates.isEmpty {
            let limit = g.threshold * strictness
            let d = GestureMath.bestDistance(trace, to: g.templates)
            let ratio = d / limit
            if ratio < bestRatio {
                bestRatio = ratio
                best = g
                bestConfidence = GestureMath.confidence(distance: d, threshold: limit)
            }
        }
        guard let gesture = best, bestRatio <= 1 else {
            if announceMiss {
                out.events.append(.customGestureMiss(bestConfidence: bestConfidence))
                haptic(.failure, &out)
            }
            return false
        }
        out.events.append(.customGestureMatch(id: gesture.id, confidence: bestConfidence))
        performCustom(gesture.action, &out)
        return true
    }

    private func performCustom(_ action: CustomAction, _ out: inout Outbox) {
        switch action {
        case .pointer(let pointerAction):
            performLocked(pointerAction, now: WristEngine.now(), &out)
        case .keyCombo(let keyCode, let modifiers):
            out.outputs.append(.shortcut(.keyCombo(keyCode: keyCode, modifiers: modifiers)))
            haptic(.success, &out)
        case .openApp(let bundleID):
            out.outputs.append(.shortcut(.openApp(bundleID: bundleID)))
            haptic(.success, &out)
        case .assistant(let command):
            out.events.append(.assistantRequested(command))
            haptic(.success, &out)
        case .none:
            break
        }
    }

    private func stopStream(_ out: inout Outbox) {
        guard snap.streaming else { return }
        if captureMode == .armed || captureMode == .ambient { endCaptureLocked(&out) }
        else if captureMode == .recording { recorder.cancel(); snap.capturingGesture = false }
        snap.streaming = false
        snap.pointerVelocity = .zero
        snap.touching = false
        clutchOpen = false
        releaseHeldButton(&out, haptic: false)
        if snap.engaged {
            snap.engaged = false
            out.events.append(.engagedChanged(false))
        }
        out.events.append(.streamStalled)
    }

    private func haptic(_ pattern: HapticPattern, _ out: inout Outbox) {
        if settings.hapticsEnabled { out.events.append(.haptic(pattern)) }
    }
}
