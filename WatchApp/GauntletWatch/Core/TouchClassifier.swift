import Foundation
import GauntletProtocol

/// Thresholds that separate a tap, a long press and a drag on the watch face.
struct TouchTuning {
    /// A touch that lifts within this time (and has not moved) is a tap.
    var tapMaxDuration: TimeInterval = 0.3
    /// Movement below this many points is treated as a still finger.
    var slop: Double = 6
    /// Holding still for this long is a long press.
    var longPressDuration: TimeInterval = 0.5
}

/// What a touch turns into.
enum TouchOutput: Equatable {
    /// Send on the link as a touch event; `dx`/`dy` are points since the previous event.
    case touch(TouchPhase, dx: Double, dy: Double)
    /// Send on the link as a discrete action.
    case action(WatchActionCode)
    /// Tick the Taptic Engine locally (long press recognised).
    case localHaptic
}

/// Turns the raw stream of a zero-distance drag gesture into link messages.
///
/// Pure value type with the clock passed in, so it is tested on the Mac.
/// - A finger going down sends `.began` at once, so the Mac knows the display is being touched.
/// - Movement is withheld until the finger has travelled `slop` points; from then on every
///   event is forwarded as a delta (the slop itself is dropped, so the pointer never jumps).
/// - Lifting quickly without travelling is a tap. Single taps are never delayed: the Mac turns
///   two quick taps into a double-click by itself.
/// - Holding still is a long press, reported once; no tap follows on release.
struct TouchClassifier {
    var tuning = TouchTuning()

    private(set) var isDown = false
    private var startTime: TimeInterval = 0
    private var anchorX = 0.0
    private var anchorY = 0.0
    private var lastX = 0.0
    private var lastY = 0.0
    private var travelled = false
    private var longPressFired = false

    /// True while a long press could still happen for the current touch.
    var longPressPending: Bool { isDown && !travelled && !longPressFired }

    /// Feed every gesture update. `tx`/`ty` is the translation since the finger went down.
    mutating func changed(tx: Double, ty: Double, at time: TimeInterval) -> [TouchOutput] {
        guard isDown else {
            isDown = true
            startTime = time
            anchorX = tx
            anchorY = ty
            lastX = tx
            lastY = ty
            travelled = false
            longPressFired = false
            return [.touch(.began, dx: 0, dy: 0)]
        }
        if !travelled {
            let distance = ((tx - anchorX) * (tx - anchorX) + (ty - anchorY) * (ty - anchorY)).squareRoot()
            guard distance >= tuning.slop else { return [] }
            travelled = true
            lastX = tx
            lastY = ty
            return []
        }
        let dx = tx - lastX
        let dy = ty - lastY
        lastX = tx
        lastY = ty
        guard dx != 0 || dy != 0 else { return [] }
        return [.touch(.moved, dx: dx, dy: dy)]
    }

    /// The long-press timer fired.
    mutating func longPressDeadline(at time: TimeInterval) -> [TouchOutput] {
        guard longPressPending, time - startTime >= tuning.longPressDuration - 0.02 else { return [] }
        longPressFired = true
        return [.action(.screenLongPress), .localHaptic]
    }

    /// The finger lifted.
    mutating func ended(at time: TimeInterval) -> [TouchOutput] {
        guard isDown else { return [] }
        isDown = false
        let isTap = !travelled && !longPressFired && time - startTime <= tuning.tapMaxDuration
        // The click goes out while the Mac still sees the finger on the glass.
        return isTap ? [.action(.screenTap), .touch(.ended, dx: 0, dy: 0)] : [.touch(.ended, dx: 0, dy: 0)]
    }

    /// The system took the touch away (app deactivated, navigation, …).
    mutating func cancelled() -> [TouchOutput] {
        guard isDown else { return [] }
        isDown = false
        return [.touch(.cancelled, dx: 0, dy: 0)]
    }
}
