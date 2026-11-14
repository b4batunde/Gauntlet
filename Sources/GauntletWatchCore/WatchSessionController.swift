import Foundation
import Combine
import GauntletProtocol
import GauntletLink

/// Everything the watch app does except UI and reading sensors.
///
/// The watch shell feeds it raw sensor values and user actions; it handles pairing,
/// batching, back-pressure and reconnection, and publishes state for SwiftUI.
/// `@Published` properties change on the main thread. Input methods are safe from any thread.
public final class WatchSessionController: ObservableObject, LinkClientDelegate {

    public enum Route {
        /// Normal operation: Bluetooth LE straight to the Mac.
        case bluetooth
        /// Simulator / test rig: TCP to the Mac app's developer link.
        case developerLink(host: String)
    }

    // MARK: Published state (main thread)

    @Published public private(set) var state: LinkClientState = .idle
    /// What the Mac is currently doing with our input.
    @Published public private(set) var macState: MacStateFlags = []
    /// What the Mac wants us to stream.
    @Published public private(set) var streamConfig = StreamConfig()
    /// Motion packets sent during the last second.
    @Published public private(set) var packetsPerSecond = 0
    /// Mac signal strength in dBm, 0 when unknown.
    @Published public private(set) var signal = 0
    /// What June is doing on the Mac (drives the watch ring).
    @Published public private(set) var assistantState: AssistantWatchState = .off
    /// The Mac wants microphone audio. The watch shell starts/stops the mic when this changes.
    @Published public private(set) var audioRequested = false

    /// Play this pattern on the Taptic Engine. Called on the main thread.
    public var onHaptic: ((HapticPattern) -> Void)?
    /// The Mac changed the requested sample rate. Called on the main thread.
    public var onStreamConfig: ((StreamConfig) -> Void)?
    /// The Mac asked to start (true) or stop (false) microphone audio. Called on the main thread.
    public var onAudioRequest: ((Bool) -> Void)?
    /// June changed state on the Mac. Called on the main thread.
    public var onAssistantState: ((AssistantWatchState) -> Void)?

    public var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    // MARK: Lifecycle

    public convenience init(deviceName: String, route: Route = .bluetooth, defaults: UserDefaults = .standard) {
        let queue = DispatchQueue(label: "gauntlet.watch.link", qos: .userInteractive)
        let transport: LinkTransport
        switch route {
        case .bluetooth: transport = BLECentralTransport(queue: queue, defaults: defaults)
        case .developerLink(let host): transport = TCPClientTransport(host: host, queue: queue)
        }
        self.init(deviceName: deviceName, identity: LinkIdentity.loadOrCreate(defaults: defaults),
                  transport: transport, queue: queue)
    }

    /// Designated initialiser; pass your own transport for tests.
    public init(deviceName: String, identity: LinkIdentity, transport: LinkTransport, queue: DispatchQueue) {
        self.queue = queue
        self.transport = transport
        client = LinkClient(identity: identity, deviceName: deviceName, transport: transport, queue: queue)
        client.delegate = self
    }

    public func start() {
        queue.async { self.startOnQueue() }
    }

    private func startOnQueue() {
        guard !running else { return }
        running = true
        client.start()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.everySecond() }
        timer.resume()
        statusTimer = timer
    }

    public func stop() {
        queue.async {
            guard self.running else { return }
            self.running = false
            self.statusTimer?.cancel()
            self.statusTimer = nil
            self.client.stop()
            self.samples.removeAll()
        }
    }

    /// Forget the paired Mac; the next connection will ask to pair again if the Mac does not know us.
    public func forgetMac() {
        queue.async {
            (self.transport as? BLECentralTransport)?.forgetRememberedPeer()
            self.transport.disconnectPeer()
        }
    }

    // MARK: Sensor input (any thread)

    /// One fused IMU sample, in the watch's device frame.
    /// - Parameters:
    ///   - gyro: rotation rate, rad/s.
    ///   - accel: user acceleration (gravity removed), g.
    ///   - gravity: unit gravity vector.
    ///   - quaternion: attitude (x, y, z, w).
    public func submitMotion(gyro: SIMD3<Double>, accel: SIMD3<Double>,
                             gravity: SIMD3<Double>, quaternion: SIMD4<Double>) {
        let arrived = ProcessInfo.processInfo.systemUptime
        queue.async {
            guard self.client.isConnected else {
                self.samples.removeAll(keepingCapacity: true)
                self.lastSampleTime = 0
                return
            }
            // The system may deliver slower than requested (or cap the rate). The Mac integrates
            // rotation over this interval, so it has to be the real one.
            if self.lastSampleTime > 0 {
                let gap = arrived - self.lastSampleTime
                if gap > 0.001, gap < 0.25 { self.measuredInterval += 0.05 * (gap - self.measuredInterval) }
            } else {
                self.measuredInterval = 1.0 / Double(max(10, min(100, self.config.sampleRateHz)))
            }
            self.lastSampleTime = arrived
            self.samples.append(MotionSample(gyro: gyro, accel: accel))
            let fit = max(1, Wire.samplesThatFit(maxPayload: self.client.maxPayload))
            let wanted = max(1, min(self.config.samplesPerPacket, fit))
            guard self.samples.count >= wanted else { return }
            self.motionSeq &+= 1
            var flags: MotionFlags = []
            if self.rightWrist { flags.insert(.rightWrist) }
            if self.crownLeft { flags.insert(.crownLeft) }
            if self.touching { flags.insert(.touching) }
            let interval = self.measuredInterval * 1000
            let packet = MotionPacket(
                seq: self.motionSeq, flags: flags,
                timestampMs: UInt32(truncatingIfNeeded: Int(ProcessInfo.processInfo.systemUptime * 1000)),
                sampleIntervalMs: UInt8(max(1, min(255, Int(interval.rounded())))),
                quaternion: quaternion, gravity: gravity,
                samples: Array(self.samples.prefix(Wire.maxSamplesPerPacket)))
            self.samples.removeAll(keepingCapacity: true)
            self.client.send(.motion(packet))
            self.sentThisSecond += 1
        }
    }

    public func setWearing(rightWrist: Bool, crownLeft: Bool) {
        queue.async { self.rightWrist = rightWrist; self.crownLeft = crownLeft }
    }

    /// Finger moved on the display. Deltas in points since the previous call.
    public func sendTouch(_ phase: TouchPhase, dx: Double = 0, dy: Double = 0) {
        queue.async {
            switch phase {
            case .began:
                self.touching = true
                self.sendEvent { .touch(TouchEvent(seq: $0, phase: .began, dx: 0, dy: 0)) }
            case .moved:
                self.touching = true
                self.touchAccumulator += SIMD2(dx, dy)
                self.scheduleFlush()
            case .ended, .cancelled:
                self.flushCoalesced()
                self.touching = false
                self.sendEvent { .touch(TouchEvent(seq: $0, phase: phase, dx: 0, dy: 0)) }
            }
        }
    }

    /// Digital Crown moved by `delta` since the previous call.
    public func sendCrown(delta: Double) {
        queue.async {
            self.crownAccumulator += delta
            self.scheduleFlush()
        }
    }

    public func sendAction(_ code: WatchActionCode, argument: UInt8 = 0) {
        queue.async {
            self.flushCoalesced()
            self.sendEvent { .action(WatchAction(seq: $0, code: code, argument: argument)) }
        }
    }

    /// 16 kHz mono PCM from the microphone, any amount at a time, from any thread.
    /// Encoded as IMA ADPCM and sent in blocks that fit one radio packet (about 20 ms each).
    /// Dropped unless the Mac has asked for audio and the link is up.
    public func submitAudio(_ pcm: [Int16]) {
        queue.async {
            guard self.client.isConnected, self.audioOn else {
                self.audioPending.removeAll(keepingCapacity: true)
                self.audioState = IMAADPCM.State()
                return
            }
            self.audioPending.append(contentsOf: pcm)
            let room = self.client.maxPayload - AudioFrame.messageOverhead
            let perBlock = min(320, IMAADPCM.samplesThatFit(bytes: room) & ~1)
            guard perBlock >= 32 else { return }               // link not ready for audio yet
            while self.audioPending.count >= perBlock {
                let block = Array(self.audioPending.prefix(perBlock))
                self.audioPending.removeFirst(perBlock)
                let payload = IMAADPCM.encodeBlock(block, state: &self.audioState)
                self.audioSeq &+= 1
                let ts = UInt32(truncatingIfNeeded: Int(ProcessInfo.processInfo.systemUptime * 1000))
                self.client.send(.audio(AudioFrame(seq: self.audioSeq, timestampMs: ts, payload: payload)))
            }
        }
    }

    public func setVitals(battery: Int?, heartRate: Int?, keepAliveActive: Bool, charging: Bool) {
        queue.async {
            self.battery = battery
            self.heartRate = heartRate
            self.keepAliveActive = keepAliveActive
            self.charging = charging
        }
    }

    // MARK: Internals (link queue)

    private let queue: DispatchQueue
    private let transport: LinkTransport
    private let client: LinkClient
    private var running = false
    private var statusTimer: DispatchSourceTimer?
    private var config = StreamConfig()

    private var samples: [MotionSample] = []
    private var lastSampleTime: TimeInterval = 0
    private var measuredInterval = 0.01
    private var motionSeq: UInt8 = 0
    private var eventSeq: UInt8 = 0
    private var sentThisSecond = 0
    private var rightWrist = false
    private var crownLeft = false
    private var touching = false
    private var touchAccumulator = SIMD2<Double>.zero
    private var crownAccumulator = 0.0
    private var flushScheduled = false
    private var battery: Int?
    private var heartRate: Int?
    private var keepAliveActive = false
    private var charging = false
    private var audioOn = false
    private var audioPending: [Int16] = []
    private var audioState = IMAADPCM.State()
    private var audioSeq: UInt16 = 0

    private func sendEvent(_ make: (UInt8) -> WatchMessage) {
        eventSeq &+= 1
        client.send(make(eventSeq))
    }

    /// Crown and touch arrive in bursts; fold them into at most ~60 messages a second.
    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + 0.016) { [weak self] in self?.flushCoalesced() }
    }

    private func flushCoalesced() {
        flushScheduled = false
        if touchAccumulator != .zero {
            let d = touchAccumulator
            touchAccumulator = .zero
            sendEvent { .touch(TouchEvent(seq: $0, phase: .moved, dx: d.x, dy: d.y)) }
        }
        if crownAccumulator != 0 {
            let delta = crownAccumulator
            crownAccumulator = 0
            sendEvent { .crown(CrownEvent(seq: $0, delta: delta)) }
        }
    }

    private func everySecond() {
        let sent = sentThisSecond
        sentThisSecond = 0
        let rssi = client.rssi
        if client.isConnected {
            var flags: StatusFlags = []
            if rightWrist { flags.insert(.rightWrist) }
            if crownLeft { flags.insert(.crownLeft) }
            if keepAliveActive { flags.insert(.keepAliveActive) }
            if charging { flags.insert(.charging) }
            let battery = self.battery, heartRate = self.heartRate, rate = config.sampleRateHz
            sendEvent { .status(WatchStatus(seq: $0, battery: battery, heartRate: heartRate, flags: flags,
                                            rssi: rssi, sampleRateHz: rate)) }
        }
        DispatchQueue.main.async {
            self.packetsPerSecond = sent
            self.signal = rssi
        }
    }

    // MARK: LinkClientDelegate (link queue)

    public func linkClient(_ client: LinkClient, didChange state: LinkClientState) {
        if case .connected = state {} else {
            samples.removeAll()
            touchAccumulator = .zero
            crownAccumulator = 0
            // A lost link closes the mic; the Mac asks again after reconnecting.
            audioOn = false
            audioPending.removeAll()
            audioState = IMAADPCM.State()
        }
        let connected: Bool
        if case .connected = state { connected = true } else { connected = false }
        DispatchQueue.main.async {
            self.state = state
            if !connected {
                self.macState = []
                self.assistantState = .off
                if self.audioRequested {
                    self.audioRequested = false
                    self.onAudioRequest?(false)
                }
            }
        }
    }

    public func linkClient(_ client: LinkClient, didReceive message: MacMessage) {
        switch message {
        case .haptic(let pattern):
            DispatchQueue.main.async { self.onHaptic?(pattern) }
        case .state(let flags):
            DispatchQueue.main.async { self.macState = flags }
        case .config(let new):
            config = new
            lastSampleTime = 0              // re-seed the measured interval at the new rate
            DispatchQueue.main.async {
                self.streamConfig = new
                self.onStreamConfig?(new)
            }
        case .assistantState(let state):
            DispatchQueue.main.async {
                self.assistantState = state
                self.onAssistantState?(state)
            }
        case .audioRequest(let on):
            audioOn = on
            if !on { audioPending.removeAll(keepingCapacity: true); audioState = IMAADPCM.State() }
            DispatchQueue.main.async {
                self.audioRequested = on
                self.onAudioRequest?(on)
            }
        case .ping, .helloAck, .authResult:
            break
        }
    }
}
