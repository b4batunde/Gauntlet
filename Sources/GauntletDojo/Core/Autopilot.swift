import Foundation
import CoreGraphics
import GauntletEngine
import GauntletProtocol

enum VirtualPosture: Equatable {
    /// Forearm lifted toward the screen, steered by `heading` / `elevation`.
    case pointing
    /// Resting below the clutch angle (pointer released).
    case dropped
    /// Pointing at the ceiling.
    case raised
}

/// What a puppeteer — the mouse or the autopilot — asks the simulated arm to do.
struct VirtualControls {
    static let neutralElevation = 0.45
    static let droppedElevation = -0.6
    static let raisedElevation = 1.2
    static let elevationRange = 0.17...0.80
    static let headingSpan = 1.0

    var heading = 0.0
    var elevation = VirtualControls.neutralElevation
    var posture = VirtualPosture.pointing
    var tap = false
    var flicks: [Bool] = []
    var crown = 0.0
    var actions: [WatchActionCode] = []

    /// Pushes the controls into the simulated watch. Returns the discrete messages to send after its next packet.
    mutating func apply(to watch: VirtualWatch) -> [WatchMessage] {
        watch.targetHeading = heading
        switch posture {
        case .pointing: watch.targetElevation = elevation
        case .dropped: watch.targetElevation = Self.droppedElevation
        case .raised: watch.targetElevation = Self.raisedElevation
        }
        if tap { watch.tap(strength: 0.42); tap = false }
        if !flicks.isEmpty { watch.flick(outward: flicks.removeFirst()) }
        var messages: [WatchMessage] = []
        if abs(crown) > 1e-5 { messages.append(watch.crown(delta: crown)); crown = 0 }
        for code in actions { messages.append(watch.action(code)) }
        actions.removeAll()
        return messages
    }
}

enum ClickKind: Equatable { case left, right, double }

/// What a perfect player would do next; each activity describes it, the autopilot performs it.
enum AutopilotHint: Equatable {
    case idle
    case click(at: CGPoint, ClickKind)
    /// Move there and grab (flick in).
    case grab(at: CGPoint)
    /// Carry the grabbed thing there and let go.
    case carry(to: CGPoint)
    /// Let go of whatever is held.
    case release
    /// Scroll until the sink has received this many more pixels of `dy`.
    case scroll(dy: Double)
    /// Perform a gesture; `serial` changes when the same gesture is wanted again.
    case gesture(GestureKind, serial: Int)
    /// Hold an absolute arm pose (radians); nil keeps the current value.
    case pose(heading: Double?, elevation: Double?)
    case raise
    case wander
}

/// Plays the Dojo through the virtual watch the way a person would: aim, settle, gesture.
/// Used for the demo mode, the scripted screenshots and the headless self-check.
struct Autopilot {
    struct Context {
        var cursor: CGPoint
        var engaged: Bool
        var dragging: Bool
        /// Sink pixels of `dy` per Digital Crown unit (signed).
        var crownPixelsPerUnit: Double
    }

    private var hint = AutopilotHint.idle
    private var elapsed = 0.0
    private var settled = 0.0
    private var fired = false
    private var sinceFire = 0.0
    private var secondTapIn: Double?
    private var recovery: (kind: Recovery, phase: Int, time: Double)?
    private var clock = 0.0

    /// What to do when the arm runs out of comfortable range before the pointer reaches its goal.
    /// The pointer is relative and its gain depends on speed, so arm and pointer drift apart —
    /// people fix that without thinking, in exactly these two ways.
    private enum Recovery {
        /// No room left below: raise the arm until the pointer pins against the top edge, then come down again.
        case liftToTop
        /// No room left above or to the side: lower the arm to let go, bring it back, pick the pointer up again.
        case regrip(recentre: Bool)
    }

    mutating func step(dt: Double, hint newHint: AutopilotHint, context: Context, controls: inout VirtualControls) {
        clock += dt
        if newHint != hint {
            // Small corrections to a moving goal keep the settle timer; a new goal starts over.
            if !Self.sameGoal(hint, newHint) { elapsed = 0; settled = 0; fired = false; sinceFire = 0 }
            hint = newHint
        }
        elapsed += dt
        if fired { sinceFire += dt }

        if let delay = secondTapIn {
            if delay <= 0 { controls.tap = true; secondTapIn = nil } else { secondTapIn = delay - dt }
        }
        if runRecovery(dt: dt, controls: &controls) { return }

        switch hint {
        case .idle:
            break

        case .click(let point, let kind):
            controls.posture = .pointing
            aim(at: point, dt: dt, context: context, controls: &controls)
            if ready(context), !fired {
                switch kind {
                case .left: controls.tap = true
                case .right: controls.flicks.append(true)
                case .double: controls.tap = true; secondTapIn = 0.2
                }
                markFired()
            }
            retry(after: 1.2)

        case .grab(let point):
            controls.posture = .pointing
            aim(at: point, dt: dt, context: context, controls: &controls)
            if ready(context), !fired, !context.dragging { controls.flicks.append(false); markFired() }
            retry(after: 1.2)

        case .carry(let point):
            controls.posture = .pointing
            aim(at: point, dt: dt, context: context, controls: &controls)
            if ready(context), !fired, context.dragging { controls.flicks.append(false); markFired() }
            retry(after: 1.2)

        case .release:
            if elapsed > 0.3, !fired, context.dragging { controls.flicks.append(false); markFired() }
            retry(after: 1.2)

        case .scroll(let dy):
            controls.posture = .pointing
            guard abs(context.crownPixelsPerUnit) > 1, elapsed > 0.3 else { break }
            // Fast when far away, easing in so the target row is not overshot.
            let pixels = (dy * 5 * dt).clamped(-26, 26)
            controls.crown += pixels / context.crownPixelsPerUnit

        case .gesture(let kind, _):
            controls.posture = .pointing
            if elapsed > 0.45, !fired, context.engaged {
                switch kind {
                case .flickOut: controls.flicks.append(true)
                case .flickIn: controls.flicks.append(false)
                default: controls.tap = true
                }
                markFired()
            }
            retry(after: 2.0)

        case .pose(let heading, let elevation):
            controls.posture = .pointing
            let maxStep = 0.75 * dt
            if let heading { controls.heading += (heading - controls.heading).clamped(-maxStep, maxStep) }
            if let elevation { controls.elevation += (elevation - controls.elevation).clamped(-maxStep, maxStep) }

        case .raise:
            controls.posture = .raised

        case .wander:
            controls.posture = .pointing
            controls.heading = 0.26 * sin(1.9 * clock)
            controls.elevation = VirtualControls.neutralElevation + 0.13 * sin(2.7 * clock)
        }
    }

    // MARK: Pieces

    private static func sameGoal(_ a: AutopilotHint, _ b: AutopilotHint) -> Bool {
        switch (a, b) {
        case (.click(let p, let k), .click(let q, let l)): return k == l && p.distance(to: q) < 6
        case (.grab(let p), .grab(let q)), (.carry(let p), .carry(let q)): return p.distance(to: q) < 6
        case (.scroll, .scroll), (.pose, .pose): return true
        default: return a == b
        }
    }

    private func ready(_ context: Context) -> Bool {
        context.engaged && settled >= 0.14 && elapsed >= 0.3
    }

    private mutating func markFired() { fired = true; sinceFire = 0 }

    /// The gesture did not have its effect (the hint is unchanged): try again.
    private mutating func retry(after delay: Double) {
        if fired, sinceFire > delay { fired = false; settled = 0 }
    }

    /// Proportional steering of the arm toward a screen point. The engine's pointer is relative and
    /// its gain depends on speed, so this closes the loop on the cursor the way eyes do.
    private mutating func aim(at point: CGPoint, dt: Double, context: Context, controls: inout VirtualControls) {
        let ex = Double(point.x - context.cursor.x), ey = Double(point.y - context.cursor.y)
        let distance = (ex * ex + ey * ey).squareRoot()
        settled = distance < 7 ? settled + dt : 0
        guard context.engaged, distance > 2 else { return }

        let gain = 4.5 / 1500.0
        var wx = (ex * gain).clamped(-1.5, 1.5), wy = (ey * gain).clamped(-1.5, 1.5)
        let speed = (wx * wx + wy * wy).squareRoot()
        if speed < 0.06 {                      // stay above the engine's dead zone on the final approach
            wx *= 0.06 / speed
            wy *= 0.06 / speed
        }
        controls.heading -= wx * dt
        controls.elevation -= wy * dt

        let comfortable = 0.2...1.0
        if controls.elevation < comfortable.lowerBound {
            controls.elevation = comfortable.lowerBound
            recovery = (.liftToTop, 0, 0)
        } else if controls.elevation > comfortable.upperBound {
            controls.elevation = comfortable.upperBound
            recovery = (.regrip(recentre: false), 0, 0)
        } else if abs(controls.heading) > 0.8 {
            recovery = (.regrip(recentre: true), 0, 0)
        }
    }

    private mutating func runRecovery(dt: Double, controls: inout VirtualControls) -> Bool {
        guard var state = recovery else { return false }
        state.time += dt
        var finished = false
        switch state.kind {
        case .liftToTop:
            controls.posture = .pointing
            if state.phase == 0 {
                controls.elevation = min(0.92, controls.elevation + 1.6 * dt)
                if controls.elevation >= 0.92 { state = (state.kind, 1, 0) }
            } else if state.time > 0.3 {
                finished = true
            }
        case .regrip(let recentre):
            switch state.phase {
            case 0:
                controls.posture = .dropped
                if state.time > 0.45 { state = (state.kind, 1, 0) }
            case 1:
                // Come back just above the engage angle, so picking the pointer up barely moves it.
                controls.elevation = 0.25
                if recentre { controls.heading = 0 }
                if state.time > 0.45 { state = (state.kind, 2, 0) }
            default:
                controls.posture = .pointing
                if state.time > 0.5 { finished = true }
            }
        }
        if finished {
            recovery = nil
            settled = 0
            return false
        }
        recovery = state
        return true
    }
}
