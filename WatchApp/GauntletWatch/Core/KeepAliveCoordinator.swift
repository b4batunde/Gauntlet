import Foundation

/// Runs the first keep-alive backend that works and falls back to the next when one cannot.
///
/// On a watch that is a workout session (which also gives heart rate) and then an extended
/// runtime session. Main thread only.
final class KeepAliveCoordinator {

    enum State: Equatable {
        case off
        case starting
        /// Running; the string is the backend's name.
        case active(String)
        /// Wanted, but nothing could run. The string says why, when known.
        case unavailable(String?)
    }

    private(set) var state: State = .off
    private(set) var heartRate: Int?
    /// Called after `state` or `heartRate` changed.
    var onChange: (() -> Void)?

    private let backends: [KeepAliveBackend]
    private var index = 0
    private var wanted = false

    init(backends: [KeepAliveBackend]) {
        self.backends = backends
        for (position, backend) in backends.enumerated() {
            backend.onEvent = { [weak self] event in self?.handle(event, from: position) }
        }
    }

    var isActive: Bool {
        if case .active = state { return true }
        return false
    }

    /// True between `start()` and `stop()`, whether or not a backend is actually running.
    var isWanted: Bool { wanted }

    /// Starts keeping the app alive. Does nothing while already starting or active;
    /// tries again from the preferred backend after everything failed.
    func start() {
        switch state {
        case .starting, .active:
            return
        case .off, .unavailable:
            wanted = true
            index = 0
            begin(lastReason: nil)
        }
    }

    func stop() {
        guard wanted else { return }
        wanted = false
        if index < backends.count { backends[index].stop() }
        heartRate = nil
        state = .off
        onChange?()
    }

    private func begin(lastReason: String?) {
        guard index < backends.count else {
            state = .unavailable(lastReason)
            onChange?()
            return
        }
        state = .starting
        onChange?()
        backends[index].start()
    }

    private func handle(_ event: KeepAliveEvent, from position: Int) {
        guard wanted, position == index else { return }
        switch event {
        case .started:
            state = .active(backends[position].name)
            onChange?()
        case .heartRate(let bpm):
            guard heartRate != bpm else { return }
            heartRate = bpm
            onChange?()
        case .stopped(let reason):
            heartRate = nil
            index += 1
            begin(lastReason: reason)
        }
    }
}
