import AppKit

// What the two displays show. Everything is drawn per frame with CoreGraphics so it can be
// choreographed exactly against the 3D action.

// MARK: - Watch face

enum WatchFace {
    case off
    /// The Gauntlet ring waking up; `appear` 0...1.
    case ready(appear: Double)
    case code(String, appear: Double)
    case paired(appear: Double)
    /// Live control: a coloured ring with a symbol and a one-word state.
    case mode(label: String, symbol: String, color: NSColor, flash: Double)
}

enum WatchScreen {
    static let width = 400, height = 480

    static func draw(_ face: WatchFace, time: Double) -> CGImage {
        drawImage(width: width, height: height) { ctx in
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let center = CGPoint(x: 200, y: 232)

            func chrome(_ alpha: Double) {
                drawText("Gauntlet", at: CGPoint(x: 34, y: 30), font: font(27, .semibold, rounded: true),
                         color: NSColor(white: 1, alpha: 0.42 * alpha))
                drawText("9:41", at: CGPoint(x: 366, y: 30), font: font(27, .semibold, rounded: true),
                         color: NSColor(white: 1, alpha: 0.9 * alpha), align: .right)
            }

            func ring(color: NSColor, alpha: Double, radius: CGFloat = 104, sweep: Double = 0.62, flash: Double = 0) {
                radialGlow(ctx, center: center, radius: radius * 1.9, color: color.withAlphaComponent(0.20 * alpha + 0.35 * flash))
                ctx.setLineWidth(13)
                ctx.setLineCap(.round)
                ctx.setStrokeColor(color.withAlphaComponent(0.20 * alpha).cgColor)
                ctx.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                let start = CGFloat(time * 1.6).truncatingRemainder(dividingBy: 2 * .pi)
                ctx.setStrokeColor(color.withAlphaComponent(alpha).cgColor)
                ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: start + CGFloat(sweep * 2 * .pi), clockwise: false)
                ctx.strokePath()
                if flash > 0.01 {
                    ctx.setFillColor(color.withAlphaComponent(0.55 * flash).cgColor)
                    ctx.fillEllipse(in: CGRect(x: center.x - radius + 14, y: center.y - radius + 14, width: radius * 2 - 28, height: radius * 2 - 28))
                }
            }

            switch face {
            case .off:
                break

            case .ready(let appear):
                let a = ease(appear)
                chrome(a)
                ring(color: Palette.cyan, alpha: a, sweep: 0.25 + 0.4 * a)
                drawSymbol("scope", center: center, pointSize: 62, color: NSColor(white: 1, alpha: a), in: ctx)
                drawText("READY", at: CGPoint(x: 200, y: 372), font: font(36, .heavy, rounded: true),
                         color: NSColor(white: 1, alpha: a), align: .center, tracking: 7)

            case .code(let code, let appear):
                let a = ease(appear)
                chrome(a)
                drawSymbol("lock.shield.fill", center: CGPoint(x: 200, y: 132), pointSize: 46, color: Palette.amber.withAlphaComponent(a), in: ctx)
                drawText("PAIRING CODE", at: CGPoint(x: 200, y: 182), font: font(22, .bold, rounded: true),
                         color: NSColor(white: 1, alpha: 0.5 * a), align: .center, tracking: 4)
                drawText(code, at: CGPoint(x: 200, y: 222 + (1 - a) * 14), font: font(66, .bold, mono: true),
                         color: Palette.amber.withAlphaComponent(a), align: .center, tracking: -1,
                         shadow: Palette.amber.withAlphaComponent(0.6 * a), shadowBlur: 22)
                drawText("Confirm on your Mac", at: CGPoint(x: 200, y: 336), font: font(27, .medium, rounded: true),
                         color: NSColor(white: 1, alpha: 0.75 * a), align: .center)

            case .paired(let appear):
                let pop = easeBack(appear)
                chrome(1)
                radialGlow(ctx, center: center, radius: 220, color: Palette.green.withAlphaComponent(0.30 * ease(appear)))
                let r = 92 * pop
                ctx.setFillColor(Palette.green.cgColor)
                ctx.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
                drawSymbol("checkmark", center: center, pointSize: 84 * pop, weight: .heavy, color: .black, in: ctx)
                drawText("PAIRED", at: CGPoint(x: 200, y: 372), font: font(36, .heavy, rounded: true),
                         color: NSColor(white: 1, alpha: ease(appear)), align: .center, tracking: 7)

            case .mode(let label, let symbol, let color, let flash):
                chrome(1)
                ring(color: color, alpha: 1, sweep: 0.68, flash: flash)
                drawSymbol(symbol, center: center, pointSize: 66, color: flash > 0.5 ? .black : .white, in: ctx)
                drawText(label, at: CGPoint(x: 200, y: 372), font: font(36, .heavy, rounded: true),
                         color: .white, align: .center, tracking: 6)
            }
        }
    }
}

// MARK: - Mac display

/// The interactive desktop the gestures act on.
struct DemoState {
    var cursor = CGPoint(x: 1500, y: 930)
    var trail: [CGPoint] = []
    var scroll = 0.0
    /// Seconds since each click, with where it landed.
    var clicks: [(at: CGPoint, age: Double, color: NSColor)] = []
    /// Card index -> how long ago it was opened.
    var opened: [Int: Double] = [:]
    var menuOrigin: CGPoint?
    var menuProgress = 0.0
    var menuHighlight = -1
    /// A card being carried: its index, lift 0...1, and where it currently is.
    var carried: (index: Int, lift: Double, center: CGPoint)?
    /// Final slots for cards that have been swapped by a completed drag.
    var slotOverride: [Int: Int] = [:]
    var slotBlend = 1.0
}

enum MacScreen {
    static let width = 1920, height = 1200
    static let full = CGRect(x: 0, y: 0, width: 1920, height: 1200)

    static let cards: [(name: String, symbol: String, color: NSColor)] = [
        ("Keynote", "play.rectangle.fill", Palette.cyan), ("Design", "paintbrush.pointed.fill", Palette.violet),
        ("Photos", "photo.fill", Palette.pink), ("Music", "music.note", Palette.amber),
        ("Notes", "note.text", Palette.green), ("Code", "chevron.left.forwardslash.chevron.right", Palette.blue),
        ("Travel", "airplane", Palette.cyan), ("Finance", "chart.line.uptrend.xyaxis", Palette.green),
        ("Health", "heart.fill", Palette.pink), ("Mail", "envelope.fill", Palette.blue),
        ("Calendar", "calendar", Palette.amber), ("Maps", "map.fill", Palette.green),
        ("Books", "book.fill", Palette.violet), ("Games", "gamecontroller.fill", Palette.pink),
        ("Weather", "cloud.sun.fill", Palette.cyan),
    ]

    /// The playground is laid out at 1x and drawn enlarged about the screen centre, so it fills the display.
    static let demoZoom: CGFloat = 1.2
    static func demoToScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: 960 + (p.x - 960) * demoZoom, y: 600 + (p.y - 600) * demoZoom)
    }

    static let window = CGRect(x: 300, y: 150, width: 1320, height: 900)
    static let content = CGRect(x: 300, y: 214, width: 1320, height: 836)
    static let cardSize = CGSize(width: 380, height: 230)

    /// Centre of grid slot `slot` (0 = top-left) at the given scroll offset.
    static func slotCenter(_ slot: Int, scroll: Double) -> CGPoint {
        let row = slot / 3, column = slot % 3
        return CGPoint(x: 540 + CGFloat(column) * 420, y: 379 + CGFloat(row) * 270 - CGFloat(scroll))
    }

    static func cardIndex(at point: CGPoint, scroll: Double) -> Int? {
        guard content.contains(point) else { return nil }
        for slot in cards.indices {
            let c = slotCenter(slot, scroll: scroll)
            if abs(point.x - c.x) <= cardSize.width / 2, abs(point.y - c.y) <= cardSize.height / 2 { return slot }
        }
        return nil
    }

    // MARK: Screens

    static func black() -> CGImage {
        drawImage(width: 16, height: 10) { ctx in
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 10))
        }
    }

    /// A real screenshot of the app, optionally faded up from black or zoomed.
    static func app(_ image: CGImage?, brightness: Double = 1, zoom: CGFloat = 1, focus: CGPoint = CGPoint(x: 0.5, y: 0)) -> CGImage {
        drawImage(width: width, height: height) { ctx in
            ctx.setFillColor(Palette.ink.cgColor)
            ctx.fill(full)
            if let image { drawAspectFill(image, in: full, ctx: ctx, zoom: zoom, focus: focus) }
            if brightness < 1 {
                ctx.setFillColor(NSColor(white: 0, alpha: 1 - brightness).cgColor)
                ctx.fill(full)
            }
        }
    }

    /// The pairing sheet over the app. `approve` 0...1 presses the Pair button; `done` 0...1 turns it into a tick.
    static func pairing(over image: CGImage?, code: String, appear: Double, approve: Double, done: Double) -> CGImage {
        drawImage(width: width, height: height) { ctx in
            ctx.setFillColor(Palette.ink.cgColor)
            ctx.fill(full)
            if let image { drawAspectFill(image, in: full, ctx: ctx) }
            let a = ease(appear)
            ctx.setFillColor(NSColor(white: 0, alpha: 0.62 * a).cgColor)
            ctx.fill(full)

            let sheet = CGRect(x: 520, y: 300 + (1 - a) * 40, width: 880, height: 600)
            ctx.saveGState()
            ctx.setAlpha(a)
            ctx.setShadow(offset: CGSize(width: 0, height: 30), blur: 80, color: NSColor(white: 0, alpha: 0.7).cgColor)
            ctx.addPath(roundedPath(sheet, 44))
            ctx.setFillColor(rgb(0x161B29).cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.setAlpha(a)
            ctx.addPath(roundedPath(sheet, 44))
            ctx.setStrokeColor(NSColor(white: 1, alpha: 0.16).cgColor)
            ctx.setLineWidth(2)
            ctx.strokePath()

            let midX = sheet.midX
            if done < 0.02 {
                let tint = Palette.amber
                radialGlow(ctx, center: CGPoint(x: midX, y: sheet.minY + 110), radius: 190, color: tint.withAlphaComponent(0.22))
                drawSymbol("applewatch.radiowaves.left.and.right", center: CGPoint(x: midX, y: sheet.minY + 104), pointSize: 74, color: tint, in: ctx)
                drawText("Pair with Apple Watch?", at: CGPoint(x: midX, y: sheet.minY + 178), font: font(50, .bold, rounded: true), color: .white, align: .center)
                drawText("Approve only if your watch shows this code.", at: CGPoint(x: midX, y: sheet.minY + 250),
                         font: font(27, .regular), color: NSColor(white: 1, alpha: 0.6), align: .center)
                drawText(code, at: CGPoint(x: midX, y: sheet.minY + 308), font: font(104, .bold, mono: true), color: tint, align: .center,
                         shadow: tint.withAlphaComponent(0.55), shadowBlur: 34)

                let decline = CGRect(x: midX - 290, y: sheet.maxY - 124, width: 270, height: 78)
                ctx.addPath(roundedPath(decline, 39))
                ctx.setFillColor(NSColor(white: 1, alpha: 0.09).cgColor)
                ctx.fillPath()
                drawText("Decline", at: CGPoint(x: decline.midX, y: decline.minY + 20), font: font(30, .medium, rounded: true),
                         color: NSColor(white: 1, alpha: 0.85), align: .center)

                let press = bump(approve, 0, 1)
                let pair = CGRect(x: midX + 20, y: sheet.maxY - 124, width: 270, height: 78).insetBy(dx: press * 5, dy: press * 3)
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: 30 + 40 * press, color: tint.withAlphaComponent(0.7).cgColor)
                ctx.addPath(roundedPath(pair, 39))
                ctx.setFillColor(tint.mixed(.white, 0.5 * press).cgColor)
                ctx.fillPath()
                ctx.restoreGState()
                drawText("Pair", at: CGPoint(x: pair.midX, y: pair.minY + 20), font: font(30, .bold, rounded: true),
                         color: NSColor(white: 0, alpha: 0.85), align: .center)
            } else {
                let pop = easeBack(done)
                let c = CGPoint(x: midX, y: sheet.midY - 50)
                radialGlow(ctx, center: c, radius: 330, color: Palette.green.withAlphaComponent(0.26 * ease(done)))
                let r = 100 * pop
                ctx.setFillColor(Palette.green.cgColor)
                ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                drawSymbol("checkmark", center: c, pointSize: 92 * pop, weight: .heavy, color: .black, in: ctx)
                drawText("Paired", at: CGPoint(x: midX, y: c.y + 136), font: font(58, .bold, rounded: true),
                         color: NSColor(white: 1, alpha: ease(done)), align: .center)
                drawText("Apple Watch is now your pointer.", at: CGPoint(x: midX, y: c.y + 214), font: font(28, .regular),
                         color: NSColor(white: 1, alpha: 0.6 * ease(done)), align: .center)
            }
            ctx.restoreGState()
        }
    }

    /// The gesture playground: a window of project cards the pointer moves over, opens, right-clicks, scrolls and drags.
    static func demo(_ state: DemoState, time: Double) -> CGImage {
        drawImage(width: width, height: height) { ctx in
            // Wallpaper.
            fillGradient(ctx, path: CGPath(rect: full, transform: nil), colors: [rgb(0x0A1022), rgb(0x150B2C)],
                         from: CGPoint(x: 0, y: 0), to: CGPoint(x: 1920, y: 1200))
            radialGlow(ctx, center: CGPoint(x: 1650 + 60 * sin(time * 0.3), y: 160), radius: 900, color: Palette.cyan.withAlphaComponent(0.22))
            radialGlow(ctx, center: CGPoint(x: 220, y: 1080 + 40 * cos(time * 0.25)), radius: 820, color: Palette.violet.withAlphaComponent(0.26))
            radialGlow(ctx, center: CGPoint(x: 960, y: 620), radius: 700, color: Palette.blue.withAlphaComponent(0.08))

            ctx.translateBy(x: 960, y: 600)
            ctx.scaleBy(x: demoZoom, y: demoZoom)
            ctx.translateBy(x: -960, y: -600)

            // Window.
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 36), blur: 90, color: NSColor(white: 0, alpha: 0.65).cgColor)
            ctx.addPath(roundedPath(window, 34))
            ctx.setFillColor(rgb(0x121726, 0.94).cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            ctx.addPath(roundedPath(window, 34))
            ctx.setStrokeColor(NSColor(white: 1, alpha: 0.14).cgColor)
            ctx.setLineWidth(2)
            ctx.strokePath()
            for i in 0..<3 {
                ctx.setFillColor(NSColor(white: 1, alpha: 0.22).cgColor)
                ctx.fillEllipse(in: CGRect(x: window.minX + 30 + CGFloat(i) * 30, y: window.minY + 24, width: 18, height: 18))
            }
            drawText("Projects", at: CGPoint(x: window.midX, y: window.minY + 16), font: font(26, .semibold),
                     color: NSColor(white: 1, alpha: 0.8), align: .center)
            ctx.setFillColor(NSColor(white: 1, alpha: 0.08).cgColor)
            ctx.fill(CGRect(x: window.minX, y: content.minY - 1, width: window.width, height: 2))

            // Cards, clipped to the scrolling area.
            ctx.saveGState()
            ctx.addPath(roundedPath(CGRect(x: content.minX + 2, y: content.minY + 2, width: content.width - 4, height: content.height - 4), 30))
            ctx.clip()
            let hover = state.carried == nil && state.menuOrigin == nil ? cardIndex(at: state.cursor, scroll: state.scroll) : nil
            for index in cards.indices where index != state.carried?.index {
                var center = slotCenter(index, scroll: state.scroll)
                if let target = state.slotOverride[index] {
                    center = mix(center, slotCenter(target, scroll: state.scroll), easeInOut(state.slotBlend))
                }
                guard center.y > content.minY - 160, center.y < content.maxY + 160 else { continue }
                let age = state.opened[index]
                let pop = age.map { 1 + 0.07 * bump($0, 0, 0.45) } ?? 1
                card(ctx, index: index, center: center, scale: (hover == index ? 1.035 : 1) * pop,
                     highlight: hover == index ? 1 : 0, opened: age.map { ease(prog($0, 0.05, 0.4)) } ?? 0, lift: 0)
            }
            ctx.restoreGState()

            // Scroll bar.
            let track = CGRect(x: window.maxX - 22, y: content.minY + 20, width: 8, height: content.height - 40)
            ctx.addPath(roundedPath(track, 4))
            ctx.setFillColor(NSColor(white: 1, alpha: 0.06).cgColor)
            ctx.fillPath()
            let total = 5 * 270.0 + 60, visible = Double(content.height)
            let thumbH = track.height * CGFloat(visible / total)
            let thumbY = track.minY + (track.height - thumbH) * CGFloat(state.scroll / max(1, total - visible))
            ctx.addPath(roundedPath(CGRect(x: track.minX, y: thumbY, width: 8, height: thumbH), 4))
            ctx.setFillColor(NSColor(white: 1, alpha: state.scroll > 1 ? 0.5 : 0.22).cgColor)
            ctx.fillPath()

            // The carried card rides above everything.
            if let carried = state.carried {
                card(ctx, index: carried.index, center: carried.center, scale: 1 + 0.08 * carried.lift, highlight: 1, opened: 0, lift: carried.lift)
            }

            // Context menu.
            if let origin = state.menuOrigin, state.menuProgress > 0.01 {
                let a = ease(state.menuProgress)
                let items = ["Open", "Share…", "Rename", "Duplicate", "Move to Trash"]
                let rect = CGRect(x: origin.x + 14, y: origin.y + 10, width: 330, height: CGFloat(items.count) * 54 + 20)
                ctx.saveGState()
                ctx.setAlpha(a)
                ctx.translateBy(x: rect.minX, y: rect.minY)
                ctx.scaleBy(x: 0.92 + 0.08 * a, y: 0.92 + 0.08 * a)
                ctx.translateBy(x: -rect.minX, y: -rect.minY)
                ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 46, color: NSColor(white: 0, alpha: 0.7).cgColor)
                ctx.addPath(roundedPath(rect, 20))
                ctx.setFillColor(rgb(0x232838, 0.98).cgColor)
                ctx.fillPath()
                ctx.setShadow(offset: .zero, blur: 0, color: nil)
                ctx.addPath(roundedPath(rect, 20))
                ctx.setStrokeColor(NSColor(white: 1, alpha: 0.16).cgColor)
                ctx.setLineWidth(1.5)
                ctx.strokePath()
                for (i, item) in items.enumerated() {
                    let row = CGRect(x: rect.minX + 10, y: rect.minY + 10 + CGFloat(i) * 54, width: rect.width - 20, height: 54)
                    if i == state.menuHighlight {
                        ctx.addPath(roundedPath(row, 12))
                        ctx.setFillColor(Palette.violet.cgColor)
                        ctx.fillPath()
                    }
                    drawText(item, at: CGPoint(x: row.minX + 18, y: row.minY + 11), font: font(27, .medium),
                             color: i == items.count - 1 && i != state.menuHighlight ? Palette.pink : .white)
                }
                ctx.restoreGState()
            }

            // Click ripples.
            for click in state.clicks where click.age >= 0 && click.age < 0.7 {
                let p = click.age / 0.7
                let r = 18 + 110 * easeOut(p)
                ctx.setStrokeColor(click.color.withAlphaComponent((1 - p) * 0.95).cgColor)
                ctx.setLineWidth(7 * (1 - p) + 1.5)
                ctx.strokeEllipse(in: CGRect(x: click.at.x - r, y: click.at.y - r, width: r * 2, height: r * 2))
            }

            // Pointer with a short comet tail.
            for (i, p) in state.trail.enumerated() {
                let f = 1 - Double(i + 1) / Double(state.trail.count + 1)
                let r = 5 + 9 * f
                ctx.setFillColor(Palette.cyan.withAlphaComponent(0.20 * f).cgColor)
                ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            }
            radialGlow(ctx, center: state.cursor, radius: 70, color: Palette.cyan.withAlphaComponent(0.30))
            pointer(ctx, at: state.cursor, grabbing: state.carried != nil)
        }
    }

    private static func card(_ ctx: CGContext, index: Int, center: CGPoint, scale: Double, highlight: Double, opened: Double, lift: Double) {
        let item = cards[index]
        let w = cardSize.width * scale, h = cardSize.height * scale
        let rect = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 10 + 30 * lift), blur: 24 + 60 * lift,
                      color: (lift > 0 ? item.color.withAlphaComponent(0.5) : NSColor(white: 0, alpha: 0.5)).cgColor)
        ctx.addPath(roundedPath(rect, 26))
        ctx.setFillColor(rgb(0x1B2134).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        fillGradient(ctx, path: roundedPath(rect, 26),
                     colors: [item.color.withAlphaComponent(0.42 + 0.2 * highlight), item.color.withAlphaComponent(0.10 + 0.08 * highlight)],
                     from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.maxY))
        ctx.addPath(roundedPath(rect, 26))
        ctx.setStrokeColor((highlight > 0 ? NSColor(white: 1, alpha: 0.75) : NSColor(white: 1, alpha: 0.14)).cgColor)
        ctx.setLineWidth(highlight > 0 ? 3 : 1.5)
        ctx.strokePath()

        let badge = CGRect(x: rect.minX + 28, y: rect.minY + 28, width: 76, height: 76)
        fillGradient(ctx, path: roundedPath(badge, 20), colors: [item.color, item.color.mixed(.black, 0.3)],
                     from: CGPoint(x: badge.minX, y: badge.minY), to: CGPoint(x: badge.minX, y: badge.maxY))
        drawSymbol(item.symbol, center: CGPoint(x: badge.midX, y: badge.midY), pointSize: 36, color: .white, in: ctx)
        drawText(item.name, at: CGPoint(x: rect.minX + 28, y: rect.maxY - 92), font: font(34, .semibold, rounded: true), color: .white)
        drawText(opened > 0.5 ? "Opened" : "\(3 + (index * 7) % 19) items", at: CGPoint(x: rect.minX + 28, y: rect.maxY - 50),
                 font: font(22, .regular), color: opened > 0.5 ? Palette.green : NSColor(white: 1, alpha: 0.55))
        if opened > 0.01 {
            let c = CGPoint(x: rect.maxX - 54, y: rect.minY + 54)
            let r = 24 * easeBack(opened)
            ctx.setFillColor(Palette.green.cgColor)
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            drawSymbol("checkmark", center: c, pointSize: 22 * easeBack(opened), weight: .heavy, color: .black, in: ctx)
        }
    }

    /// The familiar arrow pointer, drawn large enough to read from the back of a hall.
    private static func pointer(_ ctx: CGContext, at p: CGPoint, grabbing: Bool) {
        ctx.saveGState()
        ctx.translateBy(x: p.x, y: p.y)
        ctx.scaleBy(x: 2.6, y: 2.6)
        let arrow = CGMutablePath()
        arrow.move(to: CGPoint(x: 0, y: 0))
        arrow.addLine(to: CGPoint(x: 0, y: 17))
        arrow.addLine(to: CGPoint(x: 4.2, y: 13.2))
        arrow.addLine(to: CGPoint(x: 7, y: 19.6))
        arrow.addLine(to: CGPoint(x: 9.6, y: 18.4))
        arrow.addLine(to: CGPoint(x: 6.9, y: 12.2))
        arrow.addLine(to: CGPoint(x: 12.2, y: 12.2))
        arrow.closeSubpath()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 6, color: NSColor(white: 0, alpha: 0.6).cgColor)
        ctx.addPath(arrow)
        ctx.setFillColor((grabbing ? Palette.violet : NSColor.white).cgColor)
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.addPath(arrow)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(1.1)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.restoreGState()
    }
}
