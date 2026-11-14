import Foundation
import SwiftUI
import GauntletProtocol

/// `@LocalState` is plain `SwiftUI.State`.
///
/// With the command-line toolchain this project is checked with, `@State` resolves to a macro
/// whose compiler plug-in ships only inside Xcode. The alias always selects the property
/// wrapper, so the same source type-checks without Xcode and builds unchanged with it.
typealias LocalState = SwiftUI.State

/// The Gauntlet palette.
enum Palette {
    /// #070B14
    static let background = Color(red: 7.0 / 255.0, green: 11.0 / 255.0, blue: 20.0 / 255.0)
    /// Slightly lifted surface for buttons and rows.
    static let panel = Color(red: 17.0 / 255.0, green: 25.0 / 255.0, blue: 42.0 / 255.0)
    /// #35E0FF
    static let cyan = Color(red: 53.0 / 255.0, green: 224.0 / 255.0, blue: 255.0 / 255.0)
    /// #8B5CFF
    static let violet = Color(red: 139.0 / 255.0, green: 92.0 / 255.0, blue: 255.0 / 255.0)
    /// #3DFFA2
    static let green = Color(red: 61.0 / 255.0, green: 255.0 / 255.0, blue: 162.0 / 255.0)
    /// #FFB020
    static let amber = Color(red: 255.0 / 255.0, green: 176.0 / 255.0, blue: 32.0 / 255.0)
    /// #FF4D6D
    static let red = Color(red: 255.0 / 255.0, green: 77.0 / 255.0, blue: 109.0 / 255.0)
    static let grey = Color(white: 0.5)
    static let textDim = Color(white: 0.66)
}

/// What the Mac is doing with our input, reduced to the one thing worth showing at a glance.
enum ControlMode: Equatable {
    case paused
    case dragging
    case scrolling
    case engaged
    case released

    init(_ flags: MacStateFlags) {
        if flags.contains(.paused) {
            self = .paused
        } else if flags.contains(.dragging) {
            self = .dragging
        } else if flags.contains(.scrollMode) {
            self = .scrolling
        } else if flags.contains(.engaged) {
            self = .engaged
        } else {
            self = .released
        }
    }

    /// One word, always upper case.
    var label: String {
        switch self {
        case .paused: return "PAUSED"
        case .dragging: return "GRAB"
        case .scrolling: return "SCROLL"
        case .engaged: return "LIVE"
        case .released: return "READY"
        }
    }

    /// A short line under the label saying what to do next.
    var hint: String {
        switch self {
        case .paused: return "Resume in Actions"
        case .dragging: return "Flick in to drop"
        case .scrolling: return "Move to scroll"
        case .engaged: return "Pinch to click"
        case .released: return "Raise to point"
        }
    }

    var color: Color {
        switch self {
        case .paused: return Palette.grey
        case .dragging: return Palette.violet
        case .scrolling: return Palette.amber
        case .engaged: return Palette.cyan
        case .released: return Palette.cyan.opacity(0.35)
        }
    }

    var symbol: String {
        switch self {
        case .paused: return "pause.fill"
        case .dragging: return "hand.draw.fill"
        case .scrolling: return "arrow.up.and.down"
        case .engaged: return "scope"
        case .released: return "hand.raised.fill"
        }
    }

    /// The ring only moves while the pointer is live.
    var animates: Bool {
        switch self {
        case .paused, .released: return false
        case .dragging, .scrolling, .engaged: return true
        }
    }
}
