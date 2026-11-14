// A stand-in for the few WatchKit declarations the watch app uses.
//
// NOT part of the app and never built by Xcode. `tools/typecheck.sh` compiles this into a
// module named `WatchKit` so that the watch-only sources can be type-checked on a Mac that
// has no watchOS SDK. It is written from memory of the real headers, so that check proves the
// app is consistent with THIS file, not with Apple's SDK; the real build is the final word.
import Foundation

public enum WKHapticType: Int {
    case notification, directionUp, directionDown, success, failure, retry, start, stop, click
}

public enum WKInterfaceDeviceWristLocation: Int { case left, right }
public enum WKInterfaceDeviceCrownOrientation: Int { case left, right }
public enum WKInterfaceDeviceBatteryState: Int { case unknown, unplugged, charging, full }

open class WKInterfaceDevice: NSObject {
    private static let shared = WKInterfaceDevice()
    open class func current() -> WKInterfaceDevice { shared }
    open var name: String { "Apple Watch" }
    open var wristLocation: WKInterfaceDeviceWristLocation { .left }
    open var crownOrientation: WKInterfaceDeviceCrownOrientation { .right }
    open var isBatteryMonitoringEnabled = false
    open var batteryLevel: Float { -1 }
    open var batteryState: WKInterfaceDeviceBatteryState { .unknown }
    open func play(_ type: WKHapticType) {}
}

@objc public enum WKExtendedRuntimeSessionState: Int { case notStarted, scheduled, running, invalid }

@objc public enum WKExtendedRuntimeSessionInvalidationReason: Int {
    case none, sessionInProgress, expired, resignedFrontmost, suppressedBySystem, error
}

@objc public protocol WKExtendedRuntimeSessionDelegate: NSObjectProtocol {
    func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession,
                                didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
                                error: Error?)
    func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession)
    func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession)
}

open class WKExtendedRuntimeSession: NSObject {
    public override init() { super.init() }
    open weak var delegate: WKExtendedRuntimeSessionDelegate?
    open var state: WKExtendedRuntimeSessionState { .notStarted }
    open var expirationDate: Date? { nil }
    open func start() {}
    open func start(at date: Date) {}
    open func invalidate() {}
}
