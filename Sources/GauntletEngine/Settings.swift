import Foundation

/// Something the wearer can do that the engine recognises.
public enum GestureKind: String, Codable, CaseIterable, Sendable {
    /// Thumb-to-finger tap, detected from the accelerometer transient.
    case pinchTap
    /// Fast wrist twist outward (thumb rolling up) and back.
    case flickOut
    /// Fast wrist twist inward and back.
    case flickIn
    /// watchOS system "Double Tap" finger gesture.
    case handDoubleTap
    case screenTap
    case screenDoubleTap
    case screenLongPress
    /// Holding the pointer still.
    case dwell

    public var title: String {
        switch self {
        case .pinchTap: return "Finger tap"
        case .flickOut: return "Wrist flick out"
        case .flickIn: return "Wrist flick in"
        case .handDoubleTap: return "Double Tap (system)"
        case .screenTap: return "Tap watch face"
        case .screenDoubleTap: return "Double-tap watch face"
        case .screenLongPress: return "Long-press watch face"
        case .dwell: return "Hold still (dwell)"
        }
    }

    public var symbol: String {
        switch self {
        case .pinchTap: return "hand.pinch"
        case .flickOut: return "arrow.clockwise"
        case .flickIn: return "arrow.counterclockwise"
        case .handDoubleTap: return "hand.tap"
        case .screenTap: return "applewatch"
        case .screenDoubleTap: return "applewatch.radiowaves.left.and.right"
        case .screenLongPress: return "applewatch.watchface"
        case .dwell: return "timer"
        }
    }
}

/// What a gesture makes the Mac do.
public enum PointerAction: String, Codable, CaseIterable, Sendable {
    case none
    case leftClick
    case rightClick
    case doubleClick
    case middleClick
    case toggleDrag
    case toggleScrollMode
    case toggleEngage
    case missionControl

    public var title: String {
        switch self {
        case .none: return "Nothing"
        case .leftClick: return "Click"
        case .rightClick: return "Right-click"
        case .doubleClick: return "Double-click"
        case .middleClick: return "Middle-click"
        case .toggleDrag: return "Grab / release (drag)"
        case .toggleScrollMode: return "Air-scroll on/off"
        case .toggleEngage: return "Pause / resume"
        case .missionControl: return "Mission Control"
        }
    }
}

/// When the pointer follows the arm.
public enum ClutchMode: String, Codable, CaseIterable, Sendable {
    /// Always, except when the arm hangs down.
    case always
    /// Only while the forearm is lifted toward the screen; lowering it to the keyboard releases.
    case raiseToPoint

    public var title: String {
        switch self {
        case .always: return "Always on"
        case .raiseToPoint: return "Raise to point"
        }
    }
}

public struct GestureTuning: Codable, Equatable, Sendable {
    public var tapEnabled = true
    /// Minimum high-passed acceleration peak, in g.
    public var tapThreshold = 0.16
    /// The peak must stand this many times above the recent background.
    public var tapQuietRatio = 3.5
    /// Taps are ignored while the arm rotates faster than this (rad/s).
    public var tapMaxGyro = 2.5

    public var flickEnabled = true
    /// Roll rate that starts a flick, rad/s.
    public var flickRate = 5.0
    /// Minimum outbound twist, rad.
    public var flickMinAngle = 0.22

    public var dwellEnabled = false
    public var dwellTime = 0.9
    public var dwellRadius = 14.0

    public init() {}
}

public struct EngineSettings: Codable, Equatable, Sendable {
    // Pointer feel
    /// User-facing speed multiplier.
    public var sensitivity = 1.0
    /// Pixels per radian of arm rotation at cruising speed.
    public var baseGain = 2200.0
    /// Gain multiplier for very slow movement (fine positioning).
    public var precisionMultiplier = 0.35
    /// Gain multiplier for fast sweeps.
    public var boostMultiplier = 2.4
    /// Angular speed (rad/s) at which the boost is fully applied.
    public var boostSpeed = 3.0
    /// Rotation slower than this (rad/s) is treated as stillness.
    public var deadZone = 0.012
    /// 0 = raw, 1 = heavily smoothed.
    public var smoothing = 0.5
    public var invertX = false
    public var invertY = false

    // Wearing
    /// Set by calibration when the default guess for "toward the hand" is backwards.
    public var forearmAxisFlipped = false
    public var calibrated = false

    // Clutch
    public var clutch = ClutchMode.raiseToPoint
    /// Forearm elevation (degrees above horizontal) that engages in raise-to-point mode.
    public var raiseAngleDeg = 8.0
    /// Below this elevation the arm is considered to be resting at the wearer's side.
    public var restAngleDeg = -45.0

    // Scrolling & touch
    /// Pixels per Digital Crown unit.
    public var crownScrollGain = 900.0
    /// Pixels per radian in air-scroll mode.
    public var airScrollGain = 1500.0
    public var scrollInverted = false
    /// Pointer pixels per watch point when using the display as a trackpad.
    public var touchGain = 2.4

    public var hapticsEnabled = true
    public var gestures = GestureTuning()
    private var bindingTable: [String: PointerAction] = EngineSettings.defaultBindings

    public init() {}

    static let defaultBindings: [String: PointerAction] = [
        GestureKind.pinchTap.rawValue: .leftClick,
        GestureKind.flickOut.rawValue: .rightClick,
        GestureKind.flickIn.rawValue: .toggleDrag,
        GestureKind.handDoubleTap.rawValue: .leftClick,
        GestureKind.screenTap.rawValue: .leftClick,
        GestureKind.screenDoubleTap.rawValue: .doubleClick,
        GestureKind.screenLongPress.rawValue: .rightClick,
        GestureKind.dwell.rawValue: .leftClick,
    ]

    public func action(for gesture: GestureKind) -> PointerAction {
        bindingTable[gesture.rawValue] ?? .none
    }

    public mutating func setAction(_ action: PointerAction, for gesture: GestureKind) {
        bindingTable[gesture.rawValue] = action
    }

    // MARK: Persistence

    public static func load(from defaults: UserDefaults = .standard, key: String = "engineSettings") -> EngineSettings {
        guard let data = defaults.data(forKey: key),
              let s = try? JSONDecoder().decode(EngineSettings.self, from: data) else { return EngineSettings() }
        return s
    }

    public func save(to defaults: UserDefaults = .standard, key: String = "engineSettings") {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: key) }
    }
}
