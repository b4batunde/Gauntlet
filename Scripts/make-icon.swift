// Renders the app icon and writes AppIcon.iconset next to this script.
//   swift Scripts/make-icon.swift && iconutil -c icns Scripts/AppIcon.iconset -o Scripts/AppIcon.icns
import AppKit

func render(_ pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let s = CGFloat(pixels)
    let inset = s * 0.09
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: body, xRadius: s * 0.2, yRadius: s * 0.2)

    NSGradient(colors: [NSColor(red: 0.07, green: 0.11, blue: 0.20, alpha: 1),
                        NSColor(red: 0.02, green: 0.03, blue: 0.07, alpha: 1)])?.draw(in: shape, angle: -90)

    let cyan = NSColor(red: 0.208, green: 0.878, blue: 1.0, alpha: 1)
    let violet = NSColor(red: 0.545, green: 0.361, blue: 1.0, alpha: 1)
    let center = NSPoint(x: s / 2, y: s / 2)

    // Motion arcs sweeping around the watch.
    for (i, radius) in [0.30, 0.36].enumerated() {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: s * radius, startAngle: 200 - CGFloat(i) * 8, endAngle: 330 + CGFloat(i) * 8)
        arc.lineWidth = s * 0.018
        arc.lineCapStyle = .round
        (i == 0 ? cyan : violet).withAlphaComponent(i == 0 ? 0.9 : 0.6).setStroke()
        arc.stroke()
    }

    // Watch body.
    let watch = NSRect(x: s * 0.36, y: s * 0.35, width: s * 0.28, height: s * 0.34)
    let band = NSBezierPath(roundedRect: NSRect(x: s * 0.41, y: s * 0.22, width: s * 0.18, height: s * 0.60),
                            xRadius: s * 0.04, yRadius: s * 0.04)
    NSColor(white: 1, alpha: 0.10).setFill()
    band.fill()
    let face = NSBezierPath(roundedRect: watch, xRadius: s * 0.07, yRadius: s * 0.07)
    NSColor(red: 0.03, green: 0.05, blue: 0.10, alpha: 1).setFill()
    face.fill()
    face.lineWidth = s * 0.016
    cyan.setStroke()
    face.stroke()
    let crown = NSBezierPath(roundedRect: NSRect(x: watch.maxX + s * 0.004, y: watch.midY + s * 0.02, width: s * 0.026, height: s * 0.07),
                             xRadius: s * 0.01, yRadius: s * 0.01)
    cyan.setFill()
    crown.fill()

    // Pointer arrow launched from the watch face.
    let tip = NSPoint(x: s * 0.44, y: s * 0.62)
    let arrow = NSBezierPath()
    arrow.move(to: tip)
    arrow.line(to: NSPoint(x: tip.x, y: tip.y - s * 0.19))
    arrow.line(to: NSPoint(x: tip.x + s * 0.045, y: tip.y - s * 0.145))
    arrow.line(to: NSPoint(x: tip.x + s * 0.075, y: tip.y - s * 0.205))
    arrow.line(to: NSPoint(x: tip.x + s * 0.10, y: tip.y - s * 0.19))
    arrow.line(to: NSPoint(x: tip.x + s * 0.07, y: tip.y - s * 0.135))
    arrow.line(to: NSPoint(x: tip.x + s * 0.135, y: tip.y - s * 0.135))
    arrow.close()
    NSColor.white.setFill()
    arrow.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let iconset = here.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, pixels) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                       ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try? render(pixels)?.write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
print("wrote \(iconset.path)")
