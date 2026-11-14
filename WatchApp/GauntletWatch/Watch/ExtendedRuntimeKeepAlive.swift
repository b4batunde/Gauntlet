#if os(watchOS)
import Foundation
import WatchKit

/// Fallback keep-alive for when a workout session cannot run (HealthKit unavailable or denied).
///
/// Uses the session type declared in Info.plist (`WKBackgroundModes`: `physical-therapy`),
/// which runs in the background for up to an hour. No heart rate. Main thread only.
final class ExtendedRuntimeKeepAlive: NSObject, KeepAliveBackend, WKExtendedRuntimeSessionDelegate {
    let name = "Extended runtime"
    var onEvent: ((KeepAliveEvent) -> Void)?

    private var session: WKExtendedRuntimeSession?

    func start() {
        stop()
        let session = WKExtendedRuntimeSession()
        session.delegate = self
        self.session = session
        session.start()
    }

    func stop() {
        guard let session = session else { return }
        self.session = nil
        session.delegate = nil
        if session.state != .invalid { session.invalidate() }
    }

    // MARK: WKExtendedRuntimeSessionDelegate

    func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, extendedRuntimeSession === self.session else { return }
            self.onEvent?(.started)
        }
    }

    func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        // Nothing to save; `didInvalidateWith` follows and reports the end.
    }

    func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession,
                                didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
                                error: Error?) {
        let text = error?.localizedDescription ?? "The extended runtime session ended"
        DispatchQueue.main.async { [weak self] in
            guard let self = self, extendedRuntimeSession === self.session else { return }
            self.session = nil
            self.onEvent?(.stopped(reason: text))
        }
    }
}
#endif
