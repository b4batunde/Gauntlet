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
//
// In the Mac app, enable Settings › Advanced › Developer link first (or launch it with --dev-link).

let arguments = CommandLine.arguments
func value(after flag: String) -> String? {
    guard let i = arguments.firstIndex(of: flag), arguments.indices.contains(i + 1) else { return nil }
    return arguments[i + 1]
}
if arguments.contains("--help") || arguments.contains("-h") {
    print("usage: fakewatch [--demo] [--seconds N] [--right-wrist] [--port N]")
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

    if case .motion(let p) = watch.nextPacket(), let sample = p.samples.first {
        controller.submitMotion(gyro: sample.gyro, accel: sample.accel, gravity: p.gravity, quaternion: p.quaternion)
    }
}
timer.resume()
dispatchMain()
