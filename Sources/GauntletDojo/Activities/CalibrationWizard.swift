import Foundation
import CoreGraphics
import simd
import GauntletEngine

/// The calibration procedure as a plain state machine: feed it engine snapshots and events,
/// and it measures the wearer and writes the results into the engine's settings.
///
/// It has no views and no clock of its own, so the self-check can drive it step by step.
final class CalibrationWizard {
    enum Step: Int, CaseIterable {
        case hold, raise, sweepHorizontal, sweepVertical, taps, quiet, flicks, done

        var title: String {
            switch self {
            case .hold: return "Point and hold still"
            case .raise: return "Raise to the ceiling"
            case .sweepHorizontal: return "Sweep left to right"
            case .sweepVertical: return "Sweep top to bottom"
            case .taps: return "Tap eight times"
            case .quiet: return "Move without tapping"
            case .flicks: return "Flick out and in"
            case .done: return "Calibrated"
            }
        }
    }

    /// What was measured and what was changed. Nil means the step has not happened (or was skipped).
    struct Report: Equatable {
        var restElevationDeg: Double?
        /// True when the forearm axis guess was backwards and has been flipped.
        var axisCorrected: Bool?
        var headingRangeDeg: Double?
        var sensitivity: Double?
        var verticalRangeDeg: Double?
        /// Fraction of the screen height the vertical sweep covered at the new sensitivity.
        var verticalCoverage: Double?
        /// The "down" sweep read as going up — the axis is probably still wrong.
        var verticalInverted = false
        /// New raise-to-point angle, when the bottom of the sweep would otherwise have released the pointer.
        var clutchAngleDeg: Double?
        var tapThreshold: Double?
        var tapSeparation: Double?
        var tapUsable: Bool?
        var flickRate: Double?
    }

    enum Tuning {
        static let stillRate = 0.4              // rad/s; below this the arm counts as still
        static let holdTime = 1.5
        static let raiseDelta = 0.45            // rad the elevation must change to count as "raised"
        static let raiseHold = 0.4
        static let sweepSettle = 0.6
        static let minHeadingSweep = 0.12
        static let minElevationSweep = 0.10
        static let tapsWanted = 8
        static let quietTime = 5.0
        static let movingRate = 0.3
        static let flicksEachWay = 3
        static let flicksTotal = 8
        static let listeningFlickRate = 3.0     // generous threshold while collecting flicks
    }

    private(set) var step = Step.hold
    private(set) var skipped: Set<Step> = []
    private(set) var report = Report()
    /// 0...1 within the current step.
    private(set) var progress = 0.0
    /// 0 = first half of a two-part step, 1 = second half.
    private(set) var subPhase = 0
    private(set) var isStreaming = false
    private(set) var changedSettings = false
    private(set) var tapPeaks: [Double] = []
    private(set) var noisePeaks: [Double] = []
    private(set) var flicksOut: [Double] = []
    private(set) var flicksIn: [Double] = []
    /// Live measurement for the current step, radians (elevation change or sweep width so far).
    private(set) var liveSpan = 0.0

    /// Called once per completed (not skipped) step, and when the whole run finishes.
    var onStepCompleted: ((Step) -> Void)?
    var onFinished: (() -> Void)?

    private let engine: WristEngine
    private let screenSize: CGSize
    private let travel: () -> SIMD2<Double>

    private var last = WristSnapshot()
    private var stepStartedAt: TimeInterval = 0
    private var stillSince: TimeInterval?
    private var elevationSum = 0.0
    private var elevationSamples = 0
    private var restElevation = 0.0
    private var beyondSince: TimeInterval?
    private var beyondSign = 0.0
    private var decidedAt: TimeInterval?
    private var backSince: TimeInterval?
    private var sawMotion = false
    private var anchor: (value: Double, travel: Double, time: TimeInterval)?
    private var wrongWay = 0.0
    private var lastTapAt: TimeInterval = -10
    private var movingTime = 0.0
    private var lastUpdate: TimeInterval = 0
    private var savedFlick: (rate: Double, enabled: Bool)?

    /// - Parameter travel: total pointer travel the engine has emitted (the sandbox sink's odometer).
    init(engine: WristEngine, screenSize: CGSize, travel: @escaping () -> SIMD2<Double>) {
        self.engine = engine
        self.screenSize = screenSize
        self.travel = travel
    }

    // MARK: Driving

    func start(now: TimeInterval) {
        restoreFlickSettings()
        step = .hold
        skipped = []
        report = Report()
        tapPeaks = []; noisePeaks = []; flicksOut = []; flicksIn = []
        lastUpdate = now
        enter(.hold, now: now)
    }

    /// Leave things tidy if the user walks away mid-run.
    func cancel() {
        restoreFlickSettings()
    }

    func update(_ snapshot: WristSnapshot, now: TimeInterval) {
        let dt = (now - lastUpdate).clamped(0, 0.1)
        lastUpdate = now
        last = snapshot
        isStreaming = snapshot.streaming
        guard snapshot.streaming else { stillSince = nil; return }
        let speed = simd_length(snapshot.gyro)
        let still = speed < Tuning.stillRate

        switch step {
        case .hold:
            updateHold(snapshot, still: still, now: now)
        case .raise:
            updateRaise(snapshot, now: now)
        case .sweepHorizontal:
            // Sweeping right lowers the heading, so measure "leftness".
            if let sweep = updateSweep(value: snapshot.heading, odometer: travel().x, still: still, speed: speed,
                                       minimum: Tuning.minHeadingSweep, now: now) {
                finishHorizontalSweep(sweep)
                complete(now: now)
            }
        case .sweepVertical:
            if let sweep = updateSweep(value: snapshot.elevation, odometer: travel().y, still: still, speed: speed,
                                       minimum: Tuning.minElevationSweep, now: now) {
                finishVerticalSweep(sweep)
                complete(now: now)
            }
        case .taps:
            progress = Double(tapPeaks.count) / Double(Tuning.tapsWanted)
        case .quiet:
            if speed > Tuning.movingRate { movingTime += dt }
            progress = movingTime / Tuning.quietTime
            if movingTime >= Tuning.quietTime {
                finishTapCalibration()
                complete(now: now)
            }
        case .flicks:
            let total = flicksOut.count + flicksIn.count
            progress = Double(min(flicksOut.count, Tuning.flicksEachWay) + min(flicksIn.count, Tuning.flicksEachWay))
                / Double(Tuning.flicksEachWay * 2)
            if (flicksOut.count >= Tuning.flicksEachWay && flicksIn.count >= Tuning.flicksEachWay) || total >= Tuning.flicksTotal {
                finishFlickCalibration()
                complete(now: now)
            }
        case .done:
            break
        }
    }

    func handle(_ event: EngineEvent, now: TimeInterval) {
        switch event {
        case .tapCandidate(let candidate):
            if step == .taps {
                // A deliberate tap: clearly above the floor, arm not swinging, not a bounce of the last one.
                guard candidate.peak >= 0.05, candidate.gyro < 3, now - lastTapAt > 0.18 else { return }
                lastTapAt = now
                tapPeaks.append(candidate.peak)
                if tapPeaks.count >= Tuning.tapsWanted { complete(now: now) }
            } else if step == .quiet {
                noisePeaks.append(candidate.peak)
            }
        case .flickCandidate(let outward, let peakRate):
            guard step == .flicks else { return }
            if outward { flicksOut.append(peakRate) } else { flicksIn.append(peakRate) }
        default:
            break
        }
    }

    /// Give up on the current step and move on, changing as little as possible.
    func skip(now: TimeInterval) {
        switch step {
        case .hold:
            restElevation = last.elevation
        case .quiet:
            finishTapCalibration()              // use whatever noise was heard so far
            complete(now: now)
            return
        case .flicks:
            if flicksOut.count + flicksIn.count >= 2 {
                finishFlickCalibration()
                complete(now: now)
                return
            }
        case .taps:
            if tapPeaks.count >= 3 {            // enough to work with
                complete(now: now)
                return
            }
            // Without taps there is nothing to calibrate; leave the tap settings alone.
            skipped.insert(.taps)
            skipped.insert(.quiet)
            enter(.flicks, now: now)
            return
        case .done:
            return
        default:
            break
        }
        skipped.insert(step)
        advance(now: now)
    }

    /// Manual override for the one thing that cannot be measured without trusting the user.
    func flipAxis() {
        engine.updateSettings { $0.forearmAxisFlipped.toggle() }
        restElevation = -restElevation
        report.axisCorrected = !(report.axisCorrected ?? false)
        report.verticalInverted = false
        changedSettings = true
    }

    // MARK: Steps

    private func updateHold(_ s: WristSnapshot, still: Bool, now: TimeInterval) {
        guard still, s.poseValid else {
            stillSince = nil
            progress = 0
            return
        }
        guard let since = stillSince else {
            stillSince = now
            elevationSum = 0
            elevationSamples = 0
            return
        }
        elevationSum += s.elevation
        elevationSamples += 1
        progress = (now - since) / Tuning.holdTime
        if progress >= 1, elevationSamples > 0 {
            restElevation = elevationSum / Double(elevationSamples)
            report.restElevationDeg = degrees(restElevation)
            complete(now: now)
        }
    }

    /// The one fact that cannot be known in advance: which way along the watch "toward the hand" is.
    /// The wearer raises their arm; if the measured elevation falls instead, the guess was backwards.
    private func updateRaise(_ s: WristSnapshot, now: TimeInterval) {
        // Near vertical the engine keeps its last valid elevation (about 79 degrees), which is still far past the threshold.
        let delta = s.elevation - restElevation
        liveSpan = delta
        if let decided = decidedAt {
            // Decided; wait for the arm to come back down so the next step starts from pointing.
            let back = s.poseValid && abs(delta) < 0.25
            progress = 0.75
            if back {
                if let since = backSince {
                    if now - since >= 0.3 { complete(now: now) }
                } else {
                    backSince = now
                }
            } else {
                backSince = nil
            }
            if now - decided > 8 { complete(now: now) }
            return
        }
        progress = min(1, abs(delta) / Tuning.raiseDelta) * 0.7
        guard abs(delta) > Tuning.raiseDelta else { beyondSince = nil; return }
        let sign: Double = delta > 0 ? 1 : -1
        guard let since = beyondSince, beyondSign == sign else {
            beyondSince = now
            beyondSign = sign
            return
        }
        // Sustained, so a wobble on the way up cannot decide it.
        guard now - since >= Tuning.raiseHold else { return }
        if sign < 0 {
            engine.updateSettings { $0.forearmAxisFlipped.toggle() }
            restElevation = -restElevation
            report.restElevationDeg = degrees(restElevation)
            report.axisCorrected = true
            changedSettings = true
        } else {
            report.axisCorrected = false
        }
        decidedAt = now
        backSince = nil
        subPhase = 1
    }

    private struct Sweep {
        var from: Double
        var to: Double
        var travel: Double
        var duration: Double
    }

    /// Two-part sweep: pause at the start (left / top), move, pause at the end (right / bottom).
    /// `value` must decrease along the instructed direction. Moving the other way re-anchors the start.
    private func updateSweep(value: Double, odometer: Double, still: Bool, speed: Double, minimum: Double,
                             now: TimeInterval) -> Sweep? {
        if speed > 0.5 { sawMotion = true }
        if still {
            if stillSince == nil { stillSince = now }
        } else {
            stillSince = nil
        }
        let settled = stillSince.map { now - $0 >= Tuning.sweepSettle } ?? false

        guard let start = anchor else {
            // Wait until they have moved to the starting edge (or were evidently already there).
            progress = 0
            liveSpan = 0
            let armed = sawMotion || now - stepStartedAt > 2.5
            if armed, settled, let since = stillSince {
                anchor = (value, odometer, since)
                subPhase = 1
            }
            return nil
        }
        if value > start.value + 0.03 {
            // Still heading for the starting edge: move the anchor with them.
            wrongWay += value - start.value
            anchor = (value, odometer, now)
            return nil
        }
        let span = start.value - value
        liveSpan = span
        progress = min(0.95, span / max(minimum * 2.5, 0.3))
        guard span >= minimum, settled, let since = stillSince else { return nil }
        return Sweep(from: start.value, to: value, travel: abs(odometer - start.travel), duration: max(0.1, since - start.time))
    }

    private func finishHorizontalSweep(_ sweep: Sweep) {
        let settings = engine.currentSettings
        let range = sweep.from - sweep.to
        report.headingRangeDeg = degrees(range)
        let width = Double(screenSize.width)
        var sensitivity: Double
        if sweep.travel > 80 {
            // The engine already told us how far that sweep moved the pointer at the old sensitivity.
            sensitivity = settings.sensitivity * width / sweep.travel
        } else {
            // The pointer was not engaged; fall back to the engine's gain curve at the sweep's mean speed.
            sensitivity = Self.sensitivity(forRange: range, duration: sweep.duration, width: width, settings: settings)
        }
        sensitivity = sensitivity.clamped(0.3, 4.0)
        engine.updateSettings { $0.sensitivity = sensitivity }
        report.sensitivity = sensitivity
        changedSettings = true
    }

    /// Sensitivity that makes `range` radians, swept in `duration` seconds, span `width` points.
    static func sensitivity(forRange range: Double, duration: Double, width: Double, settings: EngineSettings) -> Double {
        let speed = range / max(0.1, duration)
        let t = ((speed - 0.05) / max(0.01, settings.boostSpeed - 0.05)).clamped(0, 1)
        let boost = t * t * (3 - 2 * t)
        let multiplier = settings.precisionMultiplier + (settings.boostMultiplier - settings.precisionMultiplier) * boost
        return width / max(1, settings.baseGain * multiplier * range)
    }

    private func finishVerticalSweep(_ sweep: Sweep) {
        let settings = engine.currentSettings
        report.verticalRangeDeg = degrees(sweep.from - sweep.to)
        report.verticalCoverage = sweep.travel > 20 ? sweep.travel / Double(screenSize.height) : nil
        report.verticalInverted = wrongWay > 0.25

        // The bottom of the sweep must stay above the angle where raise-to-point lets go (6 degrees below engage).
        guard settings.clutch == .raiseToPoint else { return }
        let bottom = degrees(sweep.to)
        let highestSafe = bottom + 6 - 3
        if settings.raiseAngleDeg > highestSafe {
            let angle = max(-30, highestSafe)
            engine.updateSettings { $0.raiseAngleDeg = angle }
            report.clutchAngleDeg = angle
            changedSettings = true
        }
    }

    private func finishTapCalibration() {
        let result = GestureCalibrator.tapThreshold(taps: tapPeaks, noise: noisePeaks)
        report.tapThreshold = result.threshold
        report.tapSeparation = result.separation
        report.tapUsable = result.usable
        engine.updateSettings { settings in
            settings.gestures.tapEnabled = result.usable
            if result.usable { settings.gestures.tapThreshold = result.threshold }
        }
        changedSettings = true
    }

    private func finishFlickCalibration() {
        let peaks = (flicksOut + flicksIn).sorted()
        guard !peaks.isEmpty else { restoreFlickSettings(); return }
        let median = GestureCalibrator.percentile(peaks, 0.5)
        let rate = (median * 0.6).clamped(3, 9)
        savedFlick = nil
        engine.updateSettings { settings in
            settings.gestures.flickRate = rate
            settings.gestures.flickEnabled = true
        }
        report.flickRate = rate
        changedSettings = true
    }

    private func restoreFlickSettings() {
        guard let saved = savedFlick else { return }
        savedFlick = nil
        engine.updateSettings { settings in
            settings.gestures.flickRate = saved.rate
            settings.gestures.flickEnabled = saved.enabled
        }
    }

    // MARK: Sequencing

    private func complete(now: TimeInterval) {
        let finished = step
        advance(now: now)
        onStepCompleted?(finished)
    }

    private func advance(now: TimeInterval) {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        enter(next, now: now)
    }

    private func enter(_ next: Step, now: TimeInterval) {
        if step == .flicks, next != .flicks { restoreFlickSettings() }
        step = next
        stepStartedAt = now
        progress = 0
        subPhase = 0
        liveSpan = 0
        stillSince = nil
        beyondSince = nil
        decidedAt = nil
        backSince = nil
        sawMotion = false
        anchor = nil
        wrongWay = 0
        movingTime = 0

        switch next {
        case .flicks:
            // Listen with a low threshold so gentle flicks are heard too; the real one is set from what we hear.
            let current = engine.currentSettings.gestures
            savedFlick = (current.flickRate, current.flickEnabled)
            engine.updateSettings { settings in
                settings.gestures.flickEnabled = true
                settings.gestures.flickRate = min(settings.gestures.flickRate, Tuning.listeningFlickRate)
            }
        case .done:
            if engine.snapshot().dragging { engine.perform(.toggleDrag) }     // a practice flick-in may have grabbed
            engine.updateSettings { $0.calibrated = true }
            changedSettings = true
            progress = 1
            onFinished?()
        default:
            break
        }
    }
}
