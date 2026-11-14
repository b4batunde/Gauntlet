import AppKit
import CoreGraphics
import simd

/// Where things stand in the 3D world (SceneKit units; +X right, +Y up, -Z toward the screen).
enum Stage {
    static let screenCenter = simd_float3(0, 2.18, -2.94)
    static let screenSize = simd_float2(3.2, 2.0)
    /// Elbow of a right-wrist wearer; mirrored in X for the left wrist.
    static let elbow = simd_float3(0.5, 0.96, 0.7)
    static let avatarScale: Float = 3.0
    static let cameraTarget = simd_float3(0, 1.62, -1.38)
    static let cameraDistance: Float = 3.6
    static let fieldOfView: Float = 44

    /// Screen points -> position in the screen node's local space (origin at its centre).
    static func screenLocal(_ point: CGPoint, logicalSize: CGSize) -> simd_float3 {
        let u = Float(point.x / logicalSize.width) - 0.5
        let v = 0.5 - Float(point.y / logicalSize.height)
        return simd_float3(u * screenSize.x, v * screenSize.y, 0)
    }
}

/// What the watch on the avatar's wrist (and the colour of the whole arm) is saying.
enum AvatarMood: CaseIterable {
    case offline, resting, pointing, dragging, scrolling, paused

    var tone: NSColor {
        switch self {
        case .offline: return NSColor(white: 0.45, alpha: 1)
        case .resting: return Palette.accent.mixed(with: NSColor(white: 0.5, alpha: 1), 0.75)
        case .pointing: return Palette.accent
        case .dragging: return Palette.secondary
        case .scrolling: return Palette.success
        case .paused: return Palette.warning
        }
    }

    var label: String {
        switch self {
        case .offline: return "NO LINK"
        case .resting: return "REST"
        case .pointing: return "POINT"
        case .dragging: return "DRAG"
        case .scrolling: return "SCROLL"
        case .paused: return "PAUSED"
        }
    }

    var symbol: String {
        switch self {
        case .offline: return "wifi.slash"
        case .resting: return "moon.zzz.fill"
        case .pointing: return "cursorarrow"
        case .dragging: return "hand.draw.fill"
        case .scrolling: return "arrow.up.arrow.down"
        case .paused: return "pause.fill"
        }
    }
}

/// Every texture in the Dojo is drawn in code — there are no asset files.
enum ProceduralTextures {
    /// Runs `draw` with a y-down context and an AppKit graphics context installed (for text and symbols).
    static func image(width: Int, height: Int, _ draw: (Painter) -> Void) -> CGImage? {
        guard let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        cg.translateBy(x: 0, y: CGFloat(height))
        cg.scaleBy(x: 1, y: -1)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        draw(Painter(cg: cg, size: CGSize(width: width, height: height)))
        NSGraphicsContext.current = previous
        return cg.makeImage()
    }

    /// Round, soft-edged sprite for particles.
    static func softDot() -> CGImage? {
        image(width: 64, height: 64) { p in
            p.glow(CGPoint(x: 32, y: 32), radius: 32, color: .white, alpha: 1)
            p.circle(CGPoint(x: 32, y: 32), 9, fill: .white)
        }
    }

    static func radialGlow(_ color: NSColor) -> CGImage? {
        image(width: 256, height: 256) { p in
            p.glow(CGPoint(x: 128, y: 128), radius: 128, color: color, alpha: 1)
        }
    }

    /// Flat backdrop behind everything: a faint glow where the horizon would be.
    static func sky() -> CGImage? {
        image(width: 32, height: 512) { p in
            let top = Palette.background.mixed(with: .black, 0.45)
            let horizon = Palette.background.mixed(with: Palette.accent, 0.10)
            let colors = [top.cgColor, Palette.background.cgColor, horizon.cgColor, Palette.background.cgColor] as CFArray
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.42, 0.6, 1]) else { return }
            p.cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 512), options: [])
        }
    }

    /// Something for the metal on the arm and watch to reflect.
    static func environment() -> CGImage? {
        image(width: 256, height: 128) { p in
            let colors = [NSColor(white: 0.02, alpha: 1).cgColor,
                          Palette.accent.mixed(with: .white, 0.3).cgColor,
                          Palette.secondary.mixed(with: .black, 0.55).cgColor,
                          NSColor(white: 0.01, alpha: 1).cgColor] as CFArray
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.38, 0.62, 1]) else { return }
            p.cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 128), options: [])
        }
    }

    /// Floating caption, e.g. over the hologram arm.
    static func tag(_ text: String, tone: NSColor) -> CGImage? {
        image(width: 512, height: 128) { p in
            p.roundRect(p.bounds.insetBy(dx: 6, dy: 6), radius: 58, fill: tone.alpha(0.25), stroke: tone, lineWidth: 5)
            p.text(text, in: p.bounds, size: 54, weight: .heavy, color: .white, align: .center, tracking: 6)
        }
    }

    /// The little UI on the avatar's watch.
    static func watchFace(_ mood: AvatarMood) -> CGImage? {
        image(width: 240, height: 290) { p in
            p.fill(p.bounds, NSColor(srgbRed: 0.01, green: 0.02, blue: 0.04, alpha: 1))
            let center = CGPoint(x: 120, y: 122)
            let tone = mood.tone
            p.glow(center, radius: 130, color: tone, alpha: 0.35)
            p.circle(center, 82, stroke: NSColor.white.alpha(0.14), lineWidth: 15)
            p.ring(center, 82, progress: mood == .offline ? 0.12 : 0.82, color: tone, lineWidth: 15)
            p.symbol(mood.symbol, center: center, pointSize: 62, color: .white, weight: .bold)
            p.text(mood.label, in: CGRect(x: 0, y: 222, width: 240, height: 50), size: 34, weight: .heavy,
                   color: tone, align: .center, tracking: 3)
        }
    }
}
