import Foundation
import simd
import GauntletProtocol

/// A physically plausible simulated Apple Watch.
///
/// You steer the forearm (heading / elevation / roll targets); it produces the same
/// sensor packets a real watch would: gyro, user acceleration, gravity and attitude,
/// complete with hand tremor and sensor noise. Used by the tests, by `fakewatch`,
/// and by the Dojo's "virtual watch" so everything can be exercised without hardware.
public final class VirtualWatch {

    // Targets the arm moves toward (radians).
    public var targetHeading = 0.0
    public var targetElevation = 0.35
    public var targetRoll = 0.0

    public var rightWrist = false
    public var crownLeft = false
    /// 0 = perfectly steady, 1 = typical human hand tremor.
    public var tremor = 1.0
    /// How quickly the arm follows its targets (natural frequency, rad/s).
    public var agility = 18.0
    public var sampleInterval = 0.01
    public var samplesPerPacket = 2
    public var touching = false

    // Actual simulated pose.
    public private(set) var heading = 0.0
    public private(set) var elevation = 0.35
    public private(set) var roll = 0.0
    public private(set) var time = 0.0

    private var headingRate = 0.0
    private var elevationRate = 0.0
    private var rollRate = 0.0
    private var seq: UInt8 = 0
    private var eventSeq: UInt8 = 0
    private var tapImpulse: [Double] = []
    private var flickElapsed: Double?
    private var flickSign = 1.0
    private var rng: UInt64

    public init(seed: UInt64 = 0x9E3779B97F4A7C15) {
        rng = seed == 0 ? 1 : seed
    }

    /// Jump straight to a pose with no transient.
    public func snap(heading: Double, elevation: Double, roll: Double = 0) {
        self.heading = heading; self.elevation = elevation; self.roll = roll
        targetHeading = heading; targetElevation = elevation; targetRoll = roll
        headingRate = 0; elevationRate = 0; rollRate = 0
    }

    /// Simulate a thumb-to-finger tap of the given strength (peak g).
    public func tap(strength: Double = 0.4) {
        tapImpulse = [1.0, -0.7, 0.3, -0.1].map { $0 * strength }
    }

    /// Simulate a quick wrist twist and return.
    public func flick(outward: Bool) {
        flickElapsed = 0
        flickSign = (outward == rightWrist) ? 1 : -1
    }

    public func action(_ code: WatchActionCode) -> WatchMessage {
        eventSeq &+= 1
        return .action(WatchAction(seq: eventSeq, code: code))
    }

    public func crown(delta: Double) -> WatchMessage {
        eventSeq &+= 1
        return .crown(CrownEvent(seq: eventSeq, delta: delta))
    }

    public func touch(_ phase: TouchPhase, dx: Double = 0, dy: Double = 0) -> WatchMessage {
        eventSeq &+= 1
        touching = (phase == .began || phase == .moved)
        return .touch(TouchEvent(seq: eventSeq, phase: phase, dx: dx, dy: dy))
    }

    public func status(battery: Int = 82, heartRate: Int = 68) -> WatchMessage {
        eventSeq &+= 1
        var flags: StatusFlags = [.keepAliveActive]
        if rightWrist { flags.insert(.rightWrist) }
        if crownLeft { flags.insert(.crownLeft) }
        return .status(WatchStatus(seq: eventSeq, battery: battery, heartRate: heartRate, flags: flags,
                                   rssi: -48, sampleRateHz: Int((1 / sampleInterval).rounded())))
    }

    /// Advance the simulation by one packet's worth of samples.
    public func nextPacket() -> WatchMessage {
        var samples: [MotionSample] = []
        samples.reserveCapacity(samplesPerPacket)
        var lastRotation = matrix_identity_double3x3
        for _ in 0..<max(1, samplesPerPacket) {
            let (sample, rotation) = step()
            samples.append(sample)
            lastRotation = rotation
        }
        let q = simd_quatd(lastRotation)
        let gravity = lastRotation.transpose * SIMD3<Double>(0, 0, -1)
        var flags: MotionFlags = []
        if rightWrist { flags.insert(.rightWrist) }
        if crownLeft { flags.insert(.crownLeft) }
        if touching { flags.insert(.touching) }
        seq &+= 1
        let packet = MotionPacket(
            seq: seq, flags: flags,
            timestampMs: UInt32(truncatingIfNeeded: Int((time * 1000).rounded())),
            sampleIntervalMs: UInt8(max(1, min(255, Int((sampleInterval * 1000).rounded())))),
            quaternion: SIMD4(q.imag.x, q.imag.y, q.imag.z, q.real),
            gravity: gravity, samples: samples)
        return .motion(packet)
    }

    // MARK: Simulation

    private func step() -> (MotionSample, simd_double3x3) {
        let dt = sampleInterval
        time += dt

        // Critically damped pursuit of the targets.
        func pursue(_ x: inout Double, _ v: inout Double, target: Double) {
            let a = agility * agility * (target - x) - 2 * agility * v
            v += a * dt
            x += v * dt
        }
        pursue(&heading, &headingRate, target: targetHeading)
        pursue(&elevation, &elevationRate, target: targetElevation)
        pursue(&roll, &rollRate, target: targetRoll)
        elevation = max(-1.45, min(1.45, elevation))

        // Physiological tremor: a few hundredths of a degree around 8-11 Hz.
        let amp = 0.0012 * tremor
        let w1 = 2 * Double.pi * 8.7, w2 = 2 * Double.pi * 10.9
        let tremorHeadingRate = amp * w1 * cos(w1 * time + 0.4)
        let tremorElevationRate = amp * w2 * cos(w2 * time + 1.9)

        // Wrist flick rides on top of the commanded roll.
        var flickRate = 0.0
        if let elapsed = flickElapsed {
            let duration = 0.16, amplitude = 0.5
            if elapsed <= duration {
                flickRate = flickSign * amplitude * Double.pi / duration * cos(Double.pi * elapsed / duration)
                flickElapsed = elapsed + dt
            } else {
                flickElapsed = nil
            }
        }

        let hRate = headingRate + tremorHeadingRate
        let eRate = elevationRate + tremorElevationRate
        let rRate = rollRate + flickRate

        // World frame: X right, Y forward (toward the screen), Z up.
        let forward = SIMD3<Double>(-sin(heading) * cos(elevation), cos(heading) * cos(elevation), sin(elevation))
        let right0 = SIMD3<Double>(cos(heading), sin(heading), 0)
        let up0 = simd_cross(right0, forward)
        let up = up0 * cos(roll) + right0 * sin(roll)

        // Device axes: X along the forearm (sign depends on how the watch is worn), Z out of the display.
        let s: Double = (rightWrist == crownLeft) ? 1 : -1
        let xDevice = forward * s
        let zDevice = up
        let yDevice = simd_cross(zDevice, xDevice)
        let rotation = simd_double3x3(columns: (xDevice, yDevice, zDevice))     // device -> world

        let omegaWorld = SIMD3<Double>(0, 0, 1) * hRate + right0 * eRate + forward * rRate
        var gyro = rotation.transpose * omegaWorld
        gyro += SIMD3(noise(), noise(), noise()) * 0.003

        var accel = SIMD3(noise(), noise(), noise()) * 0.004
        if !tapImpulse.isEmpty {
            let a = tapImpulse.removeFirst()
            accel += SIMD3(0.25 * a, 0.15 * a, a)
        }
        return (MotionSample(gyro: gyro, accel: accel), rotation)
    }

    /// Roughly unit-variance noise from a deterministic generator (repeatable tests).
    private func noise() -> Double {
        var sum = 0.0
        for _ in 0..<4 {
            rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
            sum += Double(rng >> 11) / Double(1 << 53)
        }
        return (sum - 2.0) * 1.732
    }
}
