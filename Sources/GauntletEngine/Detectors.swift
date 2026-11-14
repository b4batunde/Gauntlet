import Foundation
import simd

// MARK: - Pointing frame

/// Orthonormal frame attached to the forearm, expressed in the watch's device frame.
struct PointingFrame {
    /// Along the forearm, toward the hand.
    var forward: SIMD3<Double>
    /// Horizontal, to the wearer's right of the pointing direction.
    var right: SIMD3<Double>
    /// Perpendicular to the forearm, in the vertical plane that contains it.
    var up: SIMD3<Double>
    /// Radians above horizontal.
    var elevation: Double

    /// Returns nil when the forearm is too close to vertical for "left/right" to mean anything.
    static func make(gravity: SIMD3<Double>, forearm: SIMD3<Double>) -> PointingFrame? {
        let gLen = simd_length(gravity)
        guard gLen > 0.3 else { return nil }
        let worldUp = -gravity / gLen
        let sinElevation = max(-1, min(1, simd_dot(forearm, worldUp)))
        let rightRaw = simd_cross(forearm, worldUp)
        let rightLen = simd_length(rightRaw)
        guard rightLen > 0.2 else { return nil }      // within ~11 degrees of vertical
        let right = rightRaw / rightLen
        let up = simd_cross(right, forearm)
        return PointingFrame(forward: forearm, right: right, up: up, elevation: asin(sinElevation))
    }

    /// Wrist twist: 0 when the watch face looks along `up`, positive when it tips toward `right`.
    func roll(deviceNormal: SIMD3<Double> = SIMD3(0, 0, 1)) -> Double {
        atan2(simd_dot(deviceNormal, right), simd_dot(deviceNormal, up))
    }
}

/// Which way "toward the hand" points along the device X axis.
/// With the crown on the hand side (left wrist + crown right, or right wrist + crown left) it is +X.
func forearmAxis(rightWrist: Bool, crownLeft: Bool, flipped: Bool) -> SIMD3<Double> {
    var sign: Double = (rightWrist == crownLeft) ? 1 : -1
    if flipped { sign = -sign }
    return SIMD3(sign, 0, 0)
}

// MARK: - Filters

/// Low-pass whose cutoff rises with signal speed (the idea behind the One Euro filter),
/// applied to a 2D angular-velocity signal: steady at rest, lag-free in fast sweeps.
struct AdaptiveLowPass2 {
    private(set) var state = SIMD2<Double>.zero
    private var primed = false

    mutating func reset() { state = .zero; primed = false }

    mutating func filter(_ x: SIMD2<Double>, dt: Double, minCutoff: Double, beta: Double) -> SIMD2<Double> {
        guard primed else { state = x; primed = true; return x }
        // Use the larger of the smoothed and half the raw speed so the filter opens up quickly at onset.
        let speed = max(simd_length(state), 0.5 * simd_length(x))
        let cutoff = minCutoff + beta * speed
        let alpha = 1 - exp(-2 * Double.pi * cutoff * dt)
        state += alpha * (x - state)
        return state
    }
}

@inline(__always) func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
    guard edge1 > edge0 else { return x >= edge1 ? 1 : 0 }
    let t = max(0, min(1, (x - edge0) / (edge1 - edge0)))
    return t * t * (3 - 2 * t)
}

// MARK: - Finger tap

/// Detects the short, sharp acceleration transient a finger tap sends up the wrist.
///
/// The signal is high-passed (arm movement lives below ~5 Hz), compared against a lagged
/// background level, and must die away quickly — a sustained burst is movement, not a tap.
struct TapDetector {
    private var lowPassed = SIMD3<Double>.zero
    private var background = 0.01
    private var history = [Double](repeating: 0, count: 6)   // envelope delay line (~60 ms at 100 Hz)
    private var historyIndex = 0
    private var gyroSmoothed = 0.0
    private var primed = false

    private enum Phase {
        case idle
        case tracking(start: Double, peak: Double, peakTime: Double, background: Double, gyro: Double)
        case refractory(until: Double)
    }
    private var phase = Phase.idle

    /// Latest high-passed envelope, g.
    private(set) var envelope = 0.0

    static let candidateFloor = 0.04

    mutating func reset() { self = TapDetector() }

    mutating func process(accel: SIMD3<Double>, gyroMagnitude: Double, time: Double, dt: Double,
                          tuning: GestureTuning) -> TapCandidate? {
        if !primed { lowPassed = accel; primed = true }
        let alphaLP = 1 - exp(-2 * Double.pi * 6.0 * dt)
        lowPassed += alphaLP * (accel - lowPassed)
        let e = simd_length(accel - lowPassed)
        envelope = e

        // Background follows the envelope from ~60 ms ago, so a spike cannot raise its own bar.
        let delayed = history[historyIndex]
        history[historyIndex] = e
        historyIndex = (historyIndex + 1) % history.count
        background += (1 - exp(-dt / 0.15)) * (delayed - background)
        gyroSmoothed += (1 - exp(-dt / 0.05)) * (gyroMagnitude - gyroSmoothed)

        switch phase {
        case .idle:
            if e > Self.candidateFloor, e > 2.0 * background {
                phase = .tracking(start: time, peak: e, peakTime: time, background: background, gyro: gyroSmoothed)
            }
            return nil

        case .tracking(let start, var peak, var peakTime, let bg, let gyro):
            if e > peak { peak = e; peakTime = time }
            if time - peakTime >= 0.028 {
                if e < 0.6 * peak {
                    phase = .refractory(until: time + 0.12)
                    let accepted = tuning.tapEnabled
                        && peak >= tuning.tapThreshold
                        && peak >= tuning.tapQuietRatio * max(bg, 0.01)
                        && gyro <= tuning.tapMaxGyro
                    return TapCandidate(time: peakTime, peak: peak, background: bg, gyro: gyro, accepted: accepted)
                }
                if time - start > 0.09 {
                    phase = .refractory(until: time + 0.15)     // sustained: movement, not a tap
                    return nil
                }
            }
            phase = .tracking(start: start, peak: peak, peakTime: peakTime, background: bg, gyro: gyro)
            return nil

        case .refractory(let until):
            if time >= until { phase = .idle }
            return nil
        }
    }
}

// MARK: - Wrist flick

/// Detects a quick twist of the wrist about the forearm axis that immediately springs back.
struct FlickDetector {
    struct Flick {
        /// +1 = positive roll first, -1 = negative roll first.
        var sign: Int
        var peakRate: Double
    }

    private enum Phase {
        case idle
        case outbound(sign: Double, angle: Double, start: Double, peak: Double)
        case cooldown(until: Double)
    }
    private var phase = Phase.idle

    /// True from the start of a twist until shortly after it resolves; the pointer should hold still.
    var isBusy: Bool {
        if case .outbound = phase { return true }
        return false
    }

    mutating func reset() { phase = .idle }

    mutating func process(roll: Double, yaw: Double, pitch: Double, time: Double, dt: Double,
                          tuning: GestureTuning) -> Flick? {
        switch phase {
        case .idle:
            let lateral = (yaw * yaw + pitch * pitch).squareRoot()
            if tuning.flickEnabled, abs(roll) > tuning.flickRate, abs(roll) > 1.6 * lateral {
                phase = .outbound(sign: roll > 0 ? 1 : -1, angle: roll * dt, start: time, peak: abs(roll))
            }
            return nil

        case .outbound(let sign, var angle, let start, var peak):
            if roll * sign > 0 {
                angle += roll * dt
                peak = max(peak, abs(roll))
            }
            if roll * sign < -0.3 * tuning.flickRate {
                // Springing back.
                if abs(angle) >= tuning.flickMinAngle {
                    phase = .cooldown(until: time + 0.35)
                    return Flick(sign: sign > 0 ? 1 : -1, peakRate: peak)
                }
                phase = .cooldown(until: time + 0.2)
                return nil
            }
            if time - start > 0.30 {
                phase = .cooldown(until: time + 0.2)       // a deliberate turn, not a flick
                return nil
            }
            phase = .outbound(sign: sign, angle: angle, start: start, peak: peak)
            return nil

        case .cooldown(let until):
            if time >= until { phase = .idle }
            return nil
        }
    }
}

// MARK: - Calibration

public enum GestureCalibrator {
    public struct TapResult: Sendable {
        public var threshold: Double
        /// How cleanly taps separate from background movement; above ~1.5 is comfortable.
        public var separation: Double
        public var usable: Bool
    }

    /// Picks a personal tap threshold from recorded examples.
    /// - Parameters:
    ///   - taps: peaks (g) of deliberate taps.
    ///   - noise: peaks (g) of transients recorded while just moving the pointer around.
    public static func tapThreshold(taps: [Double], noise: [Double]) -> TapResult {
        guard taps.count >= 3 else { return TapResult(threshold: 0.16, separation: 0, usable: false) }
        let lowTap = percentile(taps, 0.15)
        let highNoise = max(TapDetector.candidateFloor, noise.isEmpty ? TapDetector.candidateFloor : percentile(noise, 0.95))
        let separation = lowTap / highNoise
        let threshold: Double
        if highNoise * 1.3 < lowTap * 0.8 {
            // Clean separation: sit a little below the weakest deliberate taps.
            threshold = max(highNoise * 1.3, lowTap * 0.7)
        } else {
            // Overlap: split the difference and let the quiet-ratio test do the rest.
            threshold = (lowTap + highNoise) / 2
        }
        return TapResult(threshold: max(0.06, min(0.6, threshold)), separation: separation, usable: separation > 1.2)
    }

    public static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let position = max(0, min(1, p)) * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(sorted.count - 1, lower + 1)
        let fraction = position - Double(lower)
        return sorted[lower] * (1 - fraction) + sorted[upper] * fraction
    }
}
