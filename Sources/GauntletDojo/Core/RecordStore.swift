import Foundation

/// One finished drill run.
struct DrillRecord: Codable, Equatable, Identifiable {
    var date: Date
    /// The number the drill ranks by (see `DojoMode.higherIsBetter`).
    var score: Double
    /// Ready-to-show one-liner, e.g. "3.4 bits/s · 12 hits · 1 miss".
    var summary: String

    var id: Date { date }
}

extension DojoMode {
    var higherIsBetter: Bool {
        switch self {
        case .drag, .scroll: return false       // ranked by time
        default: return true
        }
    }

    func formatScore(_ score: Double) -> String {
        switch self {
        case .targets: return String(format: "%.2f bits/s", score)
        case .drag: return String(format: "%.1f s", score)
        case .scroll: return String(format: "%.2f s / row", score)
        case .simon: return String(format: "%.0f pts", score)
        case .freePlay, .calibration, .live: return String(format: "%.1f", score)
        }
    }
}

/// Personal bests and recent history, kept in `UserDefaults` under the `dojo.` prefix.
/// Main-thread only. Pass `defaults: nil` for a store that forgets everything (tests).
final class RecordStore {
    private static let key = "dojo.records.v1"
    private static let historyLimit = 30

    /// Off while the autopilot is playing: its runs are demos, not the wearer's results.
    var isRecording = true

    private let defaults: UserDefaults?
    private var table: [String: [DrillRecord]] = [:]
    private var bests: [String: DrillRecord] = [:]

    private struct Stored: Codable {
        var history: [String: [DrillRecord]]
        var bests: [String: DrillRecord]
    }

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            table = stored.history
            bests = stored.bests
        }
    }

    func history(for mode: DojoMode) -> [DrillRecord] { table[mode.rawValue] ?? [] }

    func best(for mode: DojoMode) -> DrillRecord? { bests[mode.rawValue] }

    /// Stores a run. Returns true when it beats the previous best.
    @discardableResult
    func add(_ record: DrillRecord, for mode: DojoMode) -> Bool {
        guard isRecording else { return false }
        var runs = table[mode.rawValue] ?? []
        runs.append(record)
        if runs.count > Self.historyLimit { runs.removeFirst(runs.count - Self.historyLimit) }
        table[mode.rawValue] = runs

        var isBest = true
        if let best = bests[mode.rawValue] {
            isBest = mode.higherIsBetter ? record.score > best.score : record.score < best.score
        }
        if isBest { bests[mode.rawValue] = record }
        save()
        return isBest
    }

    func reset() {
        table = [:]
        bests = [:]
        defaults?.removeObject(forKey: Self.key)
    }

    private func save() {
        guard let defaults, let data = try? JSONEncoder().encode(Stored(history: table, bests: bests)) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
