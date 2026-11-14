#if os(watchOS)
import Foundation
import HealthKit

/// Keeps the app running with a workout session, which also yields live heart rate.
///
/// The workout is never saved: when the session ends the builder is discarded.
/// Anything that goes wrong (no HealthKit, no entitlement, access denied, session failure)
/// is reported as `.stopped`, so the coordinator can fall back to another backend.
/// Public methods are main thread only; HealthKit calls back on its own queues.
final class WorkoutKeepAlive: NSObject, KeepAliveBackend, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    let name = "Workout session"
    var onEvent: ((KeepAliveEvent) -> Void)?

    private var store: HKHealthStore?
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    /// Bumped by every `start()` and `stop()` so late callbacks from an older attempt are ignored.
    private var attempt = 0

    func start() {
        stop()
        attempt += 1
        let current = attempt
        guard HKHealthStore.isHealthDataAvailable() else {
            fail("Health data is not available", attempt: current)
            return
        }
        let store = self.store ?? HKHealthStore()
        self.store = store
        var read = Set<HKObjectType>()
        if let heartRate = HKObjectType.quantityType(forIdentifier: .heartRate) { read.insert(heartRate) }
        let share: Set<HKSampleType> = [HKObjectType.workoutType()]
        store.requestAuthorization(toShare: share, read: read) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self = self, self.attempt == current else { return }
                // `success` only says the request was processed; ask what the user decided.
                guard store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized else {
                    self.fail(error?.localizedDescription ?? "Allow Workouts for Gauntlet in Settings > Health",
                              attempt: current)
                    return
                }
                self.begin(store: store, attempt: current)
            }
        }
    }

    func stop() {
        attempt += 1
        finishSession()
    }

    // MARK: Session

    private func begin(store: HKHealthStore, attempt current: Int) {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .other
        configuration.locationType = .indoor
        do {
            let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder
            let startDate = Date()
            session.startActivity(with: startDate)
            builder.beginCollection(withStart: startDate) { _, _ in }
        } catch {
            fail(error.localizedDescription, attempt: current)
        }
    }

    /// Ends the session, if any, and throws the workout away.
    private func finishSession() {
        guard let session = session else { return }
        let builder = self.builder
        self.session = nil
        self.builder = nil
        session.delegate = nil
        builder?.delegate = nil
        if session.state != .ended { session.end() }
        if let builder = builder {
            builder.endCollection(withEnd: Date()) { _, _ in
                builder.discardWorkout()
            }
        }
    }

    private func fail(_ reason: String, attempt current: Int) {
        guard attempt == current else { return }
        finishSession()
        // Never synchronously from inside `start()`.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.attempt == current else { return }
            self.onEvent?(.stopped(reason: reason))
        }
    }

    // MARK: HKWorkoutSessionDelegate

    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState, date: Date) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, workoutSession === self.session else { return }
            switch toState {
            case .running:
                self.onEvent?(.started)
            case .ended, .stopped:
                // Not ended by us (that path clears `session` first): the system stopped it.
                self.fail("The workout session ended", attempt: self.attempt)
            default:
                break
            }
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        let reason = error.localizedDescription
        DispatchQueue.main.async { [weak self] in
            guard let self = self, workoutSession === self.session else { return }
            self.fail(reason, attempt: self.attempt)
        }
    }

    // MARK: HKLiveWorkoutBuilderDelegate

    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        guard let heartRate = HKObjectType.quantityType(forIdentifier: .heartRate),
              collectedTypes.contains(heartRate),
              let quantity = workoutBuilder.statistics(for: heartRate)?.mostRecentQuantity() else { return }
        let bpm = quantity.doubleValue(for: HKUnit.count().unitDivided(by: HKUnit.minute()))
        guard bpm.isFinite, bpm > 0 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, workoutBuilder === self.builder else { return }
            self.onEvent?(.heartRate(Int(bpm.rounded())))
        }
    }

    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}
#endif
