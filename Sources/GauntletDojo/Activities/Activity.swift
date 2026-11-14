import Foundation
import CoreGraphics
import GauntletEngine
import GauntletProtocol

/// Everything an activity may look at during one main-thread pump.
struct ActivityContext {
    var now: TimeInterval
    var cursor: CGPoint
    var snapshot: WristSnapshot
    var settings: EngineSettings
}

/// Things an activity wants the rest of the Dojo to do: 3D effects on the screen and haptics on the wrist.
enum Feedback: Equatable {
    case ripple(CGPoint, Tone)
    case burst(CGPoint, Tone)
    case haptic(HapticPattern)
    case celebrate
}

enum ActivityCommand: String {
    case restart
    case skip
    case flipAxis
}

struct ActivityAction: Equatable, Identifiable {
    var command: ActivityCommand
    var title: String
    var symbol: String
    var prominent = false

    var id: String { command.rawValue }
}

struct StatusMetric: Equatable, Identifiable {
    var label: String
    var value: String
    var tone = Tone.neutral

    var id: String { label }
}

/// One line of the calibration checklist.
struct StatusStep: Equatable, Identifiable {
    enum State { case pending, current, done, skipped }
    var id: Int
    var title: String
    var result = ""
    var state = State.pending
}

/// What the HUD's activity panel shows. Plain data so the panel stays generic.
struct ActivityStatus: Equatable {
    enum Phase { case ready, running, finished }

    var phase = Phase.ready
    var headline = ""
    var detail = ""
    var metrics: [StatusMetric] = []
    var progress: Double?
    var best: String?
    var newBest = false
    var steps: [StatusStep] = []
    /// An honest caveat worth reading (shown highlighted).
    var note: String?
    var noteTone = Tone.warning
    /// How to do this step with the mouse; shown only while the virtual watch is driving.
    var virtualTip: String?
    var actions: [ActivityAction] = []
}

/// The demonstration the ghost arm performs during calibration.
enum GhostDemo: Equatable {
    case hold, raise, sweepHorizontal, sweepVertical, tap, wander, flick
}

/// Something that owns the virtual screen: Free Play, a drill, or the calibration wizard.
///
/// Activities are plain main-thread objects with no view code beyond `draw`, so the self-check
/// can run them headlessly. Time always arrives through the context — never from a wall clock.
class Activity {
    let mode: DojoMode
    /// Set whenever the picture changed; the controller clears it after redrawing.
    var needsRedraw = true
    private var pendingFeedback: [Feedback] = []

    init(mode: DojoMode) { self.mode = mode }

    /// True while the screen shows time-based animation and wants steady redraws.
    var isAnimating: Bool { false }
    var ghostDemo: GhostDemo? { nil }

    func begin(_ context: ActivityContext) {}
    func end(_ context: ActivityContext) {}
    func update(_ context: ActivityContext) {}
    func handle(_ input: SandboxInput, _ context: ActivityContext) {}
    func handle(_ event: EngineEvent, _ context: ActivityContext) {}
    func perform(_ command: ActivityCommand, _ context: ActivityContext) {}
    func status(_ context: ActivityContext) -> ActivityStatus { ActivityStatus() }
    func draw(_ painter: Painter, _ context: ActivityContext) {}
    func autopilotHint(_ context: ActivityContext) -> AutopilotHint { .idle }

    final func emit(_ feedback: Feedback) { pendingFeedback.append(feedback) }

    final func drainFeedback() -> [Feedback] {
        defer { pendingFeedback.removeAll(keepingCapacity: true) }
        return pendingFeedback
    }
}

/// Short-lived text that floats up from where something happened ("+420 ms", "Miss").
struct Floater {
    var text: String
    var origin: CGPoint
    var tone: Tone
    var bornAt: TimeInterval
    static let life = 0.9

    func draw(_ painter: Painter, now: TimeInterval) {
        let age = (now - bornAt) / Self.life
        guard age >= 0, age < 1 else { return }
        let rect = CGRect(x: origin.x - 160, y: origin.y - 30 - CGFloat(age) * 46, width: 320, height: 40)
        painter.text(text, in: rect, size: 28, weight: .bold, color: tone.ns.alpha(CGFloat(1 - age * age)), align: .center)
    }
}

extension Array where Element == Floater {
    mutating func prune(now: TimeInterval) { removeAll { now - $0.bornAt > Floater.life } }
}
