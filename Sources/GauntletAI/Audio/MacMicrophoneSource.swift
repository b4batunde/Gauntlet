import Foundation
import AVFoundation
import CoreAudio
import GauntletLink

/// Reads the Mac's current default input device (built-in mic, or AirPods when they are connected).
enum InputDeviceInfo {
    static func defaultInputDevice() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    static func name(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var cfName: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &cfName)
        guard status == noErr, let cfName else { return nil }
        return cfName.takeRetainedValue() as String
    }
}

/// The Mac's own input, resampled to 16 kHz mono Float32. When AirPods are the current input
/// this reports their name, so the automatic source choice can tell them apart.
public final class MacMicrophoneSource: VoiceAudioSource, @unchecked Sendable {
    public var onAvailabilityChanged: ((Bool) -> Void)?
    private var engine: AVAudioEngine?
    private let lock = NSLock()

    public init() {}

    public var displayName: String {
        if let id = InputDeviceInfo.defaultInputDevice(), let name = InputDeviceInfo.name(of: id) { return name }
        return "Mac Microphone"
    }

    public var isAirPods: Bool { displayName.localizedCaseInsensitiveContains("AirPods") }

    public var isAvailable: Bool { InputDeviceInfo.defaultInputDevice() != nil }

    public func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw JuneError.noMicrophone }
        guard let converter = AVAudioConverter(from: inputFormat, to: VoiceAudioFormat.format) else { throw JuneError.noMicrophone }
        let ratio = VoiceAudioFormat.sampleRate / inputFormat.sampleRate

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: VoiceAudioFormat.format, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil, out.frameLength > 0 { onBuffer(out) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw JuneError.noMicrophone
        }
        lock.lock(); self.engine = engine; lock.unlock()
    }

    public func stop() {
        lock.lock()
        let running = engine
        engine = nil
        lock.unlock()
        guard let running else { return }
        running.inputNode.removeTap(onBus: 0)
        running.stop()
    }
}
