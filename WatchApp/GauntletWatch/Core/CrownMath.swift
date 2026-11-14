import Foundation

/// How Digital Crown values become scroll input.
enum CrownTuning {
    /// The crown binding runs over `-span ... span` and wraps around, which makes it unbounded
    /// in practice while keeping the system's detent haptics.
    static let span = 10_000.0

    /// How far the SwiftUI crown value moves for ONE FULL TURN of the crown at the sensitivity
    /// used in `CrownScrollModifier` (`.medium`). Apple does not document this number.
    /// CALIBRATE ON A REAL WATCH: turn the crown exactly once and adjust until the Mac reports
    /// a scroll of 1.0. Getting it wrong only makes scrolling faster or slower.
    static let unitsPerTurn = 6.0

    /// +1 when turning the crown upward increases the SwiftUI value (the system convention).
    /// Flip to -1 if scrolling runs backwards.
    static let upwardSign = 1.0

    /// Largest step sent in one message; the wire format carries about +-16.
    static let maxTurnsPerEvent = 8.0
}

enum CrownMath {
    /// Crown movement between two successive binding values, in turns (positive = upward).
    static func turns(from old: Double, to new: Double) -> Double {
        var raw = new - old
        // The value wrapped around the end of its range.
        if raw > CrownTuning.span { raw -= 2 * CrownTuning.span }
        if raw < -CrownTuning.span { raw += 2 * CrownTuning.span }
        guard raw.isFinite else { return 0 }
        let turns = raw / CrownTuning.unitsPerTurn * CrownTuning.upwardSign
        return max(-CrownTuning.maxTurnsPerEvent, min(CrownTuning.maxTurnsPerEvent, turns))
    }
}
