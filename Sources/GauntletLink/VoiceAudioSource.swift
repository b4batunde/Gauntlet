import Foundation
import AVFoundation
import GauntletProtocol

/// A microphone June can listen through: the watch, AirPods, or the Mac's built-in mic.
public protocol VoiceAudioSource: AnyObject {
    /// "Apple Watch", "AirPods Pro", "MacBook Air Microphone".
    var displayName: String { get }
    var isAvailable: Bool { get }
    var onAvailabilityChanged: ((Bool) -> Void)? { get set }
    /// Buffers are 16 kHz mono Float32. Called on the source's own queue.
    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws
    func stop()
}

public enum VoiceAudioFormat {
    public static let sampleRate = 16_000.0
    public static let format: AVAudioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                            sampleRate: sampleRate, channels: 1,
                                                            interleaved: false)!
}

/// The watch's microphone, streamed over the Gauntlet link as IMA ADPCM.
///
/// The Mac side owns the wiring:
/// - route every `WatchMessage.audio` frame to `ingest(_:)` (any queue);
/// - set `requestAudio` to send `MacMessage.audioRequest(_:)` to the watch;
/// - call `setLinkConnected(_:)` when the watch connects or disconnects.
///
/// The watch only streams while a listener is started, so the watch mic is closed otherwise.
public final class WatchMicrophoneSource: VoiceAudioSource, @unchecked Sendable {
    public let displayName: String
    public var onAvailabilityChanged: ((Bool) -> Void)?
    /// Sends `MacMessage.audioRequest(on)` to the watch.
    public var requestAudio: ((Bool) -> Void)?

    /// Frames received since `start`, and frames lost (sequence gaps). For the debug view.
    public var framesReceived: Int { lock.lock(); defer { lock.unlock() }; return received }
    public var framesLost: Int { lock.lock(); defer { lock.unlock() }; return lost }

    private let lock = NSLock()
    private var connected = false
    private var handler: ((AVAudioPCMBuffer) -> Void)?
    private var lastSeq: UInt16?
    private var lastFrameSamples = 320
    private var received = 0
    private var lost = 0
    /// Gaps up to this many frames are filled with silence so speech timing stays truthful.
    private static let maxFilledFrames = 5

    public init(displayName: String = "Apple Watch") {
        self.displayName = displayName
    }

    public var isAvailable: Bool {
        lock.lock(); defer { lock.unlock() }
        return connected
    }

    public func setLinkConnected(_ isConnected: Bool) {
        lock.lock()
        let changed = connected != isConnected
        connected = isConnected
        let streaming = handler != nil
        lock.unlock()
        // The watch forgets the request when the link drops; ask again on reconnect.
        if isConnected, streaming { requestAudio?(true) }
        if changed { onAvailabilityChanged?(isConnected) }
    }

    public func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        lock.lock()
        handler = onBuffer
        lastSeq = nil
        received = 0
        lost = 0
        lock.unlock()
        requestAudio?(true)
    }

    public func stop() {
        lock.lock()
        handler = nil
        lock.unlock()
        requestAudio?(false)
    }

    /// Feed every `WatchMessage.audio` frame here, from any queue.
    public func ingest(_ frame: AudioFrame) {
        guard let samples = try? IMAADPCM.decodeBlock(frame.payload), !samples.isEmpty else { return }
        lock.lock()
        guard let handler else { lock.unlock(); return }
        var silence = 0
        if let last = lastSeq {
            let gap = Int(frame.seq &- last) - 1
            if gap < 0 || gap > 30_000 {           // duplicate or out of order: drop it
                lock.unlock()
                return
            }
            if gap > 0 {
                lost += gap
                silence = min(gap, Self.maxFilledFrames) * lastFrameSamples
            }
        }
        lastSeq = frame.seq
        lastFrameSamples = samples.count
        received += 1
        lock.unlock()

        if silence > 0, let gapBuffer = Self.makeBuffer(count: silence, fill: { _ in 0 }) {
            handler(gapBuffer)
        }
        if let buffer = Self.makeBuffer(count: samples.count, fill: { Float(samples[$0]) / 32768 }) {
            handler(buffer)
        }
    }

    private static func makeBuffer(count: Int, fill: (Int) -> Float) -> AVAudioPCMBuffer? {
        guard count > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: VoiceAudioFormat.format, frameCapacity: AVAudioFrameCount(count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(count)
        for i in 0..<count { channel[i] = fill(i) }
        return buffer
    }
}
