import Foundation
import AppKit
import AVFoundation
import ApplicationServices
import GauntletProtocol
import GauntletLink
import GauntletEngine

/// June. Hold to talk (or a gesture) → read what is under the cursor → one streaming Gemini call → answer.
///
/// Everything here runs on the main thread; audio arrives on its own queue and is handed to the
/// transcriber directly. Step 2 of the build: push-to-talk and gesture-triggered summarize, explain
/// and translate. Wake word, dictation, the pocket and Notes arrive in later steps.
@MainActor
public final class AssistantController {
    // MARK: Public API (contract)

    /// Always called on the main thread.
    public var onState: ((JuneState) -> Void)?
    public var onCaptureFrame: ((CGRect?) -> Void)?
    public var onPocketChipRequested: ((CGPoint?) -> Void)?
    /// Wired by AppModel to `SystemPointerSink.sendKeyCombo`.
    public var sendKeyCombo: ((UInt16, UInt64) -> Void)?
    /// Wired by AppModel: tells the watch what June is doing (ring, haptics).
    public var sendWatchState: ((AssistantWatchState) -> Void)?

    public var settings: JuneSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            if !settings.enabled { cancel() }
        }
    }

    public private(set) var state: JuneState = .off {
        didSet { onState?(state) }
    }

    public private(set) var audioSources: [VoiceAudioSource]
    /// Wake-word listening is not built yet; this stays false until it is.
    public private(set) var handsFree = false
    public var wakeWordEnabled: Bool {
        get { settings.wakeWordEnabled }
        set { settings.wakeWordEnabled = newValue }
    }

    public init(apiKeyProvider: @escaping () -> String?) {
        self.apiKeyProvider = apiKeyProvider
        self.settings = JuneSettings.load()
        let mic = MacMicrophoneSource()
        self.macMic = mic
        self.audioSources = [mic]
    }

    public func registerSource(_ source: VoiceAudioSource) {
        audioSources.append(source)
    }

    /// AirPods on the Mac → the watch's microphone → the Mac's own microphone.
    public var activeSource: VoiceAudioSource? {
        if let preferred = settings.preferredSource,
           let match = audioSources.first(where: { $0.displayName == preferred && $0.isAvailable }) {
            return match
        }
        if macMic.isAirPods, macMic.isAvailable { return macMic }
        if let watch = audioSources.first(where: { $0 !== macMic && $0.isAvailable }) { return watch }
        return macMic.isAvailable ? macMic : nil
    }

    public func setPreferredSource(_ name: String?) {
        settings.preferredSource = name
    }

    /// Hold-to-talk. `true` starts listening, `false` ends the command.
    public func pushToTalk(isDown: Bool) {
        guard settings.enabled else { return }
        if isDown {
            pttWanted = true
            cancelWork()
            Task { [weak self] in await self?.beginPushToTalk() }
        } else {
            pttWanted = false
            endPushToTalk()
        }
    }

    /// Runs a fixed command at the cursor, skipping speech (called for gesture-triggered commands).
    public func run(_ command: AssistantCommand, at screenPoint: CGPoint) {
        guard settings.enabled else { return }
        let utterance: String
        switch command {
        case .summarize: utterance = "summarize this"
        case .explain: utterance = "explain this"
        case .translate: utterance = "translate this to \(settings.targetLanguage)"
        default:
            fail(.unsupported(command.title))
            return
        }
        cancelWork()
        setThinking()
        let started = Date()
        work = Task { [weak self] in
            await self?.process(utterance: utterance, speechEnded: started, point: screenPoint, trigger: "gesture")
        }
    }

    public func pasteFromPocket() { fail(.unsupported("The pocket")) }
    public func confirmPendingAction() {}

    public func cancel() {
        cancelWork()
        onCaptureFrame?(nil)
        setState(.off)
        sendWatchState?(restingWatchState)
    }

    // MARK: Internals

    private let apiKeyProvider: () -> String?
    private let macMic: MacMicrophoneSource
    private let client = GeminiClient()
    private var work: Task<Void, Never>?
    private var pttWanted = false
    private var session: Session?
    private var lastAnswer: String?
    private var thinkingLevel: String? = "minimal"

    private final class BufferTally: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    private struct Session {
        let id = UUID()
        let transcriber: CommandTranscriber
        var source: VoiceAudioSource
        let tally: BufferTally
    }

    private var restingWatchState: AssistantWatchState {
        settings.enabled && settings.wakeWordEnabled && handsFree ? .waiting : .off
    }

    private func setState(_ new: JuneState) { state = new }

    private func setThinking() {
        setState(.thinking)
        sendWatchState?(.thinking)
    }

    private func fail(_ error: JuneError) {
        JuneLog.write("error \(error.message)")
        onCaptureFrame?(nil)
        setState(.error(message: error.message, fix: error.fix))
        sendWatchState?(restingWatchState)
    }

    private func cancelWork() {
        work?.cancel()
        work = nil
        if let session {
            session.transcriber.cancel()
            session.source.stop()
        }
        session = nil
    }

    private static func cursorLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    // MARK: Push to talk

    private func beginPushToTalk() async {
        guard await ensurePermissions(), pttWanted, session == nil else { return }
        guard let transcriber = CommandTranscriber() else { fail(.onDeviceSpeechMissing); return }
        guard let source = activeSource else { fail(.noMicrophone); return }

        let tally = BufferTally()
        transcriber.onPartial = { [weak self] text in
            Task { @MainActor in self?.partial(text) }
        }
        transcriber.start()
        do {
            try source.start { buffer in
                tally.bump()
                transcriber.append(buffer)
            }
        } catch {
            transcriber.cancel()
            fail((error as? JuneError) ?? .noMicrophone)
            return
        }
        let current = Session(transcriber: transcriber, source: source, tally: tally)
        session = current
        setState(.listening(transcript: ""))
        sendWatchState?(.listening)
        if settings.chimeEnabled { NSSound(named: NSSound.Name("Tink"))?.play() }
        JuneLog.write("listening source=\(source.displayName)")

        // A source that never produces audio (watch without mic permission, asleep, out of range)
        // must not leave June deaf: fall back to the Mac's microphone for this command.
        if source !== macMic {
            let id = current.id
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                self?.fallBackToMacMic(ifSession: id)
            }
        }
    }

    private func fallBackToMacMic(ifSession id: UUID) {
        guard var current = session, current.id == id, current.tally.value == 0, macMic.isAvailable else { return }
        JuneLog.write("source \(current.source.displayName) silent, falling back to \(macMic.displayName)")
        current.source.stop()
        do {
            let transcriber = current.transcriber
            let tally = current.tally
            try macMic.start { buffer in
                tally.bump()
                transcriber.append(buffer)
            }
            current.source = macMic
            session = current
        } catch {
            fail((error as? JuneError) ?? .noMicrophone)
        }
    }

    private func partial(_ text: String) {
        guard session != nil else { return }
        setState(.listening(transcript: text))
    }

    private func endPushToTalk() {
        guard let current = session else { return }
        session = nil
        current.source.stop()
        let speechEnded = Date()
        let point = Self.cursorLocation()      // people point while they talk: read the cursor when they stop
        setThinking()
        work = Task { [weak self] in
            let transcript = await current.transcriber.finish()
            await self?.process(utterance: transcript, speechEnded: speechEnded, point: point, trigger: "push-to-talk")
        }
    }

    private func ensurePermissions() async -> Bool {
        guard Permissions.bundleHasUsageStrings else { fail(.notBundled); return false }
        if Permissions.microphoneState() == .notDetermined { _ = await Permissions.requestMicrophone() }
        guard Permissions.microphoneState() == .granted else { fail(.micDenied); return false }
        if Permissions.speechState() == .notDetermined { _ = await Permissions.requestSpeech() }
        guard Permissions.speechState() == .granted else { fail(.speechDenied); return false }
        return true
    }

    // MARK: Command pipeline

    private static let followUpWords = ["shorter", "longer", "simpler", "bullet", "bullets", "again", "more", "rephrase", "shorten"]

    private func isFollowUp(_ utterance: String) -> Bool {
        let lower = utterance.lowercased()
        return lastAnswer != nil && Self.followUpWords.contains { lower.contains($0) }
    }

    private func process(utterance rawUtterance: String, speechEnded: Date, point: CGPoint, trigger: String) async {
        let utterance = Self.stripWakeWords(rawUtterance).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !utterance.isEmpty else { fail(.noSpeech); return }
        guard AXIsProcessTrusted() else { fail(.needsAccessibility); return }
        guard let key = apiKeyProvider(), !key.isEmpty else { fail(.noAPIKey); return }

        let capture = await Task.detached { ContextCapture.capture(at: point) }.value
        if Task.isCancelled { return }
        onCaptureFrame?(capture.frame)

        var contextText = capture.text
        var sourceName = capture.source.rawValue
        if contextText == nil {
            if isFollowUp(utterance) {
                contextText = lastAnswer
                sourceName = "last answer"
            } else {
                fail(.emptyCapture)
                return
            }
        }
        if let text = contextText {
            let preview = text.replacingOccurrences(of: "\n", with: " ").prefix(70)
            setState(.captured(summary: "Reading: \(preview)\(text.count > 70 ? "…" : "")"))
        }

        let userText = GeminiRequest.userText(utterance: utterance, appName: capture.appName, capturedText: contextText,
                                              captureSource: sourceName, focusedEditable: capture.focusedEditable,
                                              pocket: nil, lastAnswer: lastAnswer, targetLanguage: settings.targetLanguage)
        let model = GeminiClient.model(override: settings.modelOverride)
        let requestStarted = Date()
        var firstToken: Date?
        var answer = ""

        do {
            var attempt = 0
            while true {
                attempt += 1
                let body = try GeminiRequest.body(userText: userText, imageJPEG: nil, functions: [], forced: nil,
                                                  thinkingLevel: thinkingLevel)
                do {
                    answer = ""
                    for try await event in client.stream(body: body, apiKey: key, model: model) {
                        if Task.isCancelled { return }
                        switch event {
                        case .text(let delta):
                            if firstToken == nil { firstToken = Date() }
                            answer += delta
                            setState(.answer(text: answer, streaming: true))
                        case .functionCall(let name, _):
                            throw JuneError.unsupported(name)
                        case .blocked(let reason):
                            throw JuneError.blocked(reason)
                        case .done:
                            break
                        }
                    }
                    break
                } catch JuneError.http(let code, let detail)
                            where code == 400 && thinkingLevel != nil && detail.lowercased().contains("thinking") && attempt == 1 {
                    thinkingLevel = nil          // this model rejects thinkingLevel; retry once without it
                    continue
                }
            }
        } catch is CancellationError {
            return
        } catch let error as JuneError {
            if Task.isCancelled { return }
            fail(error)
            return
        } catch {
            if Task.isCancelled { return }
            fail(.noNetwork)
            return
        }

        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { fail(.emptyAnswer); return }
        lastAnswer = trimmed
        setState(.answer(text: trimmed, streaming: false))
        sendWatchState?(.idle)

        let now = Date()
        let toFirst = firstToken.map { Int($0.timeIntervalSince(speechEnded) * 1000) } ?? -1
        let request = firstToken.map { Int($0.timeIntervalSince(requestStarted) * 1000) } ?? -1
        JuneLog.write("done trigger=\(trigger) model=\(model) app=\(capture.appName) source=\(sourceName) "
                      + "contextChars=\(contextText?.count ?? 0) answerChars=\(trimmed.count) "
                      + "speechEnd->firstToken=\(toFirst)ms request->firstToken=\(request)ms total=\(Int(now.timeIntervalSince(speechEnded) * 1000))ms")
    }

    /// Drops "hey june" / "june" from the start of a transcript (push-to-talk users sometimes say it anyway).
    public nonisolated static func stripWakeWords(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = result.lowercased()
        for prefix in ["hey june", "june"] where lower.hasPrefix(prefix) {
            let rest = result.dropFirst(prefix.count)
            if let next = rest.first, next.isLetter { break }      // "junebug" is not a wake word
            result = String(rest).trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!-"))
            break
        }
        return result
    }
}
