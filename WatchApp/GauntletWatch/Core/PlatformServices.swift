import Foundation
import GauntletWatchCore

// Everything the app needs from the watch itself, behind small protocols.
//
// The app model and the views only see these; the WatchKit / CoreMotion / HealthKit
// implementations live in the `Watch` folder. That keeps almost all of the app
// compilable and testable on a Mac without the watchOS SDK.

/// One fused IMU sample: rotation rate (rad/s), user acceleration (g), gravity (unit vector),
/// attitude quaternion (x, y, z, w). Called on the source's own queue.
typealias MotionSink = (_ gyro: SIMD3<Double>, _ accel: SIMD3<Double>,
                        _ gravity: SIMD3<Double>, _ quaternion: SIMD4<Double>) -> Void

protocol MotionSource: AnyObject {
    /// `nil` when the sensors work; otherwise a short reason for the Status page.
    var unavailableReason: String? { get }
    /// Starts delivery at `rateHz`, or restarts it at a new rate. Call on the main thread.
    func start(rateHz: Int, sink: @escaping MotionSink)
    func stop()
    /// Lets a simulated source produce data for the same wrist the app reports.
    func setWearing(_ wearing: WearingInfo)
}

extension MotionSource {
    func setWearing(_ wearing: WearingInfo) {}
}

enum KeepAliveEvent: Equatable {
    /// The backend is now keeping the app running.
    case started
    /// The backend is not running: it could not start, was denied, expired or failed.
    case stopped(reason: String?)
    case heartRate(Int)
}

/// One way of keeping the app running while the wrist is down and the display is dimmed.
/// All methods are called on the main thread, and `onEvent` must be called on it.
protocol KeepAliveBackend: AnyObject {
    /// Shown on the Status page while this backend is active.
    var name: String { get }
    var onEvent: ((KeepAliveEvent) -> Void)? { get set }
    /// Must answer with `.started` or `.stopped`, sooner or later.
    func start()
    /// Stops quietly; no event is expected afterwards.
    func stop()
}

/// The watch microphone, for June. Delivers 16 kHz mono PCM on its own queue.
/// Call `start` and `stop` on the main thread.
protocol MicrophoneSource: AnyObject {
    /// `nil` when the mic can be used; otherwise a short reason for the Status page.
    var unavailableReason: String? { get }
    var isRunning: Bool { get }
    /// Asks for permission if needed and starts the mic. `completion` runs on the main thread with
    /// `nil` once audio is flowing, or a reason it could not start (for example, the app was in the
    /// background: watchOS only lets a recording start in the foreground; once running it continues).
    func start(sink: @escaping ([Int16]) -> Void, completion: @escaping (String?) -> Void)
    func stop()
}

protocol HapticPlayer: AnyObject {
    func play(_ tone: HapticTone)
}

struct WearingInfo: Equatable {
    var rightWrist: Bool
    /// The Digital Crown is on the left edge of the display as worn.
    var crownLeft: Bool

    var summary: String {
        (rightWrist ? "Right wrist" : "Left wrist") + ", crown " + (crownLeft ? "left" : "right")
    }
}

struct BatteryInfo: Equatable {
    /// 0...100, or nil when unknown.
    var percent: Int?
    var charging: Bool
}

protocol DeviceProbe: AnyObject {
    var deviceName: String { get }
    func wearing() -> WearingInfo
    func battery() -> BatteryInfo
}

/// The set of platform services one run of the app uses.
struct PlatformServices {
    var route: WatchSessionController.Route
    var device: DeviceProbe
    var haptics: HapticPlayer
    var motion: MotionSource
    /// In order of preference; the next one is tried when one cannot run.
    var keepAlive: [KeepAliveBackend]
    /// True in the simulator, where motion is synthetic and the link is the developer link.
    var isSimulated: Bool
    /// The microphone June listens through, when the Mac asks for it. Nil = no mic support.
    var microphone: MicrophoneSource? = nil
}
