import Foundation
import Combine
import GauntletProtocol
import GauntletLink
import GauntletWatchCore

/// Owns the link and the sensors and ties them together. Main thread only.
///
/// Views observe this for watch-side state and `session` for link state.
final class AppModel: ObservableObject {

    /// Pairing, batching and reconnection live in the shared module.
    let session: WatchSessionController
    /// True in the simulator: synthetic motion over the developer link.
    let isSimulated: Bool

    /// False after the user ended the session; nothing streams and nothing keeps the app alive.
    @Published private(set) var sessionActive = false
    @Published private(set) var wearing: WearingInfo
    @Published private(set) var battery = BatteryInfo(percent: nil, charging: false)
    @Published private(set) var heartRate: Int?
    @Published private(set) var keepAlive: KeepAliveCoordinator.State = .off
    /// Why motion is not being read, when it is not.
    @Published private(set) var motionProblem: String?
    /// Why the last pairing attempt was turned down. Kept on screen until the user retries or a
    /// new attempt gets under way, because the link itself goes straight back to searching.
    @Published private(set) var rejection: String?
    /// The watch mic is streaming to June on the Mac.
    @Published private(set) var micLive = false
    /// Why the mic is not streaming although the Mac asked for it.
    @Published private(set) var micProblem: String?
    /// Local setting: play haptics the Mac asks for (and crown detents).
    @Published var hapticsEnabled: Bool {
        didSet { defaults.set(!hapticsEnabled, forKey: Self.hapticsMutedKey) }
    }

    /// How long the keep-alive session survives without a Mac before it is given up, seconds.
    var disconnectGrace: TimeInterval = 300

    private static let hapticsMutedKey = "gauntlet.watch.hapticsMuted"

    private let services: PlatformServices
    private let defaults: UserDefaults
    private let keepAliveCoordinator: KeepAliveCoordinator
    private var cancellables = Set<AnyCancellable>()
    private var vitalsTimer: Timer?
    private var graceStop: DispatchWorkItem?
    private var launched = false
    private var linkConnected = false
    private var macPaused = false
    private var motionRunning = false
    /// The Mac currently wants microphone audio.
    private var micWanted = false
    private var micStarting = false
    private var lastAssistantState: AssistantWatchState = .off
    private var talking = false

    /// - Parameter session: pass a ready-made controller to run over a test transport;
    ///   by default one is created for `services.route`.
    init(services: PlatformServices, defaults: UserDefaults = .standard, session: WatchSessionController? = nil) {
        self.services = services
        self.defaults = defaults
        isSimulated = services.isSimulated
        self.session = session ?? WatchSessionController(deviceName: services.device.deviceName,
                                                         route: services.route, defaults: defaults)
        keepAliveCoordinator = KeepAliveCoordinator(backends: services.keepAlive)
        wearing = services.device.wearing()
        hapticsEnabled = !defaults.bool(forKey: Self.hapticsMutedKey)

        self.session.onHaptic = { [weak self] pattern in self?.play(pattern.tone) }
        self.session.onStreamConfig = { [weak self] config in self?.streamConfigChanged(config) }
        self.session.onAudioRequest = { [weak self] on in self?.audioRequestChanged(on) }
        self.session.onAssistantState = { [weak self] state in self?.assistantStateChanged(state) }
        keepAliveCoordinator.onChange = { [weak self] in self?.keepAliveChanged() }
        // `@Published` delivers the new value on the main thread, just before it is stored.
        self.session.$state
            .sink { [weak self] state in self?.linkStateChanged(state) }
            .store(in: &cancellables)
        self.session.$macState
            .sink { [weak self] flags in self?.macStateChanged(flags) }
            .store(in: &cancellables)
    }

    // MARK: Lifecycle

    /// Call once when the UI first appears.
    func launch() {
        guard !launched else { return }
        launched = true
        startSession()
    }

    func startSession() {
        guard !sessionActive else { return }
        sessionActive = true
        refreshDevice()
        session.start()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.pushVitals() }
        RunLoop.main.add(timer, forMode: .common)
        vitalsTimer = timer
        pushVitals()
    }

    /// The user is done: stop streaming, let the watch sleep.
    func endSession() {
        guard sessionActive else { return }
        sessionActive = false
        rejection = nil
        graceStop?.cancel()
        graceStop = nil
        vitalsTimer?.invalidate()
        vitalsTimer = nil
        stopMotion()
        micWanted = false
        stopMic()
        keepAliveCoordinator.stop()
        session.stop()
    }

    /// Look for the Mac again after a declined or failed pairing.
    func retry() {
        rejection = nil
        guard sessionActive else { return }
        session.stop()
        session.start()
    }

    func forgetMac() {
        session.forgetMac()
    }

    /// The app came to the front (launch, wrist raise, return from another app).
    func sceneBecameActive() {
        guard sessionActive else { return }
        refreshDevice()
        // Sessions can only be started in the foreground, so this is the moment to catch up.
        evaluateKeepAlive()
        // The same goes for the microphone.
        if micWanted { startMic() }
    }

    // MARK: Input from the views

    func handle(_ output: TouchOutput) {
        switch output {
        case .touch(let phase, let dx, let dy):
            session.sendTouch(phase, dx: dx, dy: dy)
        case .action(let code):
            session.sendAction(code)
        case .localHaptic:
            play(.click)
        }
    }

    func perform(_ code: WatchActionCode) {
        session.sendAction(code)
    }

    /// The June button: held = talking (push-to-talk), released = done.
    func setTalking(_ down: Bool) {
        guard down != talking else { return }
        talking = down
        session.sendAction(.voiceHold, argument: down ? 1 : 0)
        play(down ? .start : .stop)
    }

    /// The Gesture button: the next movement is matched against the gestures recorded on the Mac.
    func armGesture() {
        session.sendAction(.armGesture)
    }

    /// Digital Crown movement in turns, positive = upward.
    func crownMoved(turns: Double) {
        session.sendCrown(delta: turns)
    }

    func play(_ tone: HapticTone) {
        guard hapticsEnabled else { return }
        services.haptics.play(tone)
    }

    // MARK: Link

    private func linkStateChanged(_ state: LinkClientState) {
        var connected = false
        switch state {
        case .rejected(let reason):
            if rejection != reason { rejection = reason }
        case .connected:
            connected = true
            if rejection != nil { rejection = nil }
        case .handshaking, .awaitingApproval:
            if rejection != nil { rejection = nil }
        case .idle, .searching:
            break
        }
        guard connected != linkConnected else { return }
        linkConnected = connected
        if connected {
            startMotion(rateHz: session.streamConfig.sampleRateHz)
        } else {
            stopMotion()
            macPaused = false
            lastAssistantState = .off
            if talking { talking = false }
        }
        evaluateKeepAlive()
    }

    private func macStateChanged(_ flags: MacStateFlags) {
        let paused = flags.contains(.paused)
        guard paused != macPaused else { return }
        macPaused = paused
        evaluateKeepAlive()
    }

    private func streamConfigChanged(_ config: StreamConfig) {
        if motionRunning { startMotion(rateHz: config.sampleRateHz) }
    }

    // MARK: Motion

    private func startMotion(rateHz: Int) {
        let problem = services.motion.unavailableReason
        if problem != motionProblem { motionProblem = problem }
        let session = self.session
        services.motion.start(rateHz: rateHz) { gyro, accel, gravity, quaternion in
            session.submitMotion(gyro: gyro, accel: accel, gravity: gravity, quaternion: quaternion)
        }
        motionRunning = true
    }

    private func stopMotion() {
        guard motionRunning else { return }
        motionRunning = false
        services.motion.stop()
    }

    // MARK: June

    private func assistantStateChanged(_ state: AssistantWatchState) {
        let old = lastAssistantState
        lastAssistantState = state
        // While the wearer holds the June button they already feel the press; skip the echo.
        if let tone = JuneLook.haptic(from: old, to: state), !(talking && state == .listening) {
            play(tone)
        }
    }

    // MARK: Microphone (June)

    private func audioRequestChanged(_ on: Bool) {
        micWanted = on
        if on { startMic() } else { stopMic() }
    }

    private func startMic() {
        guard let mic = services.microphone, !mic.isRunning, !micStarting else { return }
        micStarting = true
        let session = self.session
        mic.start(sink: { session.submitAudio($0) }) { [weak self] problem in
            guard let self else { return }
            self.micStarting = false
            if !self.micWanted {                 // the Mac changed its mind while we were starting
                mic.stop()
                self.micLive = false
                return
            }
            if self.micProblem != problem { self.micProblem = problem }
            let live = problem == nil && mic.isRunning
            if self.micLive != live { self.micLive = live }
            if live { self.play(.start) }
        }
    }

    private func stopMic() {
        services.microphone?.stop()
        if micLive { micLive = false }
        if micProblem != nil { micProblem = nil }
    }

    // MARK: Keep-alive

    /// Start when the link is up and the Mac is not paused; once running, keep going through
    /// pauses and short drop-outs; give up after a while without a Mac. `endSession()` stops it.
    private func evaluateKeepAlive() {
        guard sessionActive else { return }
        if linkConnected {
            graceStop?.cancel()
            graceStop = nil
            if !macPaused { keepAliveCoordinator.start() }
        } else if keepAliveCoordinator.isWanted, graceStop == nil {
            let item = DispatchWorkItem { [weak self] in
                guard let self, !self.linkConnected else { return }
                self.graceStop = nil
                self.keepAliveCoordinator.stop()
            }
            graceStop = item
            DispatchQueue.main.asyncAfter(deadline: .now() + disconnectGrace, execute: item)
        }
    }

    private func keepAliveChanged() {
        if keepAlive != keepAliveCoordinator.state { keepAlive = keepAliveCoordinator.state }
        if heartRate != keepAliveCoordinator.heartRate { heartRate = keepAliveCoordinator.heartRate }
        pushVitals()
    }

    // MARK: Device

    private func refreshDevice() {
        let now = services.device.wearing()
        if now != wearing { wearing = now }
        session.setWearing(rightWrist: now.rightWrist, crownLeft: now.crownLeft)
        services.motion.setWearing(now)
    }

    /// About once a second, and whenever keep-alive or heart rate changes.
    private func pushVitals() {
        let info = services.device.battery()
        if info != battery { battery = info }
        session.setVitals(battery: info.percent, heartRate: heartRate,
                          keepAliveActive: keepAliveCoordinator.isActive, charging: info.charging)
    }
}
