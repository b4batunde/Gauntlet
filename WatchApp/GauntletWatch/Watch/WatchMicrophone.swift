#if os(watchOS)
import Foundation
import AVFoundation

/// The watch microphone as 16 kHz mono Int16, for June.
///
/// watchOS lets an app *start* recording only in the foreground. With the `audio` background
/// mode a recording that is already running continues when the wrist drops and the display
/// sleeps (the workout session keeps the app alive as well). So the mic is started while the
/// app is in front and simply kept running until the Mac stops asking for audio.
final class WatchMicrophone: MicrophoneSource {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "gauntlet.watch.mic", qos: .userInitiated)
    private var converter: AVAudioConverter?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                             channels: 1, interleaved: true)!
    private(set) var isRunning = false
    private var denied = false
    private var observers: [NSObjectProtocol] = []

    var unavailableReason: String? {
        denied ? "Microphone access is off. Turn it on in Settings › Privacy & Security › Microphone." : nil
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    func start(sink: @escaping ([Int16]) -> Void, completion: @escaping (String?) -> Void) {
        guard !isRunning else { completion(nil); return }
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                self.denied = !granted
                guard granted else { completion(self.unavailableReason); return }
                completion(self.startEngine(sink: sink))
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Returns nil when running, otherwise why not.
    private func startEngine(sink: @escaping ([Int16]) -> Void) -> String? {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            return "Could not open the microphone (\(error.localizedDescription)). Open Gauntlet on the watch and try again."
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return "The microphone is not available right now."
        }
        self.converter = converter
        let outputFormat = self.outputFormat
        let queue = self.queue

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            // Convert on the tap thread (cheap), hand the samples off without blocking it.
            let ratio = outputFormat.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
            guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if fed {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                inputStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, out.frameLength > 0, let channel = out.int16ChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
            queue.async { sink(samples) }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            try? session.setActive(false)
            // Typically "cannot start recording" because the app is not in the foreground.
            return "Open Gauntlet on the watch to turn on its microphone."
        }
        isRunning = true
        observeInterruptions(sink: sink)
        return nil
    }

    /// Siri, a call or an alarm takes the mic; pick it back up afterwards if we still can.
    private func observeInterruptions(sink: @escaping ([Int16]) -> Void) {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                            queue: .main) { [weak self] note in
            guard let self, self.isRunning,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self.isRunning = false
            self.engine.inputNode.removeTap(onBus: 0)
            self.engine.stop()
            _ = self.startEngine(sink: sink)
        })
    }
}
#endif
