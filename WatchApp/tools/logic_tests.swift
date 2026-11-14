// Tests for the platform-neutral half of the watch app, runnable on a Mac without Xcode:
//
//     WatchApp/tools/typecheck.sh        (pass 4 builds and runs this file)
//
// Covers touch classification, crown maths, the keep-alive fallback chain, the haptic and
// state mappings, the simulator's motion source, and the app model end to end against a
// real `LinkServer` over an in-memory transport.
import Foundation
import GauntletProtocol
import GauntletLink
import GauntletWatchCore
import GauntletEngine

// MARK: Harness

var checks = 0
var failures = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("    FAIL line \(line): \(message)")
    }
}

func section(_ name: String, _ body: () -> Void) {
    let before = failures
    body()
    print("  \(failures == before ? "ok  " : "FAIL") \(name)")
}

/// Spins the main run loop (which also drains `DispatchQueue.main`) until `condition` holds.
@discardableResult
func pump(_ timeout: TimeInterval = 3, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    return condition()
}

func pump(for seconds: TimeInterval) {
    pump(seconds) { false }
}

// MARK: Fakes

final class FakeMotion: MotionSource {
    var unavailableReason: String?
    var starts: [Int] = []
    var stops = 0
    var sink: MotionSink?
    var wearing: WearingInfo?
    func start(rateHz: Int, sink: @escaping MotionSink) { starts.append(rateHz); self.sink = sink }
    func stop() { stops += 1; sink = nil }
    func setWearing(_ wearing: WearingInfo) { self.wearing = wearing }
}

final class FakeBackend: KeepAliveBackend {
    let name: String
    var onEvent: ((KeepAliveEvent) -> Void)?
    var startCount = 0
    var stopCount = 0
    /// Answer given synchronously from `start()`, if any.
    var answer: KeepAliveEvent?
    init(_ name: String, answer: KeepAliveEvent? = nil) { self.name = name; self.answer = answer }
    func start() { startCount += 1; if let answer { onEvent?(answer) } }
    func stop() { stopCount += 1 }
}

final class FakeDevice: DeviceProbe, HapticPlayer {
    var deviceName = "Test Watch"
    var worn = WearingInfo(rightWrist: true, crownLeft: true)
    var power = BatteryInfo(percent: 82, charging: false)
    var played: [HapticTone] = []
    func wearing() -> WearingInfo { worn }
    func battery() -> BatteryInfo { power }
    func play(_ tone: HapticTone) { played.append(tone) }
}

final class ServerProbe: LinkServerDelegate {
    private let lock = NSLock()
    private var stored: [WatchMessage] = []
    var messages: [WatchMessage] { lock.lock(); defer { lock.unlock() }; return stored }
    func linkServer(_ server: LinkServer, didChange state: LinkServerState) {}
    func linkServer(_ server: LinkServer, didReceive message: WatchMessage) {
        lock.lock(); stored.append(message); lock.unlock()
    }
}

/// Forwards to another transport but does not claim to be a local loopback, so the server
/// asks for approval the way it does over Bluetooth.
final class RadioLike: LinkTransport, LinkTransportDelegate {
    weak var delegate: LinkTransportDelegate?
    let name = "radio"
    private let inner: LinkTransport
    init(_ inner: LinkTransport) { self.inner = inner; inner.delegate = self }
    var maxPayload: Int { inner.maxPayload }
    var isOpen: Bool { inner.isOpen }
    var isLocalLoopback: Bool { false }
    func start() { inner.start() }
    func stop() { inner.stop() }
    func send(_ data: Data, reliable: Bool) { inner.send(data, reliable: reliable) }
    func disconnectPeer() { inner.disconnectPeer() }
    func transportDidOpen(_ transport: LinkTransport) { delegate?.transportDidOpen(self) }
    func transport(_ transport: LinkTransport, didReceive data: Data) { delegate?.transport(self, didReceive: data) }
    func transportDidClose(_ transport: LinkTransport, reason: String?) { delegate?.transportDidClose(self, reason: reason) }
    func transport(_ transport: LinkTransport, didChangeStatus status: String) { delegate?.transport(self, didChangeStatus: status) }
}

// MARK: Tests

func touchTests() {
    let down: TouchOutput = .touch(.began, dx: 0, dy: 0)
    let up: TouchOutput = .touch(.ended, dx: 0, dy: 0)

    section("a quick still touch is a tap, sent at once") {
        var c = TouchClassifier()
        check(c.changed(tx: 0, ty: 0, at: 10) == [down], "began on first event")
        check(c.longPressPending, "long press armed")
        check(c.changed(tx: 2, ty: -1, at: 10.05) == [], "jitter under the slop is withheld")
        check(c.ended(at: 10.12) == [.action(.screenTap), up], "tap, then ended")
        check(!c.isDown, "finger up")
    }
    section("a still touch that is neither quick nor long is nothing") {
        var c = TouchClassifier()
        _ = c.changed(tx: 0, ty: 0, at: 1)
        check(c.ended(at: 1.4) == [up], "no tap after 0.4 s")
    }
    section("holding still is one long press and no tap") {
        var c = TouchClassifier()
        _ = c.changed(tx: 0, ty: 0, at: 5)
        check(c.longPressDeadline(at: 5.2) == [], "too early")
        check(c.longPressDeadline(at: 5.5) == [.action(.screenLongPress), .localHaptic], "fires at 0.5 s")
        check(c.longPressDeadline(at: 5.9) == [], "fires once")
        check(!c.longPressPending, "no longer pending")
        check(c.ended(at: 6.0) == [up], "no tap on release")
    }
    section("a drag sends deltas after the slop and never a tap or long press") {
        var c = TouchClassifier()
        _ = c.changed(tx: 0, ty: 0, at: 0)
        check(c.changed(tx: 3, ty: 0, at: 0.02) == [], "inside slop")
        check(c.changed(tx: 7, ty: 0, at: 0.04) == [], "crossing the slop does not jump")
        check(!c.longPressPending, "long press abandoned")
        check(c.changed(tx: 10, ty: 2, at: 0.06) == [.touch(.moved, dx: 3, dy: 2)], "delta since last event")
        check(c.changed(tx: 10, ty: 2, at: 0.07) == [], "no movement, no message")
        check(c.changed(tx: 8, ty: -1, at: 0.08) == [.touch(.moved, dx: -2, dy: -3)], "negative deltas")
        check(c.longPressDeadline(at: 0.6) == [], "no long press while dragging")
        check(c.ended(at: 0.1) == [up], "quick drag is not a tap")
    }
    section("deltas add up to the finger's travel after the slop") {
        var c = TouchClassifier()
        _ = c.changed(tx: 0, ty: 0, at: 0)
        var sumX = 0.0, sumY = 0.0
        var crossedAt: (Double, Double)?
        for step in 1...60 {
            let x = Double(step) * 0.9, y = Double(step) * -0.4
            let wasPending = c.longPressPending
            for output in c.changed(tx: x, ty: y, at: Double(step) * 0.01) {
                if case .touch(.moved, let dx, let dy) = output { sumX += dx; sumY += dy }
            }
            if wasPending && !c.longPressPending { crossedAt = (x, y) }
        }
        check(crossedAt != nil, "slop crossed")
        if let crossedAt {
            check(abs(sumX - (54.0 - crossedAt.0)) < 1e-9 && abs(sumY - (-24.0 - crossedAt.1)) < 1e-9,
                  "sum \(sumX), \(sumY)")
        }
    }
    section("cancelled touches end without a tap, and the next touch starts clean") {
        var c = TouchClassifier()
        _ = c.changed(tx: 0, ty: 0, at: 0)
        check(c.cancelled() == [.touch(.cancelled, dx: 0, dy: 0)], "cancelled")
        check(c.ended(at: 0.05) == [], "nothing after cancel")
        check(c.cancelled() == [], "idempotent")
        check(c.changed(tx: 40, ty: 40, at: 1) == [down], "new touch begins; stale translation ignored")
        check(c.ended(at: 1.1) == [.action(.screenTap), up], "and can tap")
    }
}

func crownTests() {
    section("crown deltas are in turns, wrap cleanly and are bounded") {
        let unit = CrownTuning.unitsPerTurn, span = CrownTuning.span
        check(abs(CrownMath.turns(from: 0, to: unit) - CrownTuning.upwardSign) < 1e-12, "one turn")
        check(abs(CrownMath.turns(from: 5, to: 5 - unit / 2) + 0.5 * CrownTuning.upwardSign) < 1e-12, "half turn back")
        check(CrownMath.turns(from: 3, to: 3) == 0, "no movement")
        let wrapUp = CrownMath.turns(from: span - 1, to: -span + 1)
        check(abs(wrapUp - 2 / unit * CrownTuning.upwardSign) < 1e-9, "wraps upward: \(wrapUp)")
        let wrapDown = CrownMath.turns(from: -span + 1, to: span - 1)
        check(abs(wrapDown + 2 / unit * CrownTuning.upwardSign) < 1e-9, "wraps downward: \(wrapDown)")
        check(abs(CrownMath.turns(from: 0, to: 5000)) == CrownTuning.maxTurnsPerEvent, "clamped")
        check(CrownMath.turns(from: 0, to: .nan) == 0, "NaN ignored")
    }
}

func mappingTests() {
    section("every haptic pattern and Mac state has a presentation") {
        check(HapticPattern.allCases.count == 12, "pattern count changed: revisit HapticMapping.swift")
        check(Set(HapticPattern.allCases.map { $0.tone }).count >= 7, "tones are varied")
        check(HapticPattern.click.tone == .click && HapticPattern.failure.tone == .failure, "obvious ones")
        check(ControlMode([]) == .released, "nothing set")
        check(ControlMode([.engaged]) == .engaged, "engaged")
        check(ControlMode([.engaged, .scrollMode]) == .scrolling, "scroll mode beats engaged")
        check(ControlMode([.engaged, .scrollMode, .dragging]) == .dragging, "dragging beats scroll mode")
        check(ControlMode([.engaged, .dragging, .paused, .sandbox]) == .paused, "paused beats everything")
        for mode in [ControlMode.paused, .dragging, .scrolling, .engaged, .released] {
            check(!mode.label.contains(" ") && mode.label == mode.label.uppercased(), "one word: \(mode.label)")
        }
    }
    section("June's states map to a look and the right haptics") {
        check(JuneLook(.off) == .quiet && JuneLook(.idle) == .quiet, "off and idle are quiet")
        check(JuneLook(.waiting) == .waiting && !JuneLook(.waiting).takesOverRing, "waiting is only an indicator")
        check(JuneLook(.listening).takesOverRing && JuneLook(.thinking).takesOverRing, "listening/thinking own the ring")
        for state in AssistantWatchState.allCases {
            let look = JuneLook(state)
            check(look.label == look.label.uppercased() && !look.label.contains(" "), "one word: \(look.label)")
        }
        check(JuneLook.haptic(from: .waiting, to: .listening) == .directionUp, "wake")
        check(JuneLook.haptic(from: .listening, to: .thinking) == .click, "captured")
        check(JuneLook.haptic(from: .thinking, to: .idle) == .success, "answered")
        check(JuneLook.haptic(from: .waiting, to: .idle) == nil, "idle without an answer is silent")
        check(JuneLook.haptic(from: .listening, to: .listening) == nil, "no repeats")
    }
}

func keepAliveTests() {
    section("the preferred backend is used when it works") {
        let workout = FakeBackend("Workout", answer: .started), runtime = FakeBackend("Runtime", answer: .started)
        let k = KeepAliveCoordinator(backends: [workout, runtime])
        var changes = 0
        k.onChange = { changes += 1 }
        k.start()
        check(k.state == .active("Workout") && k.isActive, "active on workout: \(k.state)")
        check(runtime.startCount == 0, "fallback untouched")
        k.start()
        check(workout.startCount == 1, "start is idempotent")
        workout.onEvent?(.heartRate(71))
        check(k.heartRate == 71 && changes >= 3, "heart rate published")
        k.stop()
        check(k.state == .off && k.heartRate == nil && workout.stopCount == 1 && !k.isWanted, "stopped")
        workout.onEvent?(.heartRate(90))
        workout.onEvent?(.stopped(reason: "late"))
        check(k.state == .off && k.heartRate == nil && runtime.startCount == 0, "late events ignored")
    }
    section("falls back when the preferred backend cannot run or dies") {
        let workout = FakeBackend("Workout"), runtime = FakeBackend("Runtime")
        let k = KeepAliveCoordinator(backends: [workout, runtime])
        k.start()
        check(k.state == .starting, "waiting for the workout")
        workout.onEvent?(.stopped(reason: "denied"))
        check(runtime.startCount == 1 && k.state == .starting, "fallback started")
        workout.onEvent?(.started)
        check(k.state == .starting, "stale backend ignored")
        runtime.onEvent?(.started)
        check(k.state == .active("Runtime"), "active on fallback")
        runtime.onEvent?(.stopped(reason: "expired"))
        check(k.state == .unavailable("expired") && !k.isActive && k.isWanted, "nothing left: \(k.state)")
        k.start()
        check(workout.startCount == 2 && k.state == .starting, "retries from the preferred backend")
        workout.onEvent?(.started)
        workout.onEvent?(.heartRate(64))
        workout.onEvent?(.stopped(reason: "ended"))
        check(k.heartRate == nil && runtime.startCount == 2, "heart rate cleared on fallback")
    }
    section("no backends at all is reported, not fatal") {
        let k = KeepAliveCoordinator(backends: [])
        k.start()
        check(k.state == .unavailable(nil), "unavailable")
        k.stop()
        check(k.state == .off, "off")
    }
}

func virtualMotionTests() {
    section("the simulator's motion source produces plausible samples at the requested rate") {
        let source = VirtualMotionSource()
        let lock = NSLock()
        var count = 0, worstGravity = 0.0, worstQuaternion = 0.0, maxGyro = 0.0
        source.setWearing(WearingInfo(rightWrist: false, crownLeft: false))
        source.start(rateHz: 100) { gyro, _, gravity, q in
            lock.lock()
            count += 1
            worstGravity = max(worstGravity, abs((gravity * gravity).sum().squareRoot() - 1))
            worstQuaternion = max(worstQuaternion, abs((q * q).sum().squareRoot() - 1))
            maxGyro = max(maxGyro, (gyro * gyro).sum().squareRoot())
            lock.unlock()
        }
        Thread.sleep(forTimeInterval: 0.6)
        source.stop()
        Thread.sleep(forTimeInterval: 0.05)
        lock.lock(); let seen = count; lock.unlock()
        check(seen >= 35 && seen <= 70, "about 55 samples in 0.55 s, got \(seen)")
        check(worstGravity < 1e-6 && worstQuaternion < 1e-6, "unit gravity and quaternion")
        check(maxGyro > 0.001 && maxGyro < 5, "the arm is moving gently: \(maxGyro) rad/s")
        Thread.sleep(forTimeInterval: 0.1)
        lock.lock(); let after = count; lock.unlock()
        check(after == seen, "silent after stop")
    }
}

func appModelTests() {
    let queue = DispatchQueue(label: "test.link")
    let (macSide, watchSide) = LoopbackTransport.pair(queue: queue)
    let server = LinkServer(identity: LinkIdentity(), trust: TrustStore(fileURL: nil), macName: "Test Mac", queue: queue)
    let probe = ServerProbe()
    server.delegate = probe
    server.add(macSide)
    server.start()

    let suiteName = "gauntlet.watch.tests.\(ProcessInfo.processInfo.processIdentifier)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let motion = FakeMotion(), device = FakeDevice()
    let workout = FakeBackend("Workout"), runtime = FakeBackend("Runtime")
    let services = PlatformServices(route: .developerLink(host: "127.0.0.1"), device: device, haptics: device,
                                    motion: motion, keepAlive: [workout, runtime], isSimulated: false)
    let session = WatchSessionController(deviceName: device.deviceName, identity: LinkIdentity(),
                                         transport: watchSide, queue: queue)
    let model = AppModel(services: services, defaults: defaults, session: session)
    model.disconnectGrace = 0.3

    func received(_ match: (WatchMessage) -> Bool) -> Bool { probe.messages.contains(where: match) }

    section("launch connects, starts motion and the keep-alive session") {
        check(!model.sessionActive && motion.starts.isEmpty && workout.startCount == 0, "idle before launch")
        model.launch()
        check(model.sessionActive, "session active")
        check(pump { session.isConnected }, "connected: \(session.state)")
        check(session.state == .connected(macName: "Test Mac"), "Mac name")
        check(motion.starts == [100], "motion started at the default rate: \(motion.starts)")
        check(motion.wearing == device.worn && model.wearing == device.worn, "wearing forwarded")
        check(workout.startCount == 1 && model.keepAlive == .starting, "workout requested: \(model.keepAlive)")
        workout.onEvent?(.started)
        check(model.keepAlive == .active("Workout"), "keep-alive active")
        model.launch()
        check(motion.starts.count == 1, "launch runs once")
    }
    section("motion, touch, crown and actions reach the Mac") {
        for i in 0..<6 {
            motion.sink?(SIMD3(0.1 * Double(i), 0, 0), SIMD3(0, 0, 0.01), SIMD3(0, 0, -1), SIMD4(0, 0, 0, 1))
        }
        check(pump { probe.messages.filter { if case .motion = $0 { return true } else { return false } }.count >= 3 },
              "three motion packets of two samples")
        if case .motion(let packet)? = probe.messages.first(where: { if case .motion = $0 { return true } else { return false } }) {
            check(packet.samples.count == 2 && packet.flags.contains(.rightWrist) && packet.flags.contains(.crownLeft),
                  "samples and wearing flags")
        }
        model.handle(.touch(.began, dx: 0, dy: 0))
        model.handle(.touch(.moved, dx: 3, dy: -4))
        model.handle(.action(.screenTap))
        model.handle(.touch(.ended, dx: 0, dy: 0))
        model.crownMoved(turns: 0.5)
        model.perform(.toggleDrag)
        check(pump { received { if case .action(let a) = $0 { return a.code == .toggleDrag } else { return false } } },
              "action from the Actions page")
        check(received { if case .action(let a) = $0 { return a.code == .screenTap } else { return false } }, "screen tap")
        check(received { if case .touch(let t) = $0 { return t.phase == .moved && t.dx == 3 && t.dy == -4 } else { return false } },
              "touch delta")
        check(received { if case .touch(let t) = $0 { return t.phase == .ended } else { return false } }, "touch ended")
        check(received { if case .crown(let c) = $0 { return abs(c.delta - 0.5) < 0.001 } else { return false } }, "crown delta")
    }
    section("haptics play unless muted, and the setting persists") {
        check(model.hapticsEnabled, "on by default")
        server.send(.haptic(.dragStart))
        check(pump { device.played == [.start] }, "played: \(device.played)")
        model.handle(.localHaptic)
        check(device.played == [.start, .click], "local long-press tick")
        model.hapticsEnabled = false
        server.send(.haptic(.success))
        server.send(.state([.engaged, .dragging]))
        check(pump { session.macState == [.engaged, .dragging] }, "Mac state arrives")
        model.handle(.localHaptic)
        check(device.played == [.start, .click], "muted: \(device.played)")
        check(defaults.bool(forKey: "gauntlet.watch.hapticsMuted"), "saved")
        // A second launch: its own services and an unstarted link, sharing only the defaults.
        let spare = FakeDevice()
        let (_, unused) = LoopbackTransport.pair(queue: queue)
        let again = AppModel(
            services: PlatformServices(route: .developerLink(host: "127.0.0.1"), device: spare, haptics: spare,
                                       motion: FakeMotion(), keepAlive: [], isSimulated: true),
            defaults: defaults,
            session: WatchSessionController(deviceName: "Spare", identity: LinkIdentity(), transport: unused, queue: queue))
        check(!again.hapticsEnabled && again.isSimulated && !again.sessionActive, "restored on next launch")
        model.hapticsEnabled = true
    }
    section("a new stream config restarts motion at the new rate") {
        server.send(.config(StreamConfig(sampleRateHz: 50, samplesPerPacket: 1)))
        check(pump { motion.starts.last == 50 }, "restarted: \(motion.starts)")
        check(session.streamConfig.sampleRateHz == 50, "published")
    }
    section("vitals reach the Mac about once a second") {
        device.power = BatteryInfo(percent: 64, charging: true)
        workout.onEvent?(.heartRate(72))
        check(model.heartRate == 72, "heart rate published")
        check(pump(3.5) {
            received {
                if case .status(let s) = $0 {
                    return s.heartRate == 72 && s.battery == 64 && s.flags.contains(.keepAliveActive)
                        && s.flags.contains(.charging) && s.flags.contains(.rightWrist)
                }
                return false
            }
        }, "status with heart rate, battery, keep-alive and charging")
        check(model.battery == BatteryInfo(percent: 64, charging: true), "battery published")
    }
    section("pausing does not stop a running keep-alive session") {
        server.send(.state([.paused]))
        check(pump { session.macState == [.paused] }, "paused")
        check(model.keepAlive == .active("Workout") && workout.stopCount == 0, "still alive")
        server.send(.state([]))
        check(pump { session.macState == [] }, "resumed")
    }
    section("losing the Mac stops motion at once and the keep-alive after the grace period") {
        let stopsBefore = motion.stops
        server.disconnect()
        check(pump { !session.isConnected }, "disconnected: \(session.state)")
        check(pump { motion.stops == stopsBefore + 1 }, "motion stopped")
        check(model.keepAlive == .active("Workout"), "keep-alive survives a short drop-out")
        check(pump(2) { model.keepAlive == .off && workout.stopCount == 1 }, "given up after the grace period: \(model.keepAlive)")
        check(model.sessionActive, "session still wanted")
    }
    section("ending the session stops everything; starting again works") {
        model.endSession()
        check(!model.sessionActive, "ended")
        check(pump { session.state == .idle }, "link idle: \(session.state)")
        model.endSession()
        model.startSession()
        check(model.sessionActive, "active again")
        queue.sync { macSide.start() }
        check(pump { session.isConnected }, "reconnected: \(session.state)")
        check(workout.startCount == 2, "keep-alive requested again")
        workout.onEvent?(.stopped(reason: "Health access denied"))
        check(runtime.startCount == 1, "fallback requested")
        runtime.onEvent?(.started)
        check(model.keepAlive == .active("Runtime") && model.heartRate == nil, "running on the fallback")
        let stops = motion.stops
        model.endSession()
        check(motion.stops == stops + 1 && runtime.stopCount == 1 && model.keepAlive == .off, "all stopped")
    }
    defaults.removePersistentDomain(forName: suiteName)
    queue.sync { server.stop() }
}

func pairingTests() {
    let queue = DispatchQueue(label: "test.pairing")
    let (macSide, watchSide) = LoopbackTransport.pair(queue: queue)
    let server = LinkServer(identity: LinkIdentity(), trust: TrustStore(fileURL: nil), macName: "Studio", queue: queue)
    let radio = RadioLike(macSide)
    server.add(radio)
    server.start()
    let suiteName = "gauntlet.watch.tests.pairing.\(ProcessInfo.processInfo.processIdentifier)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let device = FakeDevice(), motion = FakeMotion(), workout = FakeBackend("Workout", answer: .started)
    let session = WatchSessionController(deviceName: "Test Watch", identity: LinkIdentity(), transport: watchSide, queue: queue)
    let model = AppModel(
        services: PlatformServices(route: .bluetooth, device: device, haptics: device, motion: motion,
                                   keepAlive: [workout], isSimulated: false),
        defaults: defaults, session: session)

    section("first pairing shows a code and streams nothing until the Mac agrees") {
        model.launch()
        var code = ""
        check(pump { if case .awaitingApproval(let c, let mac) = session.state { code = c; return mac == "Studio" }; return false },
              "awaiting approval: \(session.state)")
        check(code.count == 7 && code.filter({ $0.isNumber }).count == 6, "six digits in two groups: '\(code)'")
        check(motion.starts.isEmpty && workout.startCount == 0 && model.rejection == nil, "nothing running yet")
    }
    section("a declined pairing stays on screen until Retry") {
        // What `LinkServer.rejectPairing()` sends. (The server also drops the peer in the same
        // breath, and the in-memory test transport discards messages still queued at that
        // moment, so the verdict is delivered directly here.)
        let verdict = MacMessage.authResult(AuthResult(status: .rejected, proof: Data(count: 32))).encoded()
        queue.sync { radio.send(verdict, reliable: true) }
        check(pump { model.rejection != nil }, "rejection latched: \(session.state)")
        check(model.rejection == "Pairing was declined on the Mac.", "reason: \(model.rejection ?? "nil")")
        pump(for: 0.2)
        check(model.rejection != nil && motion.starts.isEmpty && workout.startCount == 0, "still shown, still idle")
        model.retry()
        check(model.rejection == nil, "cleared by Retry")
        queue.sync { macSide.start() }
        check(pump { if case .awaitingApproval = session.state { return true }; return false }, "asks again: \(session.state)")
    }
    section("approval connects and starts the stream") {
        server.approvePairing()
        check(pump { session.isConnected }, "connected: \(session.state)")
        check(motion.starts.count == 1 && model.keepAlive == .active("Workout") && model.rejection == nil, "streaming")
        model.endSession()
        check(pump { session.state == .idle }, "idle")
    }
    defaults.removePersistentDomain(forName: suiteName)
    queue.sync { server.stop() }
}

@main
enum LogicTests {
    static func main() {
        print("Touch"); touchTests()
        print("Crown"); crownTests()
        print("Mappings"); mappingTests()
        print("Keep-alive"); keepAliveTests()
        print("Virtual motion"); virtualMotionTests()
        print("App model over a loopback link"); appModelTests()
        print("Pairing"); pairingTests()
        print("\n\(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
