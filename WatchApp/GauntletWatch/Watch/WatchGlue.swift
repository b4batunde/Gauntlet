import Foundation
import SwiftUI

// The two SwiftUI features that exist only on Apple Watch. Everything else in the views is
// platform-neutral, so these two modifiers are the only UI code a Mac cannot compile as written.

/// Turns Digital Crown rotation into scroll input.
///
/// The crown drives a wrapped, effectively unbounded value with the system's detent
/// haptics; each change is reported as the difference from the previous value, in turns.
struct CrownScrollModifier: ViewModifier {
    let hapticsEnabled: Bool
    let onTurns: (Double) -> Void

    @LocalState private var crownValue = 0.0
    @FocusState private var crownFocused: Bool

    init(hapticsEnabled: Bool, onTurns: @escaping (Double) -> Void) {
        self.hapticsEnabled = hapticsEnabled
        self.onTurns = onTurns
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(watchOS)
        content
            .focusable(true)
            .focused($crownFocused)
            .focusEffectDisabled()
            .digitalCrownRotation($crownValue,
                                  from: -CrownTuning.span,
                                  through: CrownTuning.span,
                                  by: nil,
                                  sensitivity: .medium,
                                  isContinuous: true,
                                  isHapticFeedbackEnabled: hapticsEnabled)
            .onChange(of: crownValue) { oldValue, newValue in
                let turns = CrownMath.turns(from: oldValue, to: newValue)
                if turns != 0 { onTurns(turns) }
            }
            .onAppear {
                // Take crown focus on first appearance and again when coming back from a pushed page.
                crownFocused = true
                DispatchQueue.main.async { crownFocused = true }
            }
        #else
        content
        #endif
    }
}

extension View {
    /// Makes this control the target of the system Double Tap gesture
    /// (thumb and index finger tapped together twice; Series 9 / Ultra 2 and later).
    @ViewBuilder
    func doubleTapPrimaryAction() -> some View {
        #if os(watchOS)
        if #available(watchOS 11.0, *) {
            self.handGestureShortcut(.primaryAction)
        } else {
            self
        }
        #else
        self
        #endif
    }
}
