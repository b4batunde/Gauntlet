import SwiftUI

// In the macOS 27 SDK `@State` resolves to a macro whose plugin ships only with full Xcode.
// This alias selects the plain property wrapper, which the command-line toolchain can build.
typealias LocalState = SwiftUI.State

/// Small deterministic generator so drills can be replayed exactly in the self-check.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension Comparable {
    func clamped(_ low: Self, _ high: Self) -> Self { min(high, max(low, self)) }
}

extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat { hypot(x - other.x, y - other.y) }
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

func degrees(_ radians: Double) -> Double { radians * 180 / .pi }
func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
