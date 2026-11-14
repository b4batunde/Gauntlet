import Foundation
import AVFoundation
import Speech

/// Turns the audio of one spoken command into text, entirely on this Mac.
/// Returns nil from `init` if on-device recognition isn't available: June never falls back to server speech.
final class CommandTranscriber: @unchecked Sendable {
    private let recognizer: SFSpeechRecognizer
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private var task: SFSpeechRecognitionTask?
    private let lock = NSLock()
    private var latest = ""
    private var finished = false
    private var waiter: CheckedContinuation<String, Never>?
    /// Live transcript, called on a background queue.
    var onPartial: ((String) -> Void)?

    init?(locale: Locale = Locale(identifier: "en-US")) {
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { return nil }
        self.recognizer = recognizer
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = ["June", "Hey June"]
    }

    func start() {
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                self.lock.lock(); self.latest = text; self.lock.unlock()
                self.onPartial?(text)
                if result.isFinal { self.complete() }
            }
            if error != nil { self.complete() }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request.append(buffer)
    }

    /// Ends the audio and waits (at most 2 s) for the final transcript.
    func finish() async -> String {
        request.endAudio()
        let text: String = await withCheckedContinuation { cont in
            lock.lock()
            if finished {
                let t = latest
                lock.unlock()
                cont.resume(returning: t)
                return
            }
            waiter = cont
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [weak self] in self?.complete() }
        }
        task?.cancel()
        return text
    }

    func cancel() {
        task?.cancel()
        request.endAudio()
        complete()
    }

    private func complete() {
        lock.lock()
        finished = true
        let pending = waiter
        waiter = nil
        let text = latest
        lock.unlock()
        pending?.resume(returning: text)
    }
}
