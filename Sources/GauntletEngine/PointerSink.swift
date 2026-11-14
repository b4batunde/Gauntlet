import Foundation
import GauntletProtocol

public enum MouseButton: Int, Sendable, CaseIterable {
    case left, right, middle
}

public enum SystemShortcut: Equatable, Sendable {
    case missionControl
    /// Press and release a key with modifiers. `modifiers` is a `CGEventFlags.rawValue`.
    case keyCombo(keyCode: UInt16, modifiers: UInt64)
    case openApp(bundleID: String)
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

    // June and custom gestures
    /// Push-to-talk for June: watch-face hold (or a Mac hotkey routed through the engine).
    case voiceHold(isDown: Bool)
    /// Custom-gesture recognition armed (true) or finished (false).
    case customGestureArmed(Bool)
    /// A recording sample finished. `index` is 1-based; rejected samples are not kept.
    /// `quality` is 0...1, how consistent it is with the samples recorded so far.
    case recordingSample(index: Int, accepted: Bool, quality: Double)
    /// A custom gesture was recognised; its action runs right after this event.
    case customGestureMatch(id: UUID, confidence: Double)
    /// Armed, a movement was made, but it matched nothing well enough.
    case customGestureMiss(bestConfidence: Double)
    /// A custom gesture asked June to run a command at the cursor.
    case assistantRequested(AssistantCommand)
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

    /// Custom gestures: waiting for (or capturing) a gesture after `armCustomGesture()`.
    public var customGestureArmed = false
    /// Custom gestures: a movement is being captured right now (recording or armed).
    public var capturingGesture = false
    /// Custom gestures: a recording session is open.
    public var recordingGesture = false
    /// Custom gestures: samples kept so far in the open recording session.
    public var recordingSampleCount = 0

    public init() {}
}
