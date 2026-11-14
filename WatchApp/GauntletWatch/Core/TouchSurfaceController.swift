import Foundation
import Combine
import CoreGraphics

/// Glue between the drag gesture on the Control page and `TouchClassifier`:
/// supplies the clock and the long-press timer. Main thread only.
final class TouchSurfaceController: ObservableObject {

    /// A finger is on the glass (for visual feedback).
    @Published private(set) var isTouching = false

    /// Where classified touches go. Set by the view.
    var emit: (TouchOutput) -> Void = { _ in }

    private var classifier = TouchClassifier()
    private var longPress: DispatchWorkItem?
    private var touchID = 0

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Every update of the drag gesture, including the first one.
    func changed(translation: CGSize) {
        let wasDown = classifier.isDown
        send(classifier.changed(tx: Double(translation.width), ty: Double(translation.height), at: now))
        if !wasDown {
            touchID += 1
            isTouching = true
            armLongPress()
        } else if !classifier.longPressPending {
            disarmLongPress()
        }
    }

    /// The finger lifted normally.
    func ended() {
        disarmLongPress()
        send(classifier.ended(at: now))
        if isTouching { isTouching = false }
    }

    /// The gesture is no longer active. If no normal end follows shortly, the system
    /// cancelled the touch and the Mac must be told the finger is gone.
    func gestureBecameInactive() {
        let id = touchID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.touchID == id else { return }
            self.cancel()
        }
    }

    func cancel() {
        disarmLongPress()
        send(classifier.cancelled())
        if isTouching { isTouching = false }
    }

    private func armLongPress() {
        disarmLongPress()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.send(self.classifier.longPressDeadline(at: self.now))
        }
        longPress = item
        DispatchQueue.main.asyncAfter(deadline: .now() + classifier.tuning.longPressDuration, execute: item)
    }

    private func disarmLongPress() {
        longPress?.cancel()
        longPress = nil
    }

    private func send(_ outputs: [TouchOutput]) {
        for output in outputs { emit(output) }
    }
}
