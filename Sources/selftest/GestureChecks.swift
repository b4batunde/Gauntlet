import Foundation
import GauntletProtocol
import GauntletEngine

/// Engine fed with hand-made gyro traces, for custom gestures and June hooks.
struct TraceRig {
    final class Box: @unchecked Sendable { var events: [EngineEvent] = [] }
    let engine = WristEngine(settings: EngineSettings(), gestureStore: CustomGestureStore(url: nil))
    let sink = RecordingSink()
    let box = Box()
    var now = 100.0
    private var seq: UInt8 = 0
    private var rng: UInt64 = 0x9E37_79B9_7F4A_7C15
    private var token: ObserverToken?

    init() {
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
        { t in SIMD3(4 * scale * sin(2 * .pi * t / 0.5), 4 * scale * cos(2 * .pi * t / 0.5), 0) }
    }
    static func shake(_ t: Double) -> SIMD3<Double> { SIMD3(0, 0, 6 * sin(2 * .pi * t / 0.25)) }

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
        let pcm: [Int16] = (0..<n).map { i in
            let t = Double(i) / 16_000
            return Int16(6000 * sin(2 * .pi * 220 * t) + 2500 * sin(2 * .pi * 1250 * t))
        }
        var state = IMAADPCM.State()
        let block = IMAADPCM.encodeBlock(pcm, state: &state)
        expect(block.count == IMAADPCM.blockSize(samples: n))
        let decoded = try IMAADPCM.decodeBlock(block)
        expect(decoded.count == n)
        var err = 0.0, sig = 0.0
        for (a, b) in zip(pcm, decoded) {
            err += pow(Double(a) - Double(b), 2)
            sig += pow(Double(a), 2)
        }
        let snr = 10 * log10(sig / max(err, 1))
        expect(snr > 15, "SNR \(snr) dB")
        // A second block continues from the carried state and decodes on its own.
        let block2 = IMAADPCM.encodeBlock(pcm, state: &state)
        let decoded2 = try IMAADPCM.decodeBlock(block2)
        expect(decoded2.count == n)
        expectThrows { _ = try IMAADPCM.decodeBlock(Data([1, 2])) }
    }
} }
