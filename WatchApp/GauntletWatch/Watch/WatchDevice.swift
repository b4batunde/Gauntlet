#if os(watchOS)
import Foundation
import WatchKit

/// The watch itself: how it is worn, its battery, and its Taptic Engine. Main thread only.
final class WatchDevice: DeviceProbe, HapticPlayer {
    private let device = WKInterfaceDevice.current()

    init() {
        device.isBatteryMonitoringEnabled = true
    }

    var deviceName: String { device.name }

    func wearing() -> WearingInfo {
        WearingInfo(rightWrist: device.wristLocation == .right,
                    crownLeft: device.crownOrientation == .left)
    }

    func battery() -> BatteryInfo {
        let level = device.batteryLevel             // 0...1, negative when unknown
        let state = device.batteryState
        let percent: Int? = level >= 0 ? Int((level * 100).rounded()) : nil
        return BatteryInfo(percent: percent, charging: state == .charging || state == .full)
    }

    func play(_ tone: HapticTone) {
        device.play(tone.watchKitType)
    }
}

extension HapticTone {
    var watchKitType: WKHapticType {
        switch self {
        case .click: return .click
        case .directionUp: return .directionUp
        case .directionDown: return .directionDown
        case .start: return .start
        case .stop: return .stop
        case .success: return .success
        case .failure: return .failure
        case .notification: return .notification
        case .retry: return .retry
        }
    }
}
#endif
