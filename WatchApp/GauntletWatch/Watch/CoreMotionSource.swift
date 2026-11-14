#if os(watchOS)
import Foundation
import CoreMotion

/// Fused device motion from the watch's IMU, delivered on a private queue.
final class CoreMotionSource: MotionSource {
    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "gauntlet.watch.motion"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        return queue
    }()

    var unavailableReason: String? {
        manager.isDeviceMotionAvailable ? nil : "Motion sensors are not available"
    }

    func start(rateHz: Int, sink: @escaping MotionSink) {
        guard manager.isDeviceMotionAvailable else { return }
        if manager.isDeviceMotionActive { manager.stopDeviceMotionUpdates() }
        // Apple Watch delivers device motion at up to 100 Hz.
        manager.deviceMotionUpdateInterval = 1.0 / Double(max(10, min(100, rateHz)))
        let handler: CMDeviceMotionHandler = { motion, _ in
            guard let motion = motion else { return }
            let rate = motion.rotationRate              // rad/s
            let user = motion.userAcceleration          // g, gravity removed
            let gravity = motion.gravity                // unit vector, g
            let attitude = motion.attitude.quaternion
            sink(SIMD3<Double>(rate.x, rate.y, rate.z),
                 SIMD3<Double>(user.x, user.y, user.z),
                 SIMD3<Double>(gravity.x, gravity.y, gravity.z),
                 SIMD4<Double>(attitude.x, attitude.y, attitude.z, attitude.w))
        }
        if CMMotionManager.availableAttitudeReferenceFrames().contains(.xArbitraryZVertical) {
            manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue, withHandler: handler)
        } else {
            manager.startDeviceMotionUpdates(to: queue, withHandler: handler)
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}
#endif
