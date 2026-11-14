import Foundation

/// Constants shared by both ends of the link.
public enum Wire {
    public static let protocolVersion: UInt8 = 1

    // Bluetooth LE GATT layout. The Mac is the peripheral, the watch is the central.
    public static let serviceUUID = "8E7F1A10-5B6C-4D2E-9A3F-6C1D2B7E4F01"
    /// watch -> Mac. Write-without-response for sensor data, write-with-response for reliable messages.
    public static let streamCharUUID = "8E7F1A11-5B6C-4D2E-9A3F-6C1D2B7E4F01"
    /// Mac -> watch. Notifications (haptics, state, handshake replies).
    public static let controlCharUUID = "8E7F1A12-5B6C-4D2E-9A3F-6C1D2B7E4F01"
    public static let advertisedName = "Gauntlet"

    /// Loopback-only TCP port used by the simulator / `fakewatch` developer link.
    public static let devLinkPort: UInt16 = 47231

    public static let motionHeaderSize = 23
    public static let motionSampleSize = 12
    public static let maxSamplesPerPacket = 8

    // Fixed-point scales.
    static let quatScale = 32767.0
    static let gravityScale = 16384.0       // +-2 g of headroom on a unit vector
    static let gyroScale = 1000.0           // rad/s  -> +-32.7 rad/s
    static let accelScale = 4096.0          // g      -> +-8 g
    static let touchScale = 8.0             // points -> 1/8 pt
    static let crownScale = 2000.0          // crown units -> +-16

    /// Largest number of IMU samples that fit in a payload of `maxPayload` bytes.
    public static func samplesThatFit(maxPayload: Int) -> Int {
        max(0, min(maxSamplesPerPacket, (maxPayload - motionHeaderSize) / motionSampleSize))
    }
}

// MARK: - Watch -> Mac

public struct MotionFlags: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    /// Watch is worn on the right wrist.
    public static let rightWrist = MotionFlags(rawValue: 1 << 0)
    /// Digital Crown is on the left side of the display as worn.
    public static let crownLeft = MotionFlags(rawValue: 1 << 1)
    /// A finger is currently resting on the watch display.
    public static let touching = MotionFlags(rawValue: 1 << 2)
}

/// One inertial sample in the watch's device frame.
public struct MotionSample: Equatable, Sendable {
    /// Rotation rate, rad/s.
    public var gyro: SIMD3<Double>
    /// User acceleration (gravity removed), in g.
    public var accel: SIMD3<Double>
    public init(gyro: SIMD3<Double>, accel: SIMD3<Double>) {
        self.gyro = gyro
        self.accel = accel
    }
}

/// A batch of consecutive IMU samples plus the fused attitude at the last one.
public struct MotionPacket: Equatable, Sendable {
    public var seq: UInt8
    public var flags: MotionFlags
    /// Watch monotonic clock at the last sample, milliseconds (wraps after ~49 days).
    public var timestampMs: UInt32
    /// Spacing between samples, milliseconds.
    public var sampleIntervalMs: UInt8
    /// Attitude quaternion (x, y, z, w) at the last sample: rotates device-frame
    /// vectors into the Z-up reference frame.
    public var quaternion: SIMD4<Double>
    /// Unit gravity vector in the device frame at the last sample.
    public var gravity: SIMD3<Double>
    /// Oldest first.
    public var samples: [MotionSample]

    public init(seq: UInt8, flags: MotionFlags, timestampMs: UInt32, sampleIntervalMs: UInt8,
                quaternion: SIMD4<Double>, gravity: SIMD3<Double>, samples: [MotionSample]) {
        self.seq = seq
        self.flags = flags
        self.timestampMs = timestampMs
        self.sampleIntervalMs = sampleIntervalMs
        self.quaternion = quaternion
        self.gravity = gravity
        self.samples = samples
    }
}

public enum TouchPhase: UInt8, Sendable { case began = 0, moved = 1, ended = 2, cancelled = 3 }

/// Finger movement on the watch display, used as a tiny precision trackpad.
public struct TouchEvent: Equatable, Sendable {
    public var seq: UInt8
    public var phase: TouchPhase
    /// Movement since the previous event, in watch points.
    public var dx: Double
    public var dy: Double
    public init(seq: UInt8, phase: TouchPhase, dx: Double, dy: Double) {
        self.seq = seq; self.phase = phase; self.dx = dx; self.dy = dy
    }
}

/// Digital Crown rotation since the previous event (positive = scroll content up).
public struct CrownEvent: Equatable, Sendable {
    public var seq: UInt8
    public var delta: Double
    public init(seq: UInt8, delta: Double) { self.seq = seq; self.delta = delta }
}

/// Discrete things the wearer did on the watch itself.
public enum WatchActionCode: UInt8, Sendable, CaseIterable {
    case screenTap = 1
    case screenDoubleTap = 2
    case screenLongPress = 3
    /// The system finger double-pinch gesture (watchOS "Double Tap").
    case handDoubleTap = 4
    case togglePause = 5
    case recenter = 6
    case toggleDrag = 7
    case toggleScrollMode = 8
    case rightClick = 9
    case leftClick = 10
    /// Arm custom-gesture recognition: the next movement is matched against recorded gestures.
    case armGesture = 11
    /// Push-to-talk for June. `argument` 1 = pressed, 0 = released.
    case voiceHold = 12
}

public struct WatchAction: Equatable, Sendable {
    public var seq: UInt8
    public var code: WatchActionCode
    public var argument: UInt8
    public init(seq: UInt8, code: WatchActionCode, argument: UInt8 = 0) {
        self.seq = seq; self.code = code; self.argument = argument
    }
}

public struct StatusFlags: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let rightWrist = StatusFlags(rawValue: 1 << 0)
    public static let crownLeft = StatusFlags(rawValue: 1 << 1)
    /// A keep-alive session (workout / extended runtime) is running.
    public static let keepAliveActive = StatusFlags(rawValue: 1 << 2)
    public static let charging = StatusFlags(rawValue: 1 << 3)
}

/// Slow-changing watch state, sent about once a second. Doubles as a heartbeat.
public struct WatchStatus: Equatable, Sendable {
    public var seq: UInt8
    /// 0...100, or nil when unknown.
    public var battery: Int?
    /// Beats per minute, or nil when unavailable.
    public var heartRate: Int?
    public var flags: StatusFlags
    /// Signal strength of the Mac as seen by the watch, dBm (0 = unknown).
    public var rssi: Int
    public var sampleRateHz: Int
    public init(seq: UInt8, battery: Int?, heartRate: Int?, flags: StatusFlags, rssi: Int, sampleRateHz: Int) {
        self.seq = seq; self.battery = battery; self.heartRate = heartRate
        self.flags = flags; self.rssi = rssi; self.sampleRateHz = sampleRateHz
    }
}

/// 20 ms-ish of microphone audio from the watch: one self-contained IMA ADPCM block
/// (see `IMAADPCM`), 16 kHz mono. Sent unreliably, like motion; the Mac fills small gaps with silence.
public struct AudioFrame: Equatable, Sendable {
    public var seq: UInt16
    /// Watch monotonic clock at the first sample, milliseconds.
    public var timestampMs: UInt32
    /// `IMAADPCM.encodeBlock` output: 3-byte header (predictor, step index) + packed nibbles.
    public var payload: Data
    public init(seq: UInt16, timestampMs: UInt32, payload: Data) {
        self.seq = seq; self.timestampMs = timestampMs; self.payload = payload
    }
    /// Bytes of a `.audio` message besides the payload.
    public static let messageOverhead = 7
}

/// First message of a session.
public struct Hello: Equatable, Sendable {
    public var version: UInt8
    /// Stable random 16-byte identifier of this watch installation.
    public var deviceID: Data
    /// Curve25519 key-agreement public key, 32 bytes.
    public var publicKey: Data
    public var name: String
    public init(version: UInt8 = Wire.protocolVersion, deviceID: Data, publicKey: Data, name: String) {
        self.version = version; self.deviceID = deviceID; self.publicKey = publicKey; self.name = name
    }
}

public enum WatchMessage: Equatable, Sendable {
    case motion(MotionPacket)
    case touch(TouchEvent)
    case crown(CrownEvent)
    case action(WatchAction)
    case status(WatchStatus)
    case hello(Hello)
    /// HMAC-SHA256 over the Mac's nonce, proving possession of the pairing key.
    case authProof(Data)
    case bye
    /// Microphone audio for June. Only sent after the Mac asks with `MacMessage.audioRequest(true)`.
    case audio(AudioFrame)

    private enum Tag {
        static let motion: UInt8 = 0x01, touch: UInt8 = 0x02, crown: UInt8 = 0x03
        static let action: UInt8 = 0x04, status: UInt8 = 0x05, audio: UInt8 = 0x06
        static let hello: UInt8 = 0x10, authProof: UInt8 = 0x11, bye: UInt8 = 0x12
    }

    /// True for messages that must not be dropped (sent with acknowledgement over BLE).
    public var isReliable: Bool {
        switch self {
        case .motion, .touch, .crown, .audio: return false
        case .action, .status, .hello, .authProof, .bye: return true
        }
    }

    public func encoded() -> Data {
        var w = ByteWriter()
        switch self {
        case .motion(let p):
            w.u8(Tag.motion)
            w.u8(p.seq)
            w.u8(UInt8(min(p.samples.count, Wire.maxSamplesPerPacket)))
            w.u8(p.flags.rawValue)
            w.u32(p.timestampMs)
            w.u8(p.sampleIntervalMs)
            w.q16(p.quaternion.x, scale: Wire.quatScale)
            w.q16(p.quaternion.y, scale: Wire.quatScale)
            w.q16(p.quaternion.z, scale: Wire.quatScale)
            w.q16(p.quaternion.w, scale: Wire.quatScale)
            w.q16(p.gravity.x, scale: Wire.gravityScale)
            w.q16(p.gravity.y, scale: Wire.gravityScale)
            w.q16(p.gravity.z, scale: Wire.gravityScale)
            for s in p.samples.prefix(Wire.maxSamplesPerPacket) {
                w.q16(s.gyro.x, scale: Wire.gyroScale)
                w.q16(s.gyro.y, scale: Wire.gyroScale)
                w.q16(s.gyro.z, scale: Wire.gyroScale)
                w.q16(s.accel.x, scale: Wire.accelScale)
                w.q16(s.accel.y, scale: Wire.accelScale)
                w.q16(s.accel.z, scale: Wire.accelScale)
            }
        case .touch(let t):
            w.u8(Tag.touch); w.u8(t.seq); w.u8(t.phase.rawValue); w.u8(0)
            w.q16(t.dx, scale: Wire.touchScale)
            w.q16(t.dy, scale: Wire.touchScale)
        case .crown(let c):
            w.u8(Tag.crown); w.u8(c.seq)
            w.q16(c.delta, scale: Wire.crownScale)
        case .action(let a):
            w.u8(Tag.action); w.u8(a.seq); w.u8(a.code.rawValue); w.u8(a.argument)
        case .status(let s):
            w.u8(Tag.status); w.u8(s.seq)
            w.u8(s.battery.map { UInt8(max(0, min(100, $0))) } ?? 255)
            w.u8(s.heartRate.map { UInt8(max(1, min(254, $0))) } ?? 0)
            w.u8(s.flags.rawValue)
            w.i8(Int8(max(-127, min(127, s.rssi))))
            w.u8(UInt8(max(0, min(255, s.sampleRateHz))))
        case .hello(let h):
            w.u8(Tag.hello); w.u8(h.version)
            w.raw(h.deviceID.fixed(16))
            w.raw(h.publicKey.fixed(32))
            w.string(h.name)
        case .authProof(let proof):
            w.u8(Tag.authProof)
            w.raw(proof.fixed(32))
        case .bye:
            w.u8(Tag.bye)
        case .audio(let a):
            w.u8(Tag.audio); w.u16(a.seq); w.u32(a.timestampMs)
            w.raw(a.payload)
        }
        return w.data
    }

    public static func decode(_ data: Data) throws -> WatchMessage {
        var r = ByteReader(data)
        let tag = try r.u8()
        switch tag {
        case Tag.motion:
            let seq = try r.u8()
            let count = Int(try r.u8())
            guard count <= Wire.maxSamplesPerPacket else { throw WireError.malformed("sample count \(count)") }
            let flags = MotionFlags(rawValue: try r.u8())
            let ts = try r.u32()
            let dt = try r.u8()
            let q = SIMD4<Double>(try r.q16(scale: Wire.quatScale), try r.q16(scale: Wire.quatScale),
                                  try r.q16(scale: Wire.quatScale), try r.q16(scale: Wire.quatScale))
            let g = SIMD3<Double>(try r.q16(scale: Wire.gravityScale), try r.q16(scale: Wire.gravityScale),
                                  try r.q16(scale: Wire.gravityScale))
            var samples: [MotionSample] = []
            samples.reserveCapacity(count)
            for _ in 0..<count {
                let gyro = SIMD3<Double>(try r.q16(scale: Wire.gyroScale), try r.q16(scale: Wire.gyroScale),
                                         try r.q16(scale: Wire.gyroScale))
                let accel = SIMD3<Double>(try r.q16(scale: Wire.accelScale), try r.q16(scale: Wire.accelScale),
                                          try r.q16(scale: Wire.accelScale))
                samples.append(MotionSample(gyro: gyro, accel: accel))
            }
            return .motion(MotionPacket(seq: seq, flags: flags, timestampMs: ts, sampleIntervalMs: dt,
                                        quaternion: q, gravity: g, samples: samples))
        case Tag.touch:
            let seq = try r.u8()
            guard let phase = TouchPhase(rawValue: try r.u8()) else { throw WireError.malformed("touch phase") }
            _ = try r.u8()
            return .touch(TouchEvent(seq: seq, phase: phase,
                                     dx: try r.q16(scale: Wire.touchScale), dy: try r.q16(scale: Wire.touchScale)))
        case Tag.crown:
            let seq = try r.u8()
            return .crown(CrownEvent(seq: seq, delta: try r.q16(scale: Wire.crownScale)))
        case Tag.action:
            let seq = try r.u8()
            guard let code = WatchActionCode(rawValue: try r.u8()) else { throw WireError.malformed("action code") }
            return .action(WatchAction(seq: seq, code: code, argument: try r.u8()))
        case Tag.status:
            let seq = try r.u8()
            let battery = try r.u8()
            let hr = try r.u8()
            let flags = StatusFlags(rawValue: try r.u8())
            let rssi = Int(try r.i8())
            let rate = Int(try r.u8())
            return .status(WatchStatus(seq: seq, battery: battery == 255 ? nil : Int(battery),
                                       heartRate: hr == 0 ? nil : Int(hr), flags: flags,
                                       rssi: rssi, sampleRateHz: rate))
        case Tag.hello:
            let version = try r.u8()
            let id = try r.raw(16)
            let key = try r.raw(32)
            return .hello(Hello(version: version, deviceID: id, publicKey: key, name: try r.string()))
        case Tag.authProof:
            return .authProof(try r.raw(32))
        case Tag.bye:
            return .bye
        case Tag.audio:
            let seq = try r.u16()
            let ts = try r.u32()
            let payload = try r.raw(r.remaining)
            guard payload.count >= IMAADPCM.headerSize else { throw WireError.malformed("audio block") }
            return .audio(AudioFrame(seq: seq, timestampMs: ts, payload: payload))
        default:
            throw WireError.unknownType(tag)
        }
    }
}

// MARK: - Mac -> Watch

/// What June is doing, so the watch can show it (ring colour, haptics).
public enum AssistantWatchState: UInt8, Sendable, CaseIterable {
    case off = 0
    /// Listening for "Hey June" (the mic is live, nothing leaves the Mac).
    case waiting = 1
    /// Recording a command.
    case listening = 2
    case thinking = 3
    case idle = 4
}

/// Haptic patterns the Mac can ask the watch to play.
public enum HapticPattern: UInt8, Sendable, CaseIterable {
    case click = 1
    case doubleClick = 2
    case rightClick = 3
    case dragStart = 4
    case dragEnd = 5
    case engage = 6
    case disengage = 7
    case scrollTick = 8
    case success = 9
    case failure = 10
    case notify = 11
    case edge = 12
}

public struct MacStateFlags: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    /// The pointer is currently following the arm.
    public static let engaged = MacStateFlags(rawValue: 1 << 0)
    public static let dragging = MacStateFlags(rawValue: 1 << 1)
    public static let scrollMode = MacStateFlags(rawValue: 1 << 2)
    /// Output goes to the Dojo's virtual screen rather than the real cursor.
    public static let sandbox = MacStateFlags(rawValue: 1 << 3)
    public static let paused = MacStateFlags(rawValue: 1 << 4)
    public static let needsCalibration = MacStateFlags(rawValue: 1 << 5)
}

/// What the Mac wants the watch to stream.
public struct StreamConfig: Equatable, Sendable {
    public var sampleRateHz: Int
    public var samplesPerPacket: Int
    public init(sampleRateHz: Int = 100, samplesPerPacket: Int = 2) {
        self.sampleRateHz = sampleRateHz
        self.samplesPerPacket = samplesPerPacket
    }
}

public struct HelloAck: Equatable, Sendable {
    public var version: UInt8
    public var deviceID: Data
    public var publicKey: Data
    /// Fresh 16-byte challenge for this session.
    public var nonce: Data
    /// True when the Mac already trusts this watch.
    public var known: Bool
    public var name: String
    public init(version: UInt8 = Wire.protocolVersion, deviceID: Data, publicKey: Data,
                nonce: Data, known: Bool, name: String) {
        self.version = version; self.deviceID = deviceID; self.publicKey = publicKey
        self.nonce = nonce; self.known = known; self.name = name
    }
}

public enum AuthStatus: UInt8, Sendable {
    case accepted = 1
    /// Waiting for the user to confirm the pairing code on the Mac.
    case pendingApproval = 2
    case rejected = 3
}

public struct AuthResult: Equatable, Sendable {
    public var status: AuthStatus
    /// HMAC-SHA256 proving the Mac holds the same pairing key.
    public var proof: Data
    public init(status: AuthStatus, proof: Data) { self.status = status; self.proof = proof }
}

public enum MacMessage: Equatable, Sendable {
    case haptic(HapticPattern)
    case state(MacStateFlags)
    case config(StreamConfig)
    case ping
    case helloAck(HelloAck)
    case authResult(AuthResult)
    case assistantState(AssistantWatchState)
    /// Start (true) or stop (false) streaming the watch microphone.
    case audioRequest(Bool)

    private enum Tag {
        static let haptic: UInt8 = 0x80, state: UInt8 = 0x81, config: UInt8 = 0x82, ping: UInt8 = 0x83
        static let assistantState: UInt8 = 0x84, audioRequest: UInt8 = 0x85
        static let helloAck: UInt8 = 0x90, authResult: UInt8 = 0x91
    }

    public func encoded() -> Data {
        var w = ByteWriter()
        switch self {
        case .haptic(let p):
            w.u8(Tag.haptic); w.u8(p.rawValue)
        case .state(let f):
            w.u8(Tag.state); w.u8(f.rawValue)
        case .config(let c):
            w.u8(Tag.config)
            w.u8(UInt8(max(1, min(200, c.sampleRateHz))))
            w.u8(UInt8(max(1, min(Wire.maxSamplesPerPacket, c.samplesPerPacket))))
        case .ping:
            w.u8(Tag.ping)
        case .helloAck(let a):
            w.u8(Tag.helloAck); w.u8(a.version)
            w.raw(a.deviceID.fixed(16))
            w.raw(a.publicKey.fixed(32))
            w.raw(a.nonce.fixed(16))
            w.u8(a.known ? 1 : 0)
            w.string(a.name)
        case .authResult(let r):
            w.u8(Tag.authResult); w.u8(r.status.rawValue)
            w.raw(r.proof.fixed(32))
        case .assistantState(let s):
            w.u8(Tag.assistantState); w.u8(s.rawValue)
        case .audioRequest(let on):
            w.u8(Tag.audioRequest); w.u8(on ? 1 : 0)
        }
        return w.data
    }

    public static func decode(_ data: Data) throws -> MacMessage {
        var r = ByteReader(data)
        let tag = try r.u8()
        switch tag {
        case Tag.haptic:
            guard let p = HapticPattern(rawValue: try r.u8()) else { throw WireError.malformed("haptic") }
            return .haptic(p)
        case Tag.state:
            return .state(MacStateFlags(rawValue: try r.u8()))
        case Tag.config:
            return .config(StreamConfig(sampleRateHz: Int(try r.u8()), samplesPerPacket: Int(try r.u8())))
        case Tag.ping:
            return .ping
        case Tag.helloAck:
            let version = try r.u8()
            let id = try r.raw(16)
            let key = try r.raw(32)
            let nonce = try r.raw(16)
            let known = try r.u8() != 0
            return .helloAck(HelloAck(version: version, deviceID: id, publicKey: key,
                                      nonce: nonce, known: known, name: try r.string()))
        case Tag.authResult:
            guard let status = AuthStatus(rawValue: try r.u8()) else { throw WireError.malformed("auth status") }
            return .authResult(AuthResult(status: status, proof: try r.raw(32)))
        case Tag.assistantState:
            guard let state = AssistantWatchState(rawValue: try r.u8()) else { throw WireError.malformed("assistant state") }
            return .assistantState(state)
        case Tag.audioRequest:
            return .audioRequest(try r.u8() != 0)
        default:
            throw WireError.unknownType(tag)
        }
    }
}

extension Data {
    /// Exactly `count` bytes: truncated or zero-padded.
    func fixed(_ count: Int) -> Data {
        if self.count == count { return self }
        if self.count > count { return self.prefix(count) }
        return self + Data(repeating: 0, count: count - self.count)
    }

    public var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
