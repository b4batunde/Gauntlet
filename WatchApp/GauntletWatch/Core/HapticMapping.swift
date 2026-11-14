import Foundation
import GauntletProtocol

/// The Taptic Engine vocabulary the app uses. Mirrors the long-standing `WKHapticType`
/// cases one to one, so the only watch-specific code is a trivial lookup.
enum HapticTone: CaseIterable {
    case click
    case directionUp
    case directionDown
    case start
    case stop
    case success
    case failure
    case notification
    case retry
}

extension HapticPattern {
    /// Which tap the wearer feels for each thing the Mac reports.
    var tone: HapticTone {
        switch self {
        case .click: return .click
        case .doubleClick: return .directionUp
        case .rightClick: return .directionDown
        case .dragStart: return .start
        case .dragEnd: return .stop
        case .engage: return .start
        case .disengage: return .stop
        case .scrollTick: return .click
        case .success: return .success
        case .failure: return .failure
        case .notify: return .notification
        case .edge: return .retry
        }
    }
}
