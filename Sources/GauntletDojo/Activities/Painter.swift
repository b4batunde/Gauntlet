import AppKit
import CoreGraphics

/// Immediate-mode drawing on the virtual screen, in screen points with the origin at the top-left.
struct Painter {
    enum Face { case plain, rounded, mono }

    let cg: CGContext
    let size: CGSize

    var bounds: CGRect { CGRect(origin: .zero, size: size) }

    // MARK: Shapes

    func fill(_ rect: CGRect, _ color: NSColor) {
        cg.setFillColor(color.cgColor)
        cg.fill(rect)
    }

    func roundRect(_ rect: CGRect, radius: CGFloat, fill: NSColor? = nil, stroke: NSColor? = nil,
                   lineWidth: CGFloat = 2, dash: [CGFloat] = []) {
        let r = max(0, min(radius, min(rect.width, rect.height) / 2))
        let path = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        if let fill {
            cg.addPath(path)
            cg.setFillColor(fill.cgColor)
            cg.fillPath()
        }
        if let stroke {
            cg.addPath(path)
            cg.setStrokeColor(stroke.cgColor)
            cg.setLineWidth(lineWidth)
            cg.setLineDash(phase: 0, lengths: dash)
            cg.strokePath()
            cg.setLineDash(phase: 0, lengths: [])
        }
    }

    /// The standard card: dark fill, hairline border.
    func card(_ rect: CGRect, radius: CGFloat = 26, tint: NSColor? = nil) {
        roundRect(rect, radius: radius, fill: Palette.panel.alpha(0.82),
                  stroke: tint ?? NSColor.white.alpha(0.10), lineWidth: 2)
    }

    func circle(_ center: CGPoint, _ radius: CGFloat, fill: NSColor? = nil, stroke: NSColor? = nil,
                lineWidth: CGFloat = 2, dash: [CGFloat] = []) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        if let fill {
            cg.setFillColor(fill.cgColor)
            cg.fillEllipse(in: rect)
        }
        if let stroke {
            cg.setStrokeColor(stroke.cgColor)
            cg.setLineWidth(lineWidth)
            cg.setLineDash(phase: 0, lengths: dash)
            cg.strokeEllipse(in: rect)
            cg.setLineDash(phase: 0, lengths: [])
        }
    }

    /// Clockwise arc starting at 12 o'clock; `progress` 0...1.
    func ring(_ center: CGPoint, _ radius: CGFloat, progress: Double, color: NSColor, lineWidth: CGFloat) {
        let p = CGFloat(progress.clamped(0, 1))
        guard p > 0.001 else { return }
        cg.setStrokeColor(color.cgColor)
        cg.setLineWidth(lineWidth)
        cg.setLineCap(.round)
        // The context is flipped, so mathematically increasing angles read as clockwise.
        cg.addArc(center: center, radius: radius, startAngle: -.pi / 2, endAngle: -.pi / 2 + 2 * .pi * p, clockwise: false)
        cg.strokePath()
        cg.setLineCap(.butt)
    }

    func line(_ a: CGPoint, _ b: CGPoint, _ color: NSColor, width: CGFloat = 2, dash: [CGFloat] = []) {
        cg.setStrokeColor(color.cgColor)
        cg.setLineWidth(width)
        cg.setLineCap(.round)
        cg.setLineDash(phase: 0, lengths: dash)
        cg.move(to: a)
        cg.addLine(to: b)
        cg.strokePath()
        cg.setLineDash(phase: 0, lengths: [])
        cg.setLineCap(.butt)
    }

    func polygon(_ points: [CGPoint], fill: NSColor? = nil, stroke: NSColor? = nil, lineWidth: CGFloat = 2) {
        guard let first = points.first else { return }
        let path = CGMutablePath()
        path.move(to: first)
        for p in points.dropFirst() { path.addLine(to: p) }
        path.closeSubpath()
        if let fill {
            cg.addPath(path)
            cg.setFillColor(fill.cgColor)
            cg.fillPath()
        }
        if let stroke {
            cg.addPath(path)
            cg.setStrokeColor(stroke.cgColor)
            cg.setLineWidth(lineWidth)
            cg.setLineJoin(.round)
            cg.strokePath()
        }
    }

    /// Soft radial glow.
    func glow(_ center: CGPoint, radius: CGFloat, color: NSColor, alpha: CGFloat = 0.5) {
        let colors = [color.alpha(alpha).cgColor, color.alpha(0).cgColor] as CFArray
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else { return }
        cg.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }

    func bar(_ rect: CGRect, progress: Double, color: NSColor, track: NSColor = NSColor.white.alpha(0.10)) {
        roundRect(rect, radius: rect.height / 2, fill: track)
        let width = rect.width * CGFloat(progress.clamped(0, 1))
        if width > 1 {
            roundRect(CGRect(x: rect.minX, y: rect.minY, width: max(rect.height, width), height: rect.height),
                      radius: rect.height / 2, fill: color)
        }
    }

    func clipped(to rect: CGRect, radius: CGFloat = 0, _ body: () -> Void) {
        cg.saveGState()
        cg.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        cg.clip()
        body()
        cg.restoreGState()
    }

    // MARK: Text and symbols

    static func font(_ size: CGFloat, _ weight: NSFont.Weight, _ face: Face) -> NSFont {
        switch face {
        case .plain:
            return NSFont.systemFont(ofSize: size, weight: weight)
        case .mono:
            return NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        case .rounded:
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            if let descriptor = base.fontDescriptor.withDesign(.rounded), let font = NSFont(descriptor: descriptor, size: size) {
                return font
            }
            return base
        }
    }

    /// Draws single- or multi-line text, vertically centred in `rect`.
    func text(_ string: String, in rect: CGRect, size: CGFloat, weight: NSFont.Weight = .semibold,
              color: NSColor = Palette.textPrimary, align: NSTextAlignment = .left, face: Face = .rounded,
              tracking: CGFloat = 0) {
        guard !string.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = align
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font(size, weight, face),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
            .kern: tracking,
        ]
        let attributed = NSAttributedString(string: string, attributes: attributes)
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let needed = attributed.boundingRect(with: CGSize(width: rect.width, height: .greatestFiniteMagnitude), options: options)
        let y = rect.minY + max(0, (rect.height - ceil(needed.height)) / 2)
        attributed.draw(with: CGRect(x: rect.minX, y: y, width: rect.width, height: ceil(needed.height) + 2), options: options)
    }

    /// Small all-caps section label.
    func caption(_ string: String, at point: CGPoint, color: NSColor = Palette.textSecondary, size: CGFloat = 20) {
        text(string.uppercased(), in: CGRect(x: point.x, y: point.y, width: 900, height: size + 8),
             size: size, weight: .bold, color: color, tracking: 2.2)
    }

    /// - Parameter backing: second palette colour, for symbols with a filled shape behind the glyph
    ///   (in a `.circle.fill` symbol `color` is the glyph and `backing` is the disc).
    func symbol(_ name: String, center: CGPoint, pointSize: CGFloat, color: NSColor, backing: NSColor? = nil,
                weight: NSFont.Weight = .semibold) {
        let palette = backing.map { [color, $0] } ?? [color]
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: palette))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let s = image.size
        let rect = CGRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    // MARK: Shared chrome

    /// Title strip across the top of every activity.
    func header(_ title: String, subtitle: String, trailing: String = "", tone: Tone = .accent) {
        text(title.uppercased(), in: CGRect(x: 48, y: 18, width: 700, height: 48), size: 34, weight: .heavy,
             color: tone.ns, tracking: 3)
        text(subtitle, in: CGRect(x: 48, y: 60, width: 1000, height: 30), size: 21, weight: .medium,
             color: Palette.textSecondary)
        if !trailing.isEmpty {
            text(trailing, in: CGRect(x: size.width - 648, y: 22, width: 600, height: 48), size: 30, weight: .bold,
                 color: Palette.textPrimary, align: .right, face: .mono)
        }
        line(CGPoint(x: 48, y: 98), CGPoint(x: size.width - 48, y: 98), tone.ns.alpha(0.28), width: 2)
    }
}

/// Renders the active activity into the texture shown on the 3D screen.
final class ScreenRenderer {
    let size: CGSize
    private let context: CGContext?
    private var backdrop: CGImage?

    init(size: CGSize) {
        self.size = size
        context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        context?.interpolationQuality = .high
    }

    func render(_ activity: Activity, _ activityContext: ActivityContext) -> CGImage? {
        guard let cg = context else { return nil }
        cg.saveGState()
        cg.translateBy(x: 0, y: size.height)        // y grows downward, like the screen
        cg.scaleBy(x: 1, y: -1)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)

        let painter = Painter(cg: cg, size: size)
        drawBackdrop(painter)
        activity.draw(painter, activityContext)

        NSGraphicsContext.current = previous
        cg.restoreGState()
        return cg.makeImage()
    }

    /// Wallpaper: deep gradient, dot lattice, soft corner glows. Painted once, then blitted.
    private func drawBackdrop(_ painter: Painter) {
        if let backdrop {
            // The cached image is stored upright; undo the flip for the blit.
            painter.cg.saveGState()
            painter.cg.translateBy(x: 0, y: size.height)
            painter.cg.scaleBy(x: 1, y: -1)
            painter.cg.draw(backdrop, in: painter.bounds)
            painter.cg.restoreGState()
            return
        }
        let cg = painter.cg
        let top = Palette.panel.mixed(with: Palette.background, 0.35)
        let colors = [top.cgColor, Palette.background.cgColor] as CFArray
        if let space = CGColorSpace(name: CGColorSpace.sRGB),
           let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        } else {
            painter.fill(painter.bounds, Palette.background)
        }
        painter.glow(CGPoint(x: size.width * 0.12, y: size.height * 0.1), radius: 620, color: Palette.accent, alpha: 0.10)
        painter.glow(CGPoint(x: size.width * 0.92, y: size.height * 0.95), radius: 700, color: Palette.secondary, alpha: 0.12)
        cg.setFillColor(NSColor.white.alpha(0.05).cgColor)
        var y: CGFloat = 20
        while y < size.height {
            var x: CGFloat = 20
            while x < size.width {
                cg.fillEllipse(in: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3))
                x += 40
            }
            y += 40
        }
        backdrop = cg.makeImage()
    }
}
