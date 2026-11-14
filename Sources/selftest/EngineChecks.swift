import Foundation
import GauntletProtocol
import GauntletEngine

final class RecordingSink: PointerSink, @unchecked Sendable {
    var x = 0.0, y = 0.0
    var presses: [(button: MouseButton, down: Bool, count: Int)] = []
    var scrollX = 0.0, scrollY = 0.0
    var shortcuts = 0
    func movePointer(dx: Double, dy: Double) { x += dx; y += dy }
    func button(_ button: MouseButton, isDown: Bool, clickCount: Int) { presses.append((button, isDown, clickCount)) }
    func scroll(dx: Double, dy: Double) { scrollX += dx; scrollY += dy }
    func shortcut(_ shortcut: SystemShortcut) { shortcuts += 1 }
    func clicks(_ b: MouseButton) -> Int { presses.filter { $0.button == b && $0.down }.count }
}

/// Engine + virtual watch wired together with a simulated clock.
struct Rig {
    let engine: WristEngine
    let watch: VirtualWatch
    let sink = RecordingSink()
    var now = 100.0
    var events: [EngineEvent] = []
    private var token: ObserverToken?
    private let box = EventBox()
    final class EventBox: @unchecked Sendable { var events: [EngineEvent] = [] }

    init(rightWrist: Bool = false, crownLeft: Bool = false, settings: EngineSettings = EngineSettings()) {
        engine = WristEngine(settings: settings, gestureStore: CustomGestureStore(url: nil))
        watch = VirtualWatch(seed: 42)
        watch.rightWrist = rightWrist
        watch.crownLeft = crownLeft
        watch.snap(heading: 0, elevation: 0.35)
        engine.sink = sink
        let box = self.box
        token = engine.addObserver { box.events.append($0) }
    }

    var recorded: [EngineEvent] { box.events }

    mutating func run(_ seconds: Double) {
        let packets = Int((seconds / (watch.sampleInterval * Double(watch.samplesPerPacket))).rounded())
        for _ in 0..<packets {
            now += watch.sampleInterval * Double(watch.samplesPerPacket)
            engine.ingest(watch.nextPacket(), now: now)
        }
    }

    mutating func send(_ m: WatchMessage) { engine.ingest(m, now: now) }

    func gestures() -> [GestureKind] {
        recorded.compactMap { if case .gesture(let g, _) = $0 { return g } else { return nil } }
    }
}

func runPointerMapping() { suite("PointerMapping") {
    for (rightWrist, crownLeft) in [(false, false), (true, true), (false, true), (true, false)] {
    test("directions are correct (rightWrist=\(rightWrist), crownLeft=\(crownLeft))") {
        var rig = Rig(rightWrist: rightWrist, crownLeft: crownLeft)
        rig.run(0.5)
        expect(rig.engine.snapshot().engaged)
        expect(abs(rig.engine.snapshot().elevation - 0.35) < 0.02)

        // Swing the arm to the right: cursor goes right.
        let x0 = rig.sink.x, y0 = rig.sink.y
        rig.watch.targetHeading = -0.3
        rig.run(1.0)
        expect(rig.sink.x - x0 > 200)
        expect(abs(rig.sink.y - y0) < 0.15 * (rig.sink.x - x0))
        expect(abs(rig.engine.snapshot().heading - (-0.3)) < 0.03)

        // Raise the arm: cursor goes up (screen y decreases).
        let x1 = rig.sink.x, y1 = rig.sink.y
        rig.watch.targetElevation = 0.6
        rig.run(1.0)
        expect(rig.sink.y - y1 < -150)
        expect(abs(rig.sink.x - x1) < 0.15 * abs(rig.sink.y - y1))
    } }

    test("twisting the wrist barely moves the pointer") {
        var rig = Rig()
        rig.run(0.5)
        let x0 = rig.sink.x, y0 = rig.sink.y
        rig.watch.agility = 6            // a slow, deliberate twist (not a flick)
        rig.watch.targetRoll = 0.9
        rig.run(1.5)
        expect(abs(rig.sink.x - x0) < 25)
        expect(abs(rig.sink.y - y0) < 25)
        expect(abs(rig.engine.snapshot().roll - 0.9) < 0.05)
    }

    test("a steady hand does not drift") {
        var rig = Rig()
        rig.run(0.5)
        let x0 = rig.sink.x, y0 = rig.sink.y
        rig.run(5.0)
        expect(abs(rig.sink.x - x0) < 6)
        expect(abs(rig.sink.y - y0) < 6)
    }

    test("slow movement is finer than fast movement") {
        var slow = Rig(); slow.watch.tremor = 0; slow.run(0.3)
        slow.watch.agility = 2; slow.watch.targetHeading = -0.2; slow.run(4.0)
        var fast = Rig(); fast.watch.tremor = 0; fast.run(0.3)
        fast.watch.agility = 30; fast.watch.targetHeading = -0.2; fast.run(4.0)
        expect(slow.sink.x > 20)
        expect(fast.sink.x > 1.5 * slow.sink.x)
    }
} }

func runClutch() { suite("Clutch") {
    test("lowering the arm releases the pointer") {
        var rig = Rig()
        rig.run(0.4)
        expect(rig.engine.snapshot().engaged)
        rig.watch.targetElevation = -0.15            // down toward the keyboard
        rig.run(0.8)
        expect(!rig.engine.snapshot().engaged)
        let x0 = rig.sink.x
        rig.watch.targetHeading = -0.4
        rig.run(1.0)
        expect(abs(rig.sink.x - x0) < 0.001)
        rig.watch.targetElevation = 0.4              // lift again
        rig.run(0.8)
        expect(rig.engine.snapshot().engaged)
    }

    test("pause stops everything") {
        var rig = Rig()
        rig.run(0.4)
        rig.send(rig.watch.action(.togglePause))
        expect(rig.engine.snapshot().paused)
        let x0 = rig.sink.x
        rig.watch.targetHeading = -0.4
        rig.run(1.0)
        rig.watch.tap()
        rig.run(0.3)
        expect(abs(rig.sink.x - x0) < 0.001)
        expect(rig.sink.presses.isEmpty)
        rig.send(rig.watch.action(.togglePause))
        rig.run(0.3)
        expect(rig.engine.snapshot().engaged)
    }

    test("typing guard holds the pointer") {
        var rig = Rig()
        rig.run(0.4)
        rig.engine.suppressPointer(until: rig.now + 0.6)
        let x0 = rig.sink.x
        rig.watch.targetHeading = -0.3
        rig.run(0.5)
        expect(abs(rig.sink.x - x0) < 0.001)
    }
} }

func runGestures() { suite("Gestures") {
    test("finger tap clicks") {
        var rig = Rig()
        rig.run(0.6)
        rig.watch.tap(strength: 0.4)
        rig.run(0.3)
        expect(rig.gestures() == [.pinchTap])
        expect(rig.sink.clicks(.left) == 1)
        expect(rig.sink.presses.count == 2)          // down + up
    }

    test("two taps make a double click") {
        var rig = Rig()
        rig.run(0.6)
        rig.watch.tap(); rig.run(0.2)
        rig.watch.tap(); rig.run(0.2)
        let downs = rig.sink.presses.filter { $0.down }
        expect(downs.map(\.count) == [1, 2])
    }

    test("weak taps and arm swings do not click") {
        var rig = Rig()
        rig.run(0.6)
        rig.watch.tap(strength: 0.07)
        rig.run(0.3)
        // Big fast sweeps back and forth.
        for i in 0..<6 {
            rig.watch.targetHeading = i % 2 == 0 ? -0.5 : 0.5
            rig.watch.targetElevation = i % 2 == 0 ? 0.6 : 0.2
            rig.run(0.5)
        }
        expect(rig.sink.presses.isEmpty)
    }

    for rightWrist in [false, true] {
    test("flick out right-clicks, flick in grabs (rightWrist=\(rightWrist))") {
        var rig = Rig(rightWrist: rightWrist, crownLeft: rightWrist)
        rig.run(0.6)
        rig.watch.flick(outward: true)
        rig.run(0.5)
        expect(rig.gestures() == [.flickOut])
        expect(rig.sink.clicks(.right) == 1)

        rig.watch.flick(outward: false)
        rig.run(0.5)
        expect(rig.gestures() == [.flickOut, .flickIn])
        expect(rig.engine.snapshot().dragging)
        expect(rig.sink.presses.last?.down == true)

        // Dragging moves the pointer with the button held; losing the stream lets go.
        rig.watch.targetHeading = -0.2
        rig.run(0.6)
        rig.engine.tick(now: rig.now + 2)
        expect(!rig.engine.snapshot().dragging)
        expect(rig.sink.presses.last?.down == false)
    } }

    test("click lands where the user was aiming") {
        var rig = Rig()
        rig.run(0.6)
        rig.watch.tremor = 0
        let before = rig.sink.x
        rig.watch.tap(strength: 0.5)
        rig.run(0.25)
        expect(abs(rig.sink.x - before) < 3)
    }

    test("watch face actions and crown") {
        var rig = Rig()
        rig.run(0.4)
        rig.send(rig.watch.action(.screenTap))
        rig.send(rig.watch.action(.screenLongPress))
        expect(rig.sink.clicks(.left) == 1)
        expect(rig.sink.clicks(.right) == 1)
        rig.send(rig.watch.crown(delta: 0.1))
        expect(rig.sink.scrollY > 50)
        rig.send(rig.watch.touch(.began))
        rig.send(rig.watch.touch(.moved, dx: 10, dy: -4))
        rig.send(rig.watch.touch(.ended))
        expect(rig.sink.x > 20)
    }

    test("tap calibration finds a sensible threshold") {
        let r = GestureCalibrator.tapThreshold(taps: [0.31, 0.28, 0.4, 0.35, 0.3, 0.26], noise: [0.05, 0.06, 0.08, 0.05])
        expect(r.usable)
        expect(r.threshold > 0.09 && r.threshold < 0.27)
    }
} }

func runWireFormat() { suite("WireFormat") {
    test("motion round trips") {
        let watch = VirtualWatch(seed: 7)
        watch.samplesPerPacket = 3
        guard case .motion(let original) = watch.nextPacket() else { expect(false, "not motion"); return }
        let data = WatchMessage.motion(original).encoded()
        expect(data.count == Wire.motionHeaderSize + 3 * Wire.motionSampleSize)
        guard case .motion(let decoded) = try WatchMessage.decode(data) else { expect(false, "not motion"); return }
        expect(decoded.seq == original.seq)
        expect(decoded.samples.count == 3)
        for (a, b) in zip(decoded.samples, original.samples) {
            expect(abs(a.gyro.x - b.gyro.x) < 0.002 && abs(a.accel.z - b.accel.z) < 0.001)
        }
        expect(abs(decoded.gravity.z - original.gravity.z) < 0.001)
        expect(abs(decoded.quaternion.w - original.quaternion.w) < 0.001)
    }

    test("every message round trips") {
        let id = Data((0..<16).map { UInt8($0) }), key = Data((0..<32).map { UInt8(200 - $0) })
        let watchMessages: [WatchMessage] = [
            .touch(TouchEvent(seq: 3, phase: .moved, dx: 2.5, dy: -1.25)),
            .crown(CrownEvent(seq: 4, delta: -0.5)),
            .action(WatchAction(seq: 5, code: .handDoubleTap)),
            .status(WatchStatus(seq: 6, battery: 77, heartRate: nil, flags: [.rightWrist], rssi: -60, sampleRateHz: 100)),
            .hello(Hello(deviceID: id, publicKey: key, name: "Ayush’s Watch")),
            .authProof(key), .bye,
            .action(WatchAction(seq: 7, code: .voiceHold, argument: 1)),
            .action(WatchAction(seq: 8, code: .armGesture)),
            .audio(AudioFrame(seq: 65_000, timestampMs: 123_456, payload: Data([0x10, 0x00, 0x05, 0xAB, 0xCD]))),
        ]
        for m in watchMessages { expect(try WatchMessage.decode(m.encoded()) == m) }
        let macMessages: [MacMessage] = [
            .haptic(.dragStart), .state([.engaged, .sandbox]), .config(StreamConfig(sampleRateHz: 100, samplesPerPacket: 2)), .ping,
            .helloAck(HelloAck(deviceID: id, publicKey: key, nonce: id, known: true, name: "MacBook")),
            .authResult(AuthResult(status: .pendingApproval, proof: key)),
            .assistantState(.listening), .audioRequest(true), .audioRequest(false),
        ]
        for m in macMessages { expect(try MacMessage.decode(m.encoded()) == m) }
    }

    test("garbage is rejected not crashed") {
        expectThrows { _ = try WatchMessage.decode(Data()) }
        expectThrows { _ = try WatchMessage.decode(Data([0x01, 0x02])) }
        expectThrows { _ = try WatchMessage.decode(Data([0x7f, 0x00])) }
        expectThrows { _ = try MacMessage.decode(Data([0x90, 0x01, 0x02])) }
    }
} }

/// Conditions a real Bluetooth link produces that a clean simulation does not.
func runRobustness() { suite("Robustness") {
    /// Feeds `seconds` of motion, optionally dropping packets or delivering them in bursts.
    func feed(_ rig: inout Rig, seconds: Double, dropEvery: Int = 0, burst: Int = 1) {
        let step = rig.watch.sampleInterval * Double(rig.watch.samplesPerPacket)
        let packets = Int((seconds / step).rounded())
        var held: [WatchMessage] = []
        for i in 0..<packets {
            rig.now += step
            let packet = rig.watch.nextPacket()
            if dropEvery > 0, i % dropEvery == dropEvery - 1 { continue }
            held.append(packet)
            if held.count >= burst {
                for p in held { rig.engine.ingest(p, now: rig.now) }
                held.removeAll()
            }
        }
        for p in held { rig.engine.ingest(p, now: rig.now) }
    }

    func sweepDistance(dropEvery: Int = 0, burst: Int = 1) -> (distance: Double, presses: Int, gestures: Int) {
        var rig = Rig()
        feed(&rig, seconds: 0.5, dropEvery: dropEvery, burst: burst)
        rig.watch.targetHeading = -0.3
        rig.watch.targetElevation = 0.5
        feed(&rig, seconds: 1.5, dropEvery: dropEvery, burst: burst)
        rig.watch.targetHeading = 0.2
        feed(&rig, seconds: 1.5, dropEvery: dropEvery, burst: burst)
        return ((rig.sink.x * rig.sink.x + rig.sink.y * rig.sink.y).squareRoot(), rig.sink.presses.count, rig.gestures().count)
    }

    test("one packet in five lost: pointer still tracks and nothing clicks by accident") {
        let clean = sweepDistance()
        let lossy = sweepDistance(dropEvery: 5)
        expect(clean.distance > 100)
        expect(lossy.presses == 0 && lossy.gestures == 0, "no phantom gestures under loss")
        expect(abs(lossy.distance - clean.distance) < 0.4 * clean.distance,
               "lossy \(Int(lossy.distance)) vs clean \(Int(clean.distance))")
    }

    test("packets arriving in bursts of five behave like a steady stream") {
        let clean = sweepDistance()
        let bursty = sweepDistance(burst: 5)
        expect(bursty.presses == 0 && bursty.gestures == 0, "no phantom gestures from jitter")
        expect(abs(bursty.distance - clean.distance) < 0.1 * clean.distance,
               "bursty \(Int(bursty.distance)) vs clean \(Int(clean.distance))")
    }

    test("taps are still recognised when packets arrive in bursts") {
        var rig = Rig()
        feed(&rig, seconds: 0.6, burst: 4)
        rig.watch.tap(strength: 0.4)
        feed(&rig, seconds: 0.4, burst: 4)
        expect(rig.sink.clicks(.left) == 1, "clicks: \(rig.sink.clicks(.left))")
    }

    test("a 50 Hz stream with one sample per packet works too") {
        var rig = Rig()
        rig.watch.sampleInterval = 0.02
        rig.watch.samplesPerPacket = 1
        rig.run(0.5)
        expect(rig.engine.snapshot().engaged)
        rig.watch.targetHeading = -0.3
        rig.run(1.0)
        expect(rig.sink.x > 200, "x=\(rig.sink.x)")
        rig.watch.flick(outward: true)
        rig.run(0.5)
        expect(rig.sink.clicks(.right) == 1)
    }

    test("a stalled link pauses cleanly and resumes without a jump") {
        var rig = Rig()
        rig.run(0.5)
        rig.watch.targetHeading = -0.2
        rig.run(0.2)
        let before = rig.sink.x
        rig.now += 3                                  // radio silence
        rig.engine.tick(now: rig.now)
        expect(!rig.engine.snapshot().streaming && !rig.engine.snapshot().engaged)
        for _ in 0..<150 { _ = rig.watch.nextPacket() }   // the arm kept moving while we were deaf
        rig.run(0.3)
        expect(rig.engine.snapshot().streaming && rig.engine.snapshot().engaged)
        expect(abs(rig.sink.x - before) < 60, "no catch-up jump: moved \(rig.sink.x - before)")
    }

    test("holding the arm straight up or straight down never produces wild movement") {
        var rig = Rig()
        rig.run(0.4)
        rig.watch.agility = 6
        rig.watch.targetElevation = 1.45              // nearly vertical
        rig.run(1.5)
        let x0 = rig.sink.x, y0 = rig.sink.y
        rig.watch.targetHeading = 1.0                 // spinning about the vertical forearm
        rig.run(1.0)
        expect(abs(rig.sink.x - x0) < 400 && abs(rig.sink.y - y0) < 400)
        rig.watch.targetElevation = -1.45             // hanging at the side
        rig.run(2.0)
        expect(!rig.engine.snapshot().engaged, "arm down releases")
    }
} }
