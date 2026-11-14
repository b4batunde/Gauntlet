import Foundation
import GauntletProtocol

public enum MouseButton: Int, Sendable, CaseIterable {
    case left, right, middle
}

public enum SystemShortcut: Sendable {
    case missionControl
}

/// Where the engine's output goes: the real macOS cursor, or the Dojo's virtual screen.
/// Methods are called on whichever thread feeds the engine; implementations must be thread-safe.
public protocol PointerSink: AnyObject {
    /// Relative movement in screen points. Positive x is right, positive y is down.
    func movePointer(dx: Double, dy: Double)
    func button(_ button: MouseButton, isDown: Bool, clickCount: Int)
    /// Scroll in pixels. Positive dy scrolls content down (wheel up), positive dx scrolls content right.
    func scroll(dx: Double, dy: Double)
    func shortcut(_ shortcut: SystemShortcut)
}

/// A finger-tap shaped transient seen by the accelerometer, whether or not it passed the thresholds.
public struct TapCandidate: Equatable, Sendable {
    public var time: TimeInterval
    /// High-passed acceleration peak, g.
    public var peak: Double
    /// Background level just before the transient, g.
    public var background: Double
    /// Arm rotation speed at the time, rad/s.
    public var gyro: Double
    /// Whether it was accepted as a tap with the current tuning.
    public var accepted: Bool

    public init(time: TimeInterval, peak: Double, background: Double, gyro: Double, accepted: Bool) {
        self.time = time; self.peak = peak; self.background = background
        self.gyro = gyro; self.accepted = accepted
    }
}

public enum EngineEvent: Sendable {
    /// A gesture was recognised (before its bound action runs).
    case gesture(GestureKind, strength: Double)
    /// An action was performed.
    case action(PointerAction)
    case engagedChanged(Bool)
    case draggingChanged(Bool)
    case scrollModeChanged(Bool)
    case pausedChanged(Bool)
    /// The watch should play this pattern.
    case haptic(HapticPattern)
    /// Raw tap-like transient, for calibration.
    case tapCandidate(TapCandidate)
    /// Raw wrist flick, for calibration. `outward` is relative to the wearing wrist.
    case flickCandidate(outward: Bool, peakRate: Double)
    case streamStarted
    case streamStalled
}

/// Thread-safe view of what the engine currently knows. Cheap to copy; read it as often as you like.
public struct WristSnapshot: Sendable {
    /// True while motion packets are arriving.
    public var streaming = false
    /// Engine clock (seconds) of the most recent packet.
    public var time: TimeInterval = 0

    // Pose of the forearm, derived from gravity and integrated gyro (no magnetometer needed).
    /// Radians, positive = pointing left of where `recenter()` was called.
    public var heading = 0.0
    /// Radians above horizontal.
    public var elevation = 0.0
    /// Radians of wrist twist; 0 = watch face up, positive = face tilting to the wearer's right.
    public var roll = 0.0
    /// False when the forearm is nearly vertical and the pointing frame is undefined.
    public var poseValid = false

    /// Angular rates in the pointing frame, rad/s: x = yaw (left +), y = pitch (up +), z = roll.
    public var rates = SIMD3<Double>.zero
    /// Latest raw sensor values in the device frame.
    public var gyro = SIMD3<Double>.zero
    public var accel = SIMD3<Double>.zero
    public var gravity = SIMD3<Double>(0, 0, -1)
    /// Raw attitude quaternion from the watch (x, y, z, w).
    public var quaternion = SIMD4<Double>(0, 0, 0, 1)

    public var rightWrist = false
    public var crownLeft = false
    public var touching = false

    public var engaged = false
    public var paused = false
    public var dragging = false
    public var scrollMode = false
    /// Pointer velocity the engine is currently emitting, points/s.
    public var pointerVelocity = SIMD2<Double>.zero

    public var packetRate = 0.0
    /// 0...1 fraction of packets lost recently.
    public var packetLoss = 0.0
    public var battery: Int?
    public var heartRate: Int?
    public var rssi = 0

    public var lastGesture: GestureKind?
    public var lastGestureTime: TimeInterval = 0
    /// High-passed acceleration envelope, g. Handy for a live "tap meter".
    public var tapEnvelope = 0.0

    public init() {}
}
