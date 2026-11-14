import Foundation
import Combine
import GauntletProtocol
import GauntletLink
import GauntletWatchCore
import GauntletEngine

// A simulated Apple Watch for testing the Mac app end to end without hardware.
// It speaks the real protocol (pairing included) over the Mac app's developer link.
//
//   swift run fakewatch                 gentle figure-eight pointing (movement only)
//   swift run fakewatch --demo          full routine: point, tap, double-tap, flick, drag, scroll
//   swift run fakewatch --seconds 20    stop after 20 s
//   swift run fakewatch --right-wrist   pretend to be worn on the right wrist
//   swift run fakewatch --audio hey.wav when the Mac opens the watch mic (June), stream this
//                                       16 kHz mono 16-bit WAV in a loop; without it, quiet noise
//
// In the Mac app, enable Settings › Advanced › Developer link first (or launch it with --dev-link).

let arguments = CommandLine.arguments
func value(after flag: String) -> String? {
    guard let i = arguments.firstIndex(of: flag), arguments.indices.contains(i + 1) else { return nil }
    return arguments[i + 1]
}
if arguments.contains("--help") || arguments.contains("-h") {
    print("usage: fakewatch [--demo] [--seconds N] [--right-wrist] [--port N] [--audio file.wav]")
    exit(0)
}
let demo = arguments.contains("--demo")
let limit = value(after: "--seconds").flatMap(Double.init)
let port = value(after: "--port").flatMap(UInt16.init) ?? Wire.devLinkPort

let queue = DispatchQueue(label: "fakewatch.link", qos: .userInteractive)
let defaults = UserDefaults(suiteName: "dev.sunhacks.gauntlet.fakewatch") ?? .standard
let controller = WatchSessionController(
    deviceName: value(after: "--name") ?? "Virtual Apple Watch",
    identity: LinkIdentity.loadOrCreate(defaults: defaults),
    transport: TCPClientTransport(port: port, queue: queue),
    queue: queue)

let watch = VirtualWatch()
watch.samplesPerPacket = 1
watch.rightWrist = arguments.contains("--right-wrist")
watch.crownLeft = watch.rightWrist
watch.snap(heading: 0, elevation: -0.15)
controller.setWearing(rightWrist: watch.rightWrist, crownLeft: watch.crownLeft)
controller.setVitals(battery: 82, heartRate: 68, keepAliveActive: true, charging: false)

var subscriptions = Set<AnyCancellable>()
controller.$state.removeDuplicates().sink { state in
    switch state {
    case .idle: break
    case .searching(let why): print("… \(why)")
    case .handshaking: print("… securing connection")
    case .awaitingApproval(let code, let mac): print("⌚︎ pairing code \(code) — confirm it in Gauntlet on \(mac)")
    case .connected(let mac): print("✓ connected to \(mac)\(demo ? " — running the full demo (this clicks!)" : " — pointing only; pass --demo for clicks and gestures")")
    case .rejected(let why): print("✗ \(why)")
    }
}.store(in: &subscriptions)
controller.$macState.removeDuplicates().dropFirst().sink { flags in
    var words: [String] = []
    if flags.contains(.engaged) { words.append("engaged") }
    if flags.contains(.dragging) { words.append("dragging") }
    if flags.contains(.scrollMode) { words.append("air-scroll") }
    if flags.contains(.paused) { words.append("paused") }
    if flags.contains(.sandbox) { words.append("sandbox") }
    if flags.contains(.needsCalibration) { words.append("needs-calibration") }
    print("  mac state: \(words.isEmpty ? "released" : words.joined(separator: ", "))")
}.store(in: &subscriptions)
controller.onHaptic = { print("  haptic: \($0)") }

// Microphone: what the watch sends when June asks for audio.
func loadWAV(_ path: String) -> [Int16]? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count > 44 else { return nil }
    let bytes = [UInt8](data)
    func u32(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24 }
    func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
    var i = 12, channels = 0, rate = 0, bits = 0
    while i + 8 <= bytes.count {
        let id = String(decoding: bytes[i..<(i + 4)], as: UTF8.self), size = u32(i + 4)
        if id == "fmt " { channels = u16(i + 10); rate = u32(i + 12); bits = u16(i + 22) }
        if id == "data" {
            guard channels == 1, rate == 16_000, bits == 16 else {
                print("✗ \(path): need 16 kHz mono 16-bit PCM (got \(rate) Hz, \(channels) ch, \(bits) bit)")
                return nil
            }
            let end = min(bytes.count, i + 8 + size)
            return stride(from: i + 8, to: end - 1, by: 2).map { Int16(bitPattern: UInt16(u16($0))) }
        }
        i += 8 + size + (size & 1)
    }
    return nil
}
let audioClip: [Int16]? = value(after: "--audio").flatMap(loadWAV)
var audioOn = false
var audioCursor = 0
var noiseSeed: UInt32 = 1
controller.onAudioRequest = { on in
    audioOn = on
    audioCursor = 0
    let source = audioClip == nil ? "quiet noise; pass --audio file.wav for speech" : "looping --audio clip"
    print("  mac \(on ? "opened" : "closed") the watch mic\(on ? " (\(source))" : "")")
}
controller.onAssistantState = { print("  june: \($0)") }
controller.start()

// The choreography, on a 14-second loop. Times are seconds into the loop.
var fired = Set<Int>()
func once(_ id: Int, at time: Double, now: Double, _ body: () -> Void) {
    if now >= time, !fired.contains(id) { fired.insert(id); body() }
}

let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "fakewatch.sensor", qos: .userInteractive))
var elapsed = 0.0
var connectedFor = 0.0
timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
timer.setEventHandler {
    elapsed += 0.01
    if let limit, elapsed >= limit { controller.stop(); usleep(200_000); exit(0) }
    guard controller.isConnected else { connectedFor = 0; fired.removeAll(); return }
    connectedFor += 0.01
    let t = connectedFor.truncatingRemainder(dividingBy: 14)
    if t < 0.02 { fired.removeAll() }

    if t < 1 {
        watch.targetElevation = -0.15; watch.targetHeading = 0                 // resting on the desk
    } else if t < 2 {
        watch.targetElevation = 0.35                                            // lift to point
    } else if t < 6 {
        let phase = (t - 2) / 4 * 2 * Double.pi
        watch.targetHeading = 0.22 * sin(phase)
        watch.targetElevation = 0.35 + 0.10 * sin(2 * phase)
    } else if t < 12.5 {
        watch.targetHeading = demo && t > 9.2 && t < 10.5 ? -0.15 : 0
        watch.targetElevation = 0.35
    } else {
        watch.targetElevation = -0.15                                           // lower to release
    }
    if demo {
        once(1, at: 6.3, now: t) { watch.tap() }
        once(2, at: 7.0, now: t) { watch.tap() }
        once(3, at: 7.25, now: t) { watch.tap() }
        once(4, at: 8.0, now: t) { watch.flick(outward: true) }
        once(5, at: 9.0, now: t) { watch.flick(outward: false) }
        once(6, at: 10.6, now: t) { watch.flick(outward: false) }
        if t > 11, t < 11.5 { controller.sendCrown(delta: 0.004) }
        if t > 11.5, t < 12 { controller.sendCrown(delta: -0.004) }
    }

    if audioOn {
        var chunk = [Int16](repeating: 0, count: 160)                   // 10 ms at 16 kHz
        if let clip = audioClip, !clip.isEmpty {
            let gap = 16_000                                            // 1 s of silence between loops
            for k in 0..<chunk.count {
                let pos = (audioCursor + k) % (clip.count + gap)
                chunk[k] = pos < clip.count ? clip[pos] : 0
            }
        } else {
            for k in 0..<chunk.count {
                noiseSeed = noiseSeed &* 1_664_525 &+ 1_013_904_223
                chunk[k] = Int16(truncatingIfNeeded: Int32(noiseSeed >> 16) % 200 - 100)
            }
        }
        audioCursor += chunk.count
        controller.submitAudio(chunk)
    }

    if case .motion(let p) = watch.nextPacket(), let sample = p.samples.first {
        controller.submitMotion(gyro: sample.gyro, accel: sample.accel, gravity: p.gravity, quaternion: p.quaternion)
    }
}
timer.resume()
dispatchMain()
