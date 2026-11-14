import Foundation

/// What the Dojo is currently doing.
public enum DojoMode: String, CaseIterable, Identifiable, Sendable {
    case freePlay
    case calibration
    case targets
    case drag
    case scroll
    case simon
    /// Just mirrors the arm while the watch controls the real cursor.
    case live

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .freePlay: return "Free Play"
        case .calibration: return "Calibrate"
        case .targets: return "Target Rush"
        case .drag: return "Drag & Drop"
        case .scroll: return "Scroll Seeker"
        case .simon: return "Gesture Simon"
        case .live: return "Live"
        }
    }

    var symbol: String {
        switch self {
        case .freePlay: return "sparkles"
        case .calibration: return "slider.horizontal.3"
        case .targets: return "scope"
        case .drag: return "hand.draw"
        case .scroll: return "arrow.up.arrow.down"
        case .simon: return "hand.tap"
        case .live: return "dot.radiowaves.left.and.right"
        }
    }

    var blurb: String {
        switch self {
        case .freePlay: return "A sandbox desktop. Try every gesture with nothing at stake."
        case .calibration: return "Fit Gauntlet to your arm in about a minute."
        case .targets: return "Hit targets of different sizes as fast and cleanly as you can."
        case .drag: return "Grab each token and drop it into the matching zone."
        case .scroll: return "Scroll the highlighted row into the focus band."
        case .simon: return "Perform the gesture you are shown, as quickly as you can."
        case .live: return "Your wrist drives the real pointer; the Dojo only mirrors it."
        }
    }

    /// Drills keep score and personal bests.
    var isDrill: Bool {
        switch self {
        case .targets, .drag, .scroll, .simon: return true
        case .freePlay, .calibration, .live: return false
        }
    }

    /// Whether pointer output is routed into the virtual screen.
    var usesSandbox: Bool { self != .live }

    static let drills: [DojoMode] = [.targets, .drag, .scroll, .simon]
}

/// Launch-time choices for hosts that want something other than the defaults.
public struct DojoOptions {
    public var initialMode: DojoMode
    /// Let the built-in autopilot play through the virtual watch (demos, screenshots).
    public var autopilot: Bool
    /// Open with the personal-bests sheet showing.
    public var showStats: Bool

    public init(initialMode: DojoMode = .freePlay, autopilot: Bool = false, showStats: Bool = false) {
        self.initialMode = initialMode
        self.autopilot = autopilot
        self.showStats = showStats
    }
}
