import Foundation
import GauntletProtocol
import GauntletEngine
import GauntletLink
import AVFoundation

/// Engine fed with hand-made gyro traces, for custom gestures and June hooks.
struct TraceRig {
    final class Box: @unchecked Sendable { var events: [EngineEvent] = [] }
    let engine: WristEngine
    let sink = RecordingSink()
    let box = Box()
    var now = 100.0
    private var seq: UInt8 = 0
    private var rng: UInt64 = 0x9E37_79B9_7F4A_7C15
    private var token: ObserverToken?

    init(settings: EngineSettings = EngineSettings()) {
        engine = WristEngine(settings: settings, gestureStore: CustomGestureStore(url: nil))
        engine.sink = sink
        let box = self.box
        token = engine.addObserver { box.events.append($0) }
    }

    var events: [EngineEvent] { box.events }
    mutating func clearEvents() { box.events.removeAll() }

    private mutating func noise() -> Double {
        rng = rng &* 6364136223846793005 &+ 1442695040888963407
        return (Double(rng >> 11) / Double(1 << 53) - 0.5) * 0.1        // +-0.05 rad/s
    }

    mutating func feed(_ seconds: Double, _ gyro: (Double) -> SIMD3<Double>) {
        let dt = 0.01
        let packets = Int((seconds / (2 * dt)).rounded())
        var t = 0.0
        for _ in 0..<packets {
            var samples: [MotionSample] = []
            for _ in 0..<2 {
                let g = gyro(t) + SIMD3(noise(), noise(), noise())
                samples.append(MotionSample(gyro: g, accel: .zero))
                t += dt
            }
            seq &+= 1
            now += 2 * dt
            engine.ingest(.motion(MotionPacket(seq: seq, flags: [], timestampMs: UInt32(now * 1000),
                                               sampleIntervalMs: 10, quaternion: SIMD4(0, 0, 0, 1),
                                               gravity: SIMD3(0, -0.6, -0.8), samples: samples)), now: now)
        }
    }

    mutating func rest(_ seconds: Double) { feed(seconds) { _ in .zero } }

    static func circle(_ scale: Double) -> (Double) -> SIMD3<Double> {
        { (t: Double) -> SIMD3<Double> in
            let phase: Double = 2 * Double.pi * t / 0.5
            let amplitude: Double = 4 * scale
            return SIMD3<Double>(amplitude * sin(phase), amplitude * cos(phase), 0)
        }
    }
    static func shake(_ t: Double) -> SIMD3<Double> {
        let phase: Double = 2 * Double.pi * t / 0.25
        return SIMD3<Double>(0, 0, 6 * sin(phase))
    }

    mutating func perform(_ gesture: (Double) -> SIMD3<Double>) {
        rest(0.1)
        feed(0.5, gesture)
        rest(0.45)
    }

    func samples() -> [(index: Int, accepted: Bool)] {
        events.compactMap { if case .recordingSample(let i, let a, _) = $0 { return (i, a) } else { return nil } }
    }
}

func runCustomGestures() { suite("CustomGestures") {
    test("record three samples, then recognise the gesture and run its action") {
        var rig = TraceRig()
        rig.rest(0.3)
        rig.engine.beginRecording(name: "Circle")
        for k in 0..<3 {
            rig.engine.recordSample()
            rig.perform(TraceRig.circle(1 + 0.08 * Double(k)))
        }
        let recorded = rig.samples()
        expect(recorded.count == 3, "samples: \(recorded)")
        expect(recorded.allSatisfy { $0.accepted })
        guard let gesture = rig.engine.finishRecording(action: .pointer(.missionControl)) else {
            expect(false, "finishRecording returned nil"); return
        }
        expect(rig.engine.customGestureStore.gestures.count == 1)
        expect(gesture.name == "Circle")

        rig.clearEvents()
        rig.engine.armCustomGesture()
        rig.perform(TraceRig.circle(0.9))
        let matched = rig.events.contains { if case .customGestureMatch(let id, _) = $0 { return id == gesture.id } else { return false } }
        expect(matched, "no match event")
        expect(rig.sink.shortcuts == 1, "action did not run")
        expect(rig.events.contains { if case .customGestureArmed(false) = $0 { return true } else { return false } })
    }

    test("a different movement is a miss and runs nothing") {
        var rig = TraceRig()
        rig.rest(0.3)
        rig.engine.beginRecording(name: "Circle")
        for _ in 0..<3 { rig.engine.recordSample(); rig.perform(TraceRig.circle(1)) }
        expect(rig.engine.finishRecording(action: .assistant(.summarize)) != nil)
        rig.clearEvents()
        rig.engine.armCustomGesture()
        rig.perform(TraceRig.shake)
        expect(rig.events.contains { if case .customGestureMiss = $0 { return true } else { return false } })
        expect(!rig.events.contains { if case .assistantRequested = $0 { return true } else { return false } })
    }

    test("a gesture can ask June for a command") {
        var rig = TraceRig()
        rig.rest(0.3)
        rig.engine.beginRecording(name: "Ask")
        for _ in 0..<3 { rig.engine.recordSample(); rig.perform(TraceRig.circle(1)) }
        expect(rig.engine.finishRecording(action: .assistant(.explain)) != nil)
        rig.clearEvents()
        rig.engine.armCustomGesture()
        rig.perform(TraceRig.circle(1))
        expect(rig.events.contains { if case .assistantRequested(.explain) = $0 { return true } else { return false } })
    }

    test("inconsistent samples are rejected, and too few cannot be saved") {
        var rig = TraceRig()
        rig.rest(0.3)
        rig.engine.beginRecording(name: "Mixed")
        rig.engine.recordSample(); rig.perform(TraceRig.circle(1))
        rig.engine.recordSample(); rig.perform(TraceRig.shake)
        let recorded = rig.samples()
        expect(recorded.count == 2)
        expect(recorded.first?.accepted == true && recorded.last?.accepted == false)
        expect(rig.engine.finishRecording(action: .none) == nil)
        expect(rig.engine.customGestureStore.gestures.isEmpty)
        rig.engine.cancelRecording()
        expect(!rig.engine.snapshot().recordingGesture)
    }

    test("arming with no movement times out as a miss") {
        var rig = TraceRig()
        rig.rest(0.3)
        rig.engine.beginRecording(name: "Circle")
        for _ in 0..<3 { rig.engine.recordSample(); rig.perform(TraceRig.circle(1)) }
        _ = rig.engine.finishRecording(action: .none)
        rig.clearEvents()
        rig.engine.armCustomGesture()
        expect(rig.engine.snapshot().customGestureArmed)
        rig.rest(3.0)
        expect(rig.events.contains { if case .customGestureMiss = $0 { return true } else { return false } })
        expect(!rig.engine.snapshot().customGestureArmed)
    }

    test("always-on: a gesture fires without arming and the pointer is put back") {
        var settings = EngineSettings()
        settings.clutch = .always                       // engaged with the arm level
        var rig = TraceRig(settings: settings)
        rig.rest(0.3)
        rig.engine.beginRecording(name: "Circle")
        for _ in 0..<3 { rig.engine.recordSample(); rig.perform(TraceRig.circle(1)) }
        expect(rig.engine.finishRecording(action: .pointer(.missionControl)) != nil)
        rig.engine.customGestureStore.alwaysOn = true
        rig.rest(0.3)
        expect(rig.engine.snapshot().engaged, "rig should be engaged")
        let x0 = rig.sink.x, y0 = rig.sink.y
        rig.clearEvents()
        rig.perform(TraceRig.circle(1))
        expect(rig.events.contains { if case .customGestureMatch = $0 { return true } else { return false } },
               "no match in always-on mode")
        expect(rig.sink.shortcuts == 1, "shortcuts \(rig.sink.shortcuts)")
        let drift = abs(rig.sink.x - x0) + abs(rig.sink.y - y0)
        expect(drift < 60, "pointer not restored, drift \(drift)")
        rig.clearEvents()
        rig.perform(TraceRig.shake)
        expect(!rig.events.contains { if case .customGestureMatch = $0 { return true } else { return false } },
               "shake must not match")
        expect(rig.sink.shortcuts == 1)
    }

    test("arming with no saved gestures is an immediate miss") {
        var rig = TraceRig()
        rig.rest(0.3)
        rig.engine.armCustomGesture()
        expect(rig.events.contains { if case .customGestureMiss = $0 { return true } else { return false } })
        expect(!rig.engine.snapshot().customGestureArmed)
    }

    test("store persists gestures and keeps templates when the UI edits a copy") {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gauntlet-gestures-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CustomGestureStore(url: url)
        var rig = TraceRig()
        rig.rest(0.3)
        rig.engine.beginRecording(name: "Circle")
        for _ in 0..<3 { rig.engine.recordSample(); rig.perform(TraceRig.circle(1)) }
        guard var g = rig.engine.finishRecording(action: .keyCombo(keyCode: 9, modifiers: 1 << 20)) else {
            expect(false); return
        }
        store.update(g)
        g.name = "Renamed"
        g.enabled = false
        store.update(g)
        let reloaded = CustomGestureStore(url: url)
        expect(reloaded.gestures.count == 1)
        expect(reloaded.gestures.first?.name == "Renamed")
        expect(reloaded.gestures.first?.enabled == false)
        expect(reloaded.gestures.first?.action == .keyCombo(keyCode: 9, modifiers: 1 << 20))
    }
} }

func runJuneHooks() { suite("JuneHooks") {
    test("tap interceptor consumes a Double Tap instead of clicking") {
        var rig = TraceRig()
        rig.engine.tapInterceptor = { true }
        rig.engine.ingest(.action(WatchAction(seq: 1, code: .handDoubleTap)), now: rig.now)
        expect(rig.sink.clicks(.left) == 0)
        expect(rig.events.contains { if case .haptic(.success) = $0 { return true } else { return false } })
        rig.engine.tapInterceptor = nil
        rig.engine.ingest(.action(WatchAction(seq: 2, code: .handDoubleTap)), now: rig.now)
        expect(rig.sink.clicks(.left) == 1)
        rig.clearEvents()
    }

    test("watch-face push-to-talk becomes voiceHold events") {
        let rig = TraceRig()
        rig.engine.ingest(.action(WatchAction(seq: 1, code: .voiceHold, argument: 1)), now: rig.now)
        rig.engine.ingest(.action(WatchAction(seq: 2, code: .voiceHold, argument: 0)), now: rig.now)
        let holds = rig.events.compactMap { if case .voiceHold(let down) = $0 { return down } else { return nil } }
        expect(holds == [true, false])
    }

    test("IMA ADPCM round trips speech-like audio") {
        let n = 320
        var pcm: [Int16] = []
        for i in 0..<n {
            let t: Double = Double(i) / 16_000
            let low: Double = 6000 * sin(2 * Double.pi * 220 * t)
            let high: Double = 2500 * sin(2 * Double.pi * 1250 * t)
            pcm.append(Int16(low + high))
        }
        var state = IMAADPCM.State()
        let block = IMAADPCM.encodeBlock(pcm, state: &state)
        expect(block.count == IMAADPCM.blockSize(samples: n))
        let decoded = try IMAADPCM.decodeBlock(block)
        expect(decoded.count == n)
        var err: Double = 0
        var sig: Double = 0
        for (a, b) in zip(pcm, decoded) {
            let d: Double = Double(a) - Double(b)
            let v: Double = Double(a)
            err += d * d
            sig += v * v
        }
        let ratio: Double = sig / Swift.max(err, 1)
        let snr: Double = 10 * log10(ratio)
        expect(snr > 15, "SNR \(snr) dB")
        // A second block continues from the carried state and decodes on its own.
        let block2 = IMAADPCM.encodeBlock(pcm, state: &state)
        let decoded2 = try IMAADPCM.decodeBlock(block2)
        expect(decoded2.count == n)
        expectThrows { _ = try IMAADPCM.decodeBlock(Data([1, 2])) }
    }
} }

func runWatchMicrophone() { suite("WatchMicrophone") {
    final class Counter: @unchecked Sendable { var samples = 0; var buffers = 0 }

    func frame(_ seq: UInt16) -> AudioFrame {
        var pcm: [Int16] = []
        for i in 0..<320 {
            let x: Double = Double(i) * 0.2
            pcm.append(Int16(4000 * sin(x)))
        }
        var state = IMAADPCM.State()
        return AudioFrame(seq: seq, timestampMs: UInt32(seq) * 20, payload: IMAADPCM.encodeBlock(pcm, state: &state))
    }

    test("frames become 16 kHz buffers; small gaps are filled with silence") {
        let mic = WatchMicrophoneSource()
        let counter = Counter()
        var requests: [Bool] = []
        mic.requestAudio = { requests.append($0) }
        mic.setLinkConnected(true)
        try mic.start { counter.samples += Int($0.frameLength); counter.buffers += 1 }
        mic.ingest(frame(1))
        mic.ingest(frame(3))                    // frame 2 lost
        mic.ingest(frame(3))                    // duplicate: dropped
        expect(counter.samples == 3 * 320, "samples \(counter.samples)")
        expect(mic.framesReceived == 2 && mic.framesLost == 1)
        mic.stop()
        expect(requests == [true, false], "requests \(requests)")
    }

    test("reconnect and watch restarts resync the sequence") {
        let mic = WatchMicrophoneSource()
        let counter = Counter()
        mic.setLinkConnected(true)
        try mic.start { _ in counter.buffers += 1 }
        mic.ingest(frame(500)); mic.ingest(frame(501))
        expect(mic.framesReceived == 2)
        // The watch app restarted without the link dropping: its counter is back near 0.
        for seq in UInt16(1)...UInt16(12) { mic.ingest(frame(seq)) }
        expect(mic.framesReceived == 2 + 3, "received \(mic.framesReceived)")
        // A reconnect starts a fresh sequence immediately.
        mic.setLinkConnected(false)
        mic.setLinkConnected(true)
        mic.ingest(frame(0))
        expect(mic.framesReceived == 6)
    }

    test("debug capture writes a WAV even when nobody is listening") {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gauntlet-mic-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let mic = WatchMicrophoneSource()
        var requests: [Bool] = []
        mic.requestAudio = { requests.append($0) }
        mic.setLinkConnected(true)
        mic.recordDebugWAV(seconds: 0.04, to: url) { _ in }
        mic.ingest(frame(1)); mic.ingest(frame(2))
        let data = (try? Data(contentsOf: url)) ?? Data()
        expect(data.count == 44 + 640 * 2, "wav bytes \(data.count)")
        expect(data.prefix(4) == Data("RIFF".utf8))
        expect(requests == [true, false], "requests \(requests)")
    }
} }
