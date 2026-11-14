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
    private var consecutiveDrops = 0
    /// Gaps up to this many frames are filled with silence so speech timing stays truthful.
    private static let maxFilledFrames = 5
    /// After this many frames in a row look stale, assume the watch restarted its counter and resync.
    private static let resyncAfterDrops = 10

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
        lastSeq = nil                               // a new connection starts a new sequence
        consecutiveDrops = 0
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
        consecutiveDrops = 0
        received = 0
        lost = 0
        lock.unlock()
        requestAudio?(true)
    }

    public func stop() {
        lock.lock()
        handler = nil
        let debugRunning = debug != nil
        lock.unlock()
        if !debugRunning { requestAudio?(false) }
    }

    // MARK: Debug capture

    public enum DebugError: Error, Equatable {
        /// Another debug recording is already running.
        case busy
        /// The watch sent no audio (not connected, mic not permitted, or app in the background).
        case noAudio
        case writeFailed(String)
    }

    /// Records `seconds` of watch microphone audio to a 16 kHz 16-bit mono WAV, for checking
    /// audio quality. Works whether or not June is listening. Completion runs on the main thread
    /// with the file URL (default: ~/Library/Logs/Gauntlet/watch-mic-<time>.wav).
    public func recordDebugWAV(seconds: Double = 5, to url: URL? = nil,
                               completion: @escaping (Result<URL, DebugError>) -> Void) {
        let target = url ?? Self.defaultDebugURL()
        let wanted = max(1, Int(seconds * VoiceAudioFormat.sampleRate))
        lock.lock()
        guard debug == nil else {
            lock.unlock()
            DispatchQueue.main.async { completion(.failure(.busy)) }
            return
        }
        let owns = handler == nil
        let capture = DebugCapture(url: target, wanted: wanted, ownsRequest: owns, completion: completion)
        debug = capture
        if owns { lastSeq = nil; consecutiveDrops = 0 }
        lock.unlock()
        if owns { requestAudio?(true) }
        // Give the watch a little slack to start its mic; then finish with whatever arrived.
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds + 3) { [weak self, weak capture] in
            guard let self, let capture else { return }
            self.finishDebug(capture)
        }
    }

    public static func defaultDebugURL() -> URL {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/Gauntlet", isDirectory: true)
            ?? FileManager.default.temporaryDirectory
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return logs.appendingPathComponent("watch-mic-\(stamp).wav")
    }

    private final class DebugCapture {
        let url: URL
        let wanted: Int
        let ownsRequest: Bool
        let completion: (Result<URL, DebugError>) -> Void
        var samples: [Int16] = []
        init(url: URL, wanted: Int, ownsRequest: Bool, completion: @escaping (Result<URL, DebugError>) -> Void) {
            self.url = url; self.wanted = wanted; self.ownsRequest = ownsRequest; self.completion = completion
            samples.reserveCapacity(wanted)
        }
    }

    private var debug: DebugCapture?

    /// Ends `capture` if it is still the active one: writes the file and reports.
    private func finishDebug(_ capture: DebugCapture) {
        lock.lock()
        guard debug === capture else { lock.unlock(); return }
        debug = nil
        let stopRequest = capture.ownsRequest && handler == nil
        let pcm = Array(capture.samples.prefix(capture.wanted))
        lock.unlock()
        if stopRequest { requestAudio?(false) }

        let result: Result<URL, DebugError>
        if pcm.isEmpty {
            result = .failure(.noAudio)
        } else {
            do {
                try FileManager.default.createDirectory(at: capture.url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try WAVFile.data(pcm: pcm, sampleRate: Int(VoiceAudioFormat.sampleRate)).write(to: capture.url)
                result = .success(capture.url)
            } catch {
                result = .failure(.writeFailed(error.localizedDescription))
            }
        }
        DispatchQueue.main.async { capture.completion(result) }
    }

    // MARK: Frames

    /// Feed every `WatchMessage.audio` frame here, from any queue.
    public func ingest(_ frame: AudioFrame) {
        guard let samples = try? IMAADPCM.decodeBlock(frame.payload), !samples.isEmpty else { return }
        lock.lock()
        let output = handler
        let capture = debug
        guard output != nil || capture != nil else { lock.unlock(); return }
        var silence = 0
        if let last = lastSeq {
            let gap = Int(frame.seq &- last) - 1
            if gap < 0 || gap > 30_000 {           // duplicate or out of order
                consecutiveDrops += 1
                if consecutiveDrops < Self.resyncAfterDrops {
                    lock.unlock()
                    return
                }
                // Many stale frames in a row: the watch restarted its counter. Follow it.
            } else if gap > 0 {
                lost += gap
                silence = min(gap, Self.maxFilledFrames) * lastFrameSamples
            }
        }
        consecutiveDrops = 0
        lastSeq = frame.seq
        lastFrameSamples = samples.count
        received += 1
        var debugFull = false
        if let capture {
            if silence > 0 { capture.samples.append(contentsOf: repeatElement(Int16(0), count: silence)) }
            capture.samples.append(contentsOf: samples)
            debugFull = capture.samples.count >= capture.wanted
        }
        lock.unlock()

        if let output {
            if silence > 0, let gapBuffer = Self.makeBuffer(count: silence, fill: { _ in 0 }) {
                output(gapBuffer)
            }
            if let buffer = Self.makeBuffer(count: samples.count, fill: { Float(samples[$0]) / 32768 }) {
                output(buffer)
            }
        }
        if debugFull, let capture { finishDebug(capture) }
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

/// Minimal RIFF/WAVE writer: 16-bit little-endian PCM, mono.
public enum WAVFile {
    public static func data(pcm: [Int16], sampleRate: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let dataBytes = UInt32(pcm.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1); u16(1)                                   // PCM, mono
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2))
        u16(2); u16(16)                                  // block align, bits per sample
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        for s in pcm { withUnsafeBytes(of: s.littleEndian) { d.append(contentsOf: $0) } }
        return d
    }
}
