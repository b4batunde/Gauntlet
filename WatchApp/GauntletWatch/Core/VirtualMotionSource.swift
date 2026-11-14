import Foundation
import GauntletProtocol
import GauntletEngine

/// Synthetic motion for the watchOS Simulator, which has no IMU.
///
/// Drives the shared `VirtualWatch` through a slow figure of eight, so a simulator build
/// exercises the whole link and visibly moves the pointer on the Mac.
final class VirtualMotionSource: MotionSource {
    var unavailableReason: String? { nil }

    private let queue = DispatchQueue(label: "gauntlet.watch.virtual-motion", qos: .userInteractive)
    private let watch = VirtualWatch()          // touched on `queue` only
    private var timer: DispatchSourceTimer?     // main thread only

    func start(rateHz: Int, sink: @escaping MotionSink) {
        stop()
        let interval = 1.0 / Double(max(10, min(200, rateHz)))
        let watch = self.watch
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.05, repeating: interval, leeway: .milliseconds(1))
        timer.setEventHandler {
            watch.sampleInterval = interval
            watch.samplesPerPacket = 1
            let t = watch.time
            watch.targetHeading = 0.22 * sin(t * 0.9)
            watch.targetElevation = 0.34 + 0.10 * sin(t * 1.8)     // stays above the engage angle
            guard case .motion(let packet) = watch.nextPacket() else { return }
            for sample in packet.samples {
                sink(sample.gyro, sample.accel, packet.gravity, packet.quaternion)
            }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func setWearing(_ wearing: WearingInfo) {
        let watch = self.watch
        queue.async {
            watch.rightWrist = wearing.rightWrist
            watch.crownLeft = wearing.crownLeft
        }
    }
}
