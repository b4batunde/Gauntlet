import Foundation
import simd

// MARK: - Public types (interface contract)

/// June commands a custom gesture can trigger. Named here so the engine never depends on GauntletAI.
public enum AssistantCommand: String, Codable, CaseIterable, Sendable {
    case summarize, explain, translate, draftReply, pastePocket, look, saveToNotes

    public var title: String {
        switch self {
        case .summarize: return "Summarize this"
        case .explain: return "Explain this"
        case .translate: return "Translate this"
        case .draftReply: return "Write a reply"
        case .pastePocket: return "Paste reply"
        case .look: return "What's this? (look)"
        case .saveToNotes: return "Save to Notes"
        }
    }
}

/// What a custom gesture does.
public enum CustomAction: Codable, Equatable, Sendable {
    case pointer(PointerAction)
    /// `modifiers` is a `CGEventFlags.rawValue`.
    case keyCombo(keyCode: UInt16, modifiers: UInt64)
    case openApp(bundleID: String)
    case assistant(AssistantCommand)
    case none
}

/// A gesture the user taught Pointer.
public struct CustomGesture: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var action: CustomAction
    public var enabled: Bool
    public var createdAt: Date
    // Recognition data. Opaque to the UI: resampled, normalised gyro traces and the match threshold.
    var templates: [[SIMD3<Double>]]
    var threshold: Double
}

/// Saved custom gestures. Thread-safe. Persisted as JSON (Application Support/Gauntlet).
///
/// `onChange` runs on the thread that made the change, after the store's lock is released.
public final class CustomGestureStore: @unchecked Sendable {
    private struct File: Codable {
        var version = 1
        var alwaysOn = false
        var gestures: [CustomGesture] = []
    }

    private let lock = NSLock()
    private var file = File()
    private let url: URL?

    /// Called after any change (add, update, delete, always-on toggle).
    public var onChange: (() -> Void)?

    /// `url == nil` keeps everything in memory (tests, previews).
    public init(url: URL? = CustomGestureStore.defaultURL()) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(File.self, from: data) {
            file = decoded
        }
    }

    public static func defaultURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return base.appendingPathComponent("Gauntlet", isDirectory: true)
            .appendingPathComponent("custom-gestures.json")
    }

    public var gestures: [CustomGesture] {
        lock.lock(); defer { lock.unlock() }
        return file.gestures
    }

    public func gesture(id: UUID) -> CustomGesture? {
        lock.lock(); defer { lock.unlock() }
        return file.gestures.first { $0.id == id }
    }

    /// Recognise gestures without arming first (stricter threshold). Off by default.
    public var alwaysOn: Bool {
        get { lock.lock(); defer { lock.unlock() }; return file.alwaysOn }
        set {
            lock.lock(); file.alwaysOn = newValue; saveLocked(); lock.unlock()
            onChange?()
        }
    }

    /// Adds the gesture, or replaces the one with the same id (rename, change action, enable/disable).
    public func update(_ gesture: CustomGesture) {
        lock.lock()
        if let i = file.gestures.firstIndex(where: { $0.id == gesture.id }) {
            // The UI edits name/action/enabled; never let it clobber recognition data with stale copies.
            var merged = gesture
            if merged.templates.isEmpty {
                merged.templates = file.gestures[i].templates
                merged.threshold = file.gestures[i].threshold
            }
            file.gestures[i] = merged
        } else {
            file.gestures.append(gesture)
        }
        saveLocked()
        lock.unlock()
        onChange?()
    }

    public func delete(id: UUID) {
        lock.lock()
        file.gestures.removeAll { $0.id == id }
        saveLocked()
        lock.unlock()
        onChange?()
    }

    private func saveLocked() {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(file)
            try data.write(to: url, options: .atomic)
        } catch {
            // Best effort: the in-memory copy stays correct for this session.
        }
    }
}

// MARK: - Recognition maths (dynamic time warping over gyro traces)

enum GestureMath {
    /// Every trace is resampled to this many frames before comparison.
    static let length = 40
    /// Sakoe-Chiba band, frames.
    static let band = 8
    /// Recording: a set of samples whose worst pairwise distance exceeds this is too inconsistent.
    static let consistencyLimit = 0.55
    /// Recording: a new sample this far (mean) from the others is rejected.
    static let sampleRejectDistance = 0.5
    /// Always-on mode uses a stricter threshold than armed mode.
    static let alwaysOnStrictness = 0.6

    static func resample(_ frames: [SIMD3<Double>], to n: Int = length) -> [SIMD3<Double>] {
        guard let first = frames.first else { return Array(repeating: .zero, count: n) }
        guard frames.count > 1, n > 1 else { return Array(repeating: first, count: max(1, n)) }
        var out: [SIMD3<Double>] = []
        out.reserveCapacity(n)
        let scale = Double(frames.count - 1) / Double(n - 1)
        for i in 0..<n {
            let x = Double(i) * scale
            let i0 = min(frames.count - 1, Int(x))
            let i1 = min(frames.count - 1, i0 + 1)
            let f = x - Double(i0)
            out.append(frames[i0] + (frames[i1] - frames[i0]) * f)
        }
        return out
    }

    /// Scale to unit RMS so a slow and a quick version of the same motion compare equal.
    static func normalize(_ frames: [SIMD3<Double>]) -> [SIMD3<Double>] {
        guard !frames.isEmpty else { return frames }
        var sum = 0.0
        for f in frames { sum += simd_length_squared(f) }
        let rms = (sum / Double(frames.count)).squareRoot()
        guard rms > 1e-6 else { return frames }
        return frames.map { $0 / rms }
    }

    static func template(_ raw: [SIMD3<Double>]) -> [SIMD3<Double>] { normalize(resample(raw)) }

    /// Mean per-step distance along the best warping path (lower = more alike, ~0...2).
    static func distance(_ a: [SIMD3<Double>], _ b: [SIMD3<Double>]) -> Double {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return .infinity }
        let w = max(band, abs(n - m))
        let inf = Double.infinity
        var prev = [Double](repeating: inf, count: m + 1)
        var cur = [Double](repeating: inf, count: m + 1)
        prev[0] = 0
        for i in 1...n {
            for j in 0...m { cur[j] = inf }
            let lo = max(1, i - w), hi = min(m, i + w)
            if lo <= hi {
                for j in lo...hi {
                    let cost = simd_distance(a[i - 1], b[j - 1])
                    cur[j] = cost + min(prev[j], cur[j - 1], prev[j - 1])
                }
            }
            swap(&prev, &cur)
        }
        return prev[m] / Double(n + m)
    }

    /// Closest distance from `trace` to any of `templates`.
    static func bestDistance(_ trace: [SIMD3<Double>], to templates: [[SIMD3<Double>]]) -> Double {
        var best = Double.infinity
        for t in templates { best = min(best, distance(trace, t)) }
        return best
    }

    /// 1 at a perfect match, 0.5 exactly at the threshold, toward 0 beyond it.
    static func confidence(distance d: Double, threshold: Double) -> Double {
        guard d.isFinite, threshold > 0 else { return 0 }
        let r = d / threshold
        return 1 / (1 + r * r)
    }

    /// Threshold for a set of samples, or nil if they disagree too much to learn from.
    static func threshold(for templates: [[SIMD3<Double>]]) -> Double? {
        guard templates.count >= 2 else { return nil }
        var worst = 0.0
        for i in 0..<templates.count {
            for j in (i + 1)..<templates.count {
                worst = max(worst, distance(templates[i], templates[j]))
            }
        }
        guard worst <= consistencyLimit else { return nil }
        return max(0.2, min(0.6, worst * 2.0 + 0.12))
    }
}

// MARK: - Capturing one gesture from the motion stream

/// Waits for a movement to start, records it, and ends it when the wrist goes still.
struct MotionRecorder {
    enum Result {
        case finished([SIMD3<Double>])
        case timedOut
    }

    static let releaseRate = 0.6        // rad/s: below this the wrist counts as still
    static let quietTime = 0.18         // s of stillness that ends a gesture
    static let minDuration = 0.15
    static let maxDuration = 2.0
    static let preRollCount = 8         // frames kept from just before the onset
    static let minFrames = 8

    private(set) var active = false
    private(set) var capturing = false
    private var frames: [SIMD3<Double>] = []
    private var preRoll: [SIMD3<Double>] = []
    private var deadline: TimeInterval = 0
    private var elapsed = 0.0
    private var quiet = 0.0
    private var quietFrames = 0
    private var onsetRate = 1.2

    /// Start waiting for a gesture. `window` = how long to wait for it to begin (`.infinity` = forever).
    mutating func begin(time: TimeInterval, window: TimeInterval, onsetRate: Double) {
        active = true
        capturing = false
        frames.removeAll(keepingCapacity: true)
        preRoll.removeAll(keepingCapacity: true)
        deadline = time + window
        elapsed = 0; quiet = 0; quietFrames = 0
        self.onsetRate = onsetRate
    }

    mutating func cancel() {
        active = false
        capturing = false
        frames.removeAll(keepingCapacity: true)
        preRoll.removeAll(keepingCapacity: true)
    }

    mutating func feed(_ gyro: SIMD3<Double>, time: TimeInterval, dt: Double) -> Result? {
        guard active else { return nil }
        let speed = simd_length(gyro)
        if !capturing {
            preRoll.append(gyro)
            if preRoll.count > Self.preRollCount { preRoll.removeFirst(preRoll.count - Self.preRollCount) }
            if speed >= onsetRate {
                capturing = true
                frames = preRoll
                elapsed = 0; quiet = 0; quietFrames = 0
            } else if time > deadline {
                cancel()
                return .timedOut
            }
            return nil
        }

        frames.append(gyro)
        elapsed += dt
        if speed < Self.releaseRate {
            quiet += dt
            quietFrames += 1
        } else {
            quiet = 0
            quietFrames = 0
        }
        let ended = (quiet >= Self.quietTime && elapsed >= Self.minDuration) || elapsed >= Self.maxDuration
        guard ended else { return nil }

        let kept = Array(frames.dropLast(min(quietFrames, max(0, frames.count - Self.minFrames))))
        cancel()
        return kept.count >= Self.minFrames ? .finished(kept) : .timedOut
    }
}
