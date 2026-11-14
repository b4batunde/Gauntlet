import AppKit
import SwiftUI
import SceneKit

/// `DojoTheme` in the colour types SceneKit and CoreGraphics want.
enum Palette {
    static let background = make(DojoTheme.background)
    static let panel = make(DojoTheme.panel)
    static let accent = make(DojoTheme.accent)
    static let secondary = make(DojoTheme.secondary)
    static let success = make(DojoTheme.success)
    static let warning = make(DojoTheme.warning)
    static let danger = make(DojoTheme.danger)
    static let textPrimary = make(DojoTheme.textPrimary)
    static let textSecondary = make(DojoTheme.textSecondary)
    static let stroke = make(DojoTheme.panelStroke)

    private static func make(_ color: Color) -> NSColor {
        NSColor(color).usingColorSpace(.sRGB) ?? NSColor.white
    }
}

/// Semantic colour used by feedback, status rows and screen drawings.
enum Tone: Equatable {
    case accent, secondary, success, warning, danger, neutral

    var ns: NSColor {
        switch self {
        case .accent: return Palette.accent
        case .secondary: return Palette.secondary
        case .success: return Palette.success
        case .warning: return Palette.warning
        case .danger: return Palette.danger
        case .neutral: return Palette.textPrimary
        }
    }

    var color: Color {
        switch self {
        case .accent: return DojoTheme.accent
        case .secondary: return DojoTheme.secondary
        case .success: return DojoTheme.success
        case .warning: return DojoTheme.warning
        case .danger: return DojoTheme.danger
        case .neutral: return DojoTheme.textPrimary
        }
    }
}

extension NSColor {
    func alpha(_ value: CGFloat) -> NSColor { withAlphaComponent(alphaComponent * value) }

    func mixed(with other: NSColor, _ fraction: CGFloat) -> NSColor {
        blended(withFraction: fraction, of: other) ?? self
    }

    /// RGB as a shader-friendly vector.
    var rgbVector: SCNVector3 {
        let c = usingColorSpace(.sRGB) ?? self
        return SCNVector3(c.redComponent, c.greenComponent, c.blueComponent)
    }
}
