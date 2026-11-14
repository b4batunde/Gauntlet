import AppKit
import SceneKit
import simd

typealias V3 = SIMD3<Float>

// MARK: Timing

func clamp01(_ x: Double) -> Double { max(0, min(1, x)) }
/// 0 before `a`, 1 after `b`, linear in between.
func prog(_ t: Double, _ a: Double, _ b: Double) -> Double { b > a ? clamp01((t - a) / (b - a)) : (t >= b ? 1 : 0) }
func ease(_ x: Double) -> Double { let t = clamp01(x); return t * t * (3 - 2 * t) }
func easeOut(_ x: Double) -> Double { let t = 1 - clamp01(x); return 1 - t * t * t }
func easeIn(_ x: Double) -> Double { let t = clamp01(x); return t * t * t }
func easeInOut(_ x: Double) -> Double { let t = clamp01(x); return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
/// Overshooting ease for pops.
func easeBack(_ x: Double) -> Double { let t = clamp01(x) - 1; return 1 + 2.2 * t * t * t + 1.2 * t * t }
func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
func mix(_ a: V3, _ b: V3, _ t: Double) -> V3 { a + (b - a) * Float(t) }
func mix(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
/// A bump that rises from `a`, peaks, and is back to zero at `b`.
func bump(_ t: Double, _ a: Double, _ b: Double) -> Double { let p = prog(t, a, b); return sin(p * .pi) }
/// 1 inside [a, b] with soft edges of the given lengths.
func window(_ t: Double, _ a: Double, _ b: Double, fadeIn: Double = 0.5, fadeOut: Double = 0.4) -> Double {
    ease(prog(t, a, a + fadeIn)) * (1 - ease(prog(t, b - fadeOut, b)))
}

/// Keyframed value with an ease-in-out on every segment.
func keyed(_ keys: [(Double, V3)], _ t: Double) -> V3 {
    guard let first = keys.first, let last = keys.last else { return .zero }
    if t <= first.0 { return first.1 }
    if t >= last.0 { return last.1 }
    for i in 1..<keys.count where t <= keys[i].0 {
        return mix(keys[i - 1].1, keys[i].1, easeInOut(prog(t, keys[i - 1].0, keys[i].0)))
    }
    return last.1
}

func keyed(_ keys: [(Double, Double)], _ t: Double) -> Double {
    Double(keyed(keys.map { ($0.0, V3(Float($0.1), 0, 0)) }, t).x)
}

func keyed(_ keys: [(Double, CGPoint)], _ t: Double) -> CGPoint {
    let v = keyed(keys.map { ($0.0, V3(Float($0.1.x), Float($0.1.y), 0)) }, t)
    return CGPoint(x: CGFloat(v.x), y: CGFloat(v.y))
}

// MARK: Colour

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

enum Palette {
    static let cyan = rgb(0x35E0FF)
    static let violet = rgb(0x8B5CFF)
    static let green = rgb(0x3DFFA2)
    static let amber = rgb(0xFFB020)
    static let pink = rgb(0xFF5C9E)
    static let blue = rgb(0x408FFF)
    static let ink = rgb(0x070B14)
}

extension NSColor {
    func mixed(_ other: NSColor, _ t: Double) -> NSColor { blended(withFraction: CGFloat(clamp01(t)), of: other) ?? self }
}

// MARK: Drawing helpers

/// A bitmap canvas with a top-left origin (y grows downward), which is how screens are laid out.
func drawImage(width: Int, height: Int, _ body: (CGContext) -> Void) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: 1, y: -1)
    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    body(ctx)
    NSGraphicsContext.current = previous
    return ctx.makeImage()!
}

func roundedPath(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: min(radius, rect.width / 2), cornerHeight: min(radius, rect.height / 2), transform: nil)
}

func font(_ size: CGFloat, _ weight: NSFont.Weight, rounded: Bool = false, mono: Bool = false) -> NSFont {
    if mono { return NSFont.monospacedSystemFont(ofSize: size, weight: weight) }
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    if rounded, let descriptor = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: descriptor, size: size) { return f }
    return base
}

enum TextAlign { case left, center, right }

/// Draws one line of text in a flipped (top-left origin) context. `point` is the baseline-independent
/// anchor: the top edge of the line box, at the left / centre / right according to `align`.
@discardableResult
func drawText(_ string: String, at point: CGPoint, font: NSFont, color: NSColor, align: TextAlign = .left,
              tracking: CGFloat = 0, shadow: NSColor? = nil, shadowBlur: CGFloat = 0) -> CGSize {
    var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: tracking]
    if let shadow {
        let s = NSShadow()
        s.shadowColor = shadow
        s.shadowBlurRadius = shadowBlur
        s.shadowOffset = .zero
        attributes[.shadow] = s
    }
    let text = NSAttributedString(string: string, attributes: attributes)
    let size = text.size()
    var origin = point
    switch align {
    case .left: break
    case .center: origin.x -= size.width / 2
    case .right: origin.x -= size.width
    }
    text.draw(at: origin)
    return size
}

/// An SF Symbol rendered in a single colour, centred on `center`.
func drawSymbol(_ name: String, center: CGPoint, pointSize: CGFloat, weight: NSFont.Weight = .semibold, color: NSColor, in ctx: CGContext) {
    // A symbol that is still scaling up from nothing has no size yet; AppKit aborts on empty images.
    guard pointSize >= 1, let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
          let image = base.withSymbolConfiguration(.init(pointSize: pointSize, weight: weight)) else { return }
    let size = image.size
    guard size.width >= 1, size.height >= 1 else { return }
    let tinted = NSImage(size: size, flipped: false) { rect in
        image.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        return true
    }
    // Symbols are upright in an unflipped space; counter the canvas flip locally.
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.scaleBy(x: 1, y: -1)
    if let cg = tinted.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        ctx.draw(cg, in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
    }
    ctx.restoreGState()
}

func fillGradient(_ ctx: CGContext, path: CGPath, colors: [NSColor], from: CGPoint, to: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors.map(\.cgColor) as CFArray, locations: nil)!
    ctx.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

func radialGlow(_ ctx: CGContext, center: CGPoint, radius: CGFloat, color: NSColor) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray, locations: nil)!
    ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

/// Draws an image to fill `rect`, cropping what does not fit (anchored to the top).
func drawAspectFill(_ image: CGImage, in rect: CGRect, ctx: CGContext, zoom: CGFloat = 1, focus: CGPoint = CGPoint(x: 0.5, y: 0)) {
    let scale = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height)) * zoom
    let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
    let x = rect.minX - (w - rect.width) * focus.x
    let y = rect.minY - (h - rect.height) * focus.y
    ctx.saveGState()
    ctx.clip(to: rect)
    // CGContext.draw assumes a bottom-left origin; flip locally so the image is upright.
    ctx.translateBy(x: x, y: y + h)
    ctx.scaleBy(x: 1, y: -1)
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    ctx.restoreGState()
}

func loadImage(_ path: String) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}
