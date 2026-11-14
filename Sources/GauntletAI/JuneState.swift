import Foundation

/// What June is doing right now. Published to the UI on the main thread.
public enum JuneState: Sendable, Equatable {
    /// June is switched off, or resting between commands (push-to-talk only).
    case off
    /// The mic is open for "Hey June" and nothing leaves the Mac.
    case waitingForWakeWord
    /// Recording a command; `transcript` is the live on-device transcription.
    case listening(transcript: String)
    case thinking
    /// What June is looking at (shown before the answer arrives).
    case captured(summary: String)
    case answer(text: String, streaming: Bool)
    /// A data-changing action waits for a physical confirm (pinch tap).
    case confirm(description: String)
    case pocketReady(preview: String)
    /// One-line success toast: "Typed", "Saved to Notes".
    case notice(String)
    case error(message: String, fix: String?)
}

public enum WakeSensitivity: String, Codable, CaseIterable, Sendable {
    case strict, normal, loose
}

/// Everything the June settings page edits. Persisted in UserDefaults.
public struct JuneSettings: Codable, Equatable, Sendable {
    /// Master switch. Off: June ignores every trigger and the microphone stays closed.
    public var enabled = true
    public var wakeWordEnabled = false
    public var sensitivity = WakeSensitivity.normal
    /// Display name of the preferred audio source; nil = automatic (AirPods, then watch, then Mac mic).
    public var preferredSource: String?
    public var screenshotFallback = false
    public var targetLanguage = "Spanish"
    public var chimeEnabled = true
    /// Hold Right Option to talk; Control-Option-G arms custom gestures.
    public var hotkeysEnabled = true
    public var modelOverride: String?

    public init() {}

    static let key = "juneSettings"

    public static func load(from defaults: UserDefaults = .standard) -> JuneSettings {
        guard let data = defaults.data(forKey: key),
              let s = try? JSONDecoder().decode(JuneSettings.self, from: data) else { return JuneSettings() }
        return s
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: JuneSettings.key) }
    }
}

/// Every way June can fail, each with a one-line fix the UI shows.
public enum JuneError: Error, Equatable, Sendable {
    case noAPIKey
    case noNetwork
    case timeout
    case http(Int, String)
    case blocked(String)
    case emptyAnswer
    case emptyCapture
    case needsAccessibility
    case noMicrophone
    case micDenied
    case speechDenied
    case onDeviceSpeechMissing
    case noSpeech
    case notBundled
    case unsupported(String)

    public var message: String {
        switch self {
        case .noAPIKey: return "No Gemini API key."
        case .noNetwork: return "No internet connection."
        case .timeout: return "Gemini took too long to answer."
        case .http(let code, let detail):
            switch code {
            case 400, 401, 403: return "Gemini rejected the request (\(code)). \(detail)"
            case 429: return "Gemini rate limit reached."
            default: return "Gemini error \(code). \(detail)"
            }
        case .blocked: return "Gemini declined to answer that."
        case .emptyAnswer: return "Gemini sent back an empty answer."
        case .emptyCapture: return "June couldn't read anything under the cursor."
        case .needsAccessibility: return "June needs the Accessibility permission to read what you point at."
        case .noMicrophone: return "No microphone is available."
        case .micDenied: return "Microphone access is off."
        case .speechDenied: return "Speech recognition access is off."
        case .onDeviceSpeechMissing: return "On-device speech recognition isn't installed."
        case .noSpeech: return "Didn't catch that."
        case .notBundled: return "Run the built Gauntlet app, not the bare binary."
        case .unsupported(let what): return "\(what) isn't available yet."
        }
    }

    public var fix: String? {
        switch self {
        case .noAPIKey: return "Set GEMINI_API_KEY or save a key in Settings › June."
        case .noNetwork: return "Check the connection and try again."
        case .timeout: return "Try again, or check the connection."
        case .http(let code, _): return code == 429 ? "Wait a moment and try again." : "Check the API key and model name in Settings › June."
        case .blocked: return "Try pointing at different text."
        case .emptyAnswer: return "Try again."
        case .emptyCapture: return "Point at some text, or select it first."
        case .needsAccessibility: return "System Settings › Privacy & Security › Accessibility › turn on Gauntlet."
        case .noMicrophone: return "Connect or enable a microphone."
        case .micDenied: return "System Settings › Privacy & Security › Microphone › turn on Gauntlet."
        case .speechDenied: return "System Settings › Privacy & Security › Speech Recognition › turn on Gauntlet."
        case .onDeviceSpeechMissing: return "System Settings › Keyboard › Dictation: turn it on and download the language."
        case .noSpeech: return "Hold the button, speak, then release."
        case .notBundled: return "Build with Scripts/build-app.sh and open the .app."
        case .unsupported: return nil
        }
    }
}
