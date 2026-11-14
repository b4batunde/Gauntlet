import AppKit
import SceneKit
import simd

/// The film, shot by shot. `apply(t)` poses every object, light and screen for time `t`;
/// `overlay` draws the titles on top of the rendered frame.
///
///   0-5    cold open (type on black)
///   5-12   the watch, alone
///   12-19  the Mac opens
///   19-27  pairing
///   27-46  gestures: point, tap, flick, scroll, grab
///   46-53  what is inside
///   53-59  the Dojo
///   59-66  finale
final class Director {
    static let duration = 66.0
    static let cuts: [Double] = [12.0, 27.0, 46.5, 53.0, 59.0]
    static let pairingCode = "482 913"

    // Beats inside the gesture sequence (film time, seconds).
    static let taps: [Double] = [32.5, 34.9]
    static let flickOut = 36.6
    static let scrollStart = 40.3, scrollEnd = 42.5
    static let grab = 43.9, drop = 45.7

    let studio: Studio
    private let appWaiting: CGImage?
    private let appPointing: CGImage?
    private let dojo: CGImage?
    private var macKey = ""
    private var staticScreens: [String: CGImage] = [:]

    init(studio: Studio, assets: String) {
        self.studio = studio
        appWaiting = loadImage(assets + "/app-waiting.png")
        appPointing = loadImage(assets + "/app-pointing.png")
        dojo = loadImage(assets + "/dojo.png")
        if appWaiting == nil || appPointing == nil || dojo == nil {
            FileHandle.standardError.write(Data("warning: some screenshots are missing from \(assets)\n".utf8))
        }
    }

    // MARK: - Gesture playground state

    private static let cursorKeys: [(Double, CGPoint)] = [
        (27.0, CGPoint(x: 1500, y: 930)), (27.5, CGPoint(x: 1500, y: 930)), (28.9, CGPoint(x: 540, y: 400)),
        (30.3, CGPoint(x: 1380, y: 660)), (31.6, CGPoint(x: 960, y: 385)), (33.5, CGPoint(x: 960, y: 385)),
        (34.5, CGPoint(x: 540, y: 655)), (37.4, CGPoint(x: 540, y: 655)), (38.3, CGPoint(x: 700, y: 758)),
        (39.2, CGPoint(x: 700, y: 758)), (40.1, CGPoint(x: 900, y: 640)), (43.0, CGPoint(x: 900, y: 640)),
        (43.7, CGPoint(x: 1380, y: 385)), (44.1, CGPoint(x: 1380, y: 385)), (45.5, CGPoint(x: 540, y: 655)),
        (45.9, CGPoint(x: 540, y: 655)), (46.6, CGPoint(x: 760, y: 800)),
    ]

    static func cursor(_ t: Double) -> CGPoint { keyed(cursorKeys, t) }

    static func demoState(_ t: Double) -> DemoState {
        var s = DemoState()
        s.cursor = cursor(t)
        s.trail = (1...10).map { cursor(t - Double($0) * 0.02) }
        s.scroll = keyed([(scrollStart, 0), (scrollEnd, 540)], t)

        for (i, tap) in taps.enumerated() where t >= tap {
            s.clicks.append((cursor(tap), t - tap, Palette.cyan))
            s.opened[i == 0 ? 1 : 3] = t - tap
        }
        if t >= flickOut { s.clicks.append((cursor(flickOut), t - flickOut, Palette.violet)) }
        if t >= drop { s.clicks.append((MacScreen.slotCenter(9, scroll: 540), t - drop, Palette.violet)) }

        // Context menu.
        let menu = ease(prog(t, flickOut + 0.12, flickOut + 0.36)) * (1 - ease(prog(t, 39.0, 39.25)))
        if menu > 0.01 {
            let origin = cursor(flickOut)
            s.menuOrigin = origin
            s.menuProgress = menu
            let row = Int(floor((s.cursor.y - (origin.y + 20)) / 54))
            if s.cursor.x > origin.x + 14, s.cursor.x < origin.x + 344, (0..<5).contains(row) { s.menuHighlight = row }
        }

        // Drag: card 8 is carried to slot 9 and card 9 slides out of the way.
        if t >= grab {
            let settle = ease(prog(t, drop, drop + 0.25))
            if t < drop + 0.25 {
                let lift = ease(prog(t, grab, grab + 0.2)) * (1 - settle)
                let held = t < drop ? s.cursor : mix(cursor(drop), MacScreen.slotCenter(9, scroll: 540), settle)
                s.carried = (8, lift, held)
                s.slotOverride = [9: 8]
                s.slotBlend = prog(t, 44.9, 45.6)
            } else {
                s.slotOverride = [8: 9, 9: 8]
                s.slotBlend = 1
            }
        }
        return s
    }

    // MARK: - Posing

    /// Camera-facing pose for beauty shots.
    private func heroOrientation(yaw: Double, tilt: Double, roll: Double = 0) -> simd_quatf {
        simd_quatf(angle: Float(yaw), axis: V3(0, 1, 0)) * simd_quatf(angle: Float(tilt), axis: V3(1, 0, 0))
            * simd_quatf(angle: Float(roll), axis: V3(0, 0, 1))
    }

    /// The watch as worn on a forearm that points at the screen. `heading` + turns left,
    /// `elevation` lifts the hand, `roll` twists the wrist.
    private func wornOrientation(heading: Double, elevation: Double, roll: Double) -> simd_quatf {
        let h = Float(heading), e = Float(elevation), r = Float(roll)
        let forward = V3(-sin(h) * cos(e), sin(e), -cos(h) * cos(e))
        let right = simd_normalize(simd_cross(forward, V3(0, 1, 0)))
        let up = simd_cross(right, forward)
        let normal = up * cos(r) + right * sin(r)
        let x = forward, z = normal, y = simd_cross(z, x)
        return simd_quatf(simd_float3x3(columns: (x, y, z)))
    }

    private func setLights(key: Double, rim: Double, target: V3) {
        studio.key.light?.intensity = CGFloat(520 * key)
        studio.rimCool.light?.intensity = CGFloat(620 * rim)
        studio.rimWarm.light?.intensity = CGFloat(560 * rim)
        studio.aim(studio.key, from: target + V3(1.6, 4.6, 4.2), at: target)
        studio.aim(studio.rimCool, from: target + V3(-4.2, 2.4, -3.4), at: target)
        studio.aim(studio.rimWarm, from: target + V3(4.2, 1.8, -3.2), at: target)
    }

    private func setPool(at position: V3, intensity: Double, size: Float) {
        studio.poolNode.simdPosition = V3(position.x, 0.004, position.z)
        studio.poolNode.simdScale = V3(size, size, 1)
        studio.pool.emission.intensity = CGFloat(intensity)
    }

    /// A point given in the camera's own space (x right, y up, -z ahead), as a world position.
    /// Keeps the watch at the same place in frame while the camera travels.
    private func inFrame(_ offset: V3) -> V3 {
        let p = studio.cameraNode.simdWorldTransform * SIMD4<Float>(offset.x, offset.y, offset.z, 1)
        return V3(p.x, p.y, p.z)
    }

    /// World position of a point on the Mac's display given in screen pixels.
    private func screenPoint(_ p: CGPoint) -> V3 {
        let x = (Float(p.x) / Float(MacScreen.width) - 0.5) * Float(MacModel.screenWidth)
        let y = Float(MacModel.depth) / 2 + 0.03 + (0.5 - Float(p.y) / Float(MacScreen.height)) * Float(MacModel.screenHeight)
        return studio.mac.lid.simdConvertPosition(V3(x, y, 0.03), to: nil)
    }

    private func setMacScreen(key: String?, _ make: () -> CGImage) {
        if let key {
            guard key != macKey else { return }
            macKey = key
            if staticScreens[key] == nil { staticScreens[key] = make() }
            studio.mac.screen.emission.contents = staticScreens[key]
        } else {
            macKey = ""
            studio.mac.screen.emission.contents = make()
        }
    }

    func apply(_ t: Double) {
        let s = studio
        s.resetSparks()
        s.sweep.light?.intensity = 0
        s.watch.crownGlow.opacity = 0
        s.watch.crown.eulerAngles.x = 0
        for i in 0..<3 { s.watch.setRipple(i, progress: 0) }
        s.watch.sensorGlow.emission.intensity = 0.25
        s.watch.body.simdPosition = .zero
        let breathe = sin(t * 0.9) * 0.012

        switch t {
        // --- Cold open: darkness ---
        case ..<5.0:
            s.watch.root.isHidden = true
            s.mac.root.isHidden = true
            setLights(key: 0, rim: 0, target: V3(0, 1, 0))
            setPool(at: .zero, intensity: 0.10 * ease(prog(t, 2.5, 5)), size: 0.7)
            s.aim(s.cameraNode, from: V3(0, 1.2, 4.8), at: V3(0, 1.0, 0))

        // --- The watch, alone ---
        case ..<12.0:
            s.watch.root.isHidden = false
            s.mac.root.isHidden = true
            let reveal = ease(prog(t, 5.0, 7.2))
            setLights(key: 0.15 + 0.85 * reveal, rim: 0.95 * reveal, target: V3(0, 1.2, 0))
            setPool(at: .zero, intensity: 0.10 + 0.16 * reveal, size: 0.7)
            s.watch.root.simdPosition = V3(0, 1.22 + Float(breathe), 0)
            s.watch.root.simdScale = V3(repeating: 2.1)
            let yaw = keyed([(5.0, -2.5), (8.6, -0.95), (12.0, -0.42)], t)
            s.watch.root.simdOrientation = heroOrientation(yaw: yaw, tilt: 0.10, roll: 0.05)
            let cam = keyed([(5.0, V3(-0.5, 1.0, 4.9)), (12.0, V3(0.35, 1.22, 4.0))], t)
            s.aim(s.cameraNode, from: cam, at: V3(0, 1.0, 0))
            // A light that travels across the case as it turns.
            let sweepT = prog(t, 5.6, 9.4)
            s.sweep.light?.intensity = CGFloat(150 * bump(t, 5.6, 9.4))
            s.aim(s.sweep, from: V3(Float(mix(-5.5, 5.5, sweepT)), 2.6, 5.2), at: V3(0, 1.2, 0))
            s.watch.display.emission.contents = WatchScreen.draw(t < 7.4 ? .off : .ready(appear: prog(t, 7.4, 8.5)), time: t)

        // --- The Mac opens; the watch arrives ---
        case ..<19.0:
            s.mac.root.isHidden = false
            let focus = V3(0.2, 0.9, -0.2)
            setLights(key: 1, rim: 0.42, target: focus)
            setPool(at: V3(0.3, 0, 0.2), intensity: 0.22, size: 1.25)
            s.mac.setOpen(easeInOut(prog(t, 12.5, 15.3)))
            s.mac.keyboardGlow.emission.intensity = CGFloat(0.55 * ease(prog(t, 14.0, 15.6)))
            if t < 13.5 {
                setMacScreen(key: "black") { MacScreen.black() }
            } else if t < 15.2 {
                setMacScreen(key: nil) { MacScreen.app(self.appWaiting, brightness: ease(prog(t, 13.5, 15.2))) }
            } else {
                setMacScreen(key: "waiting") { MacScreen.app(self.appWaiting) }
            }
            let cam = keyed([(12.0, V3(-2.6, 1.05, 4.9)), (15.6, V3(-0.3, 1.9, 6.9)), (19.0, V3(0.95, 1.85, 6.8))], t)
            s.aim(s.cameraNode, from: cam, at: keyed([(12.0, V3(0, 0.7, -0.2)), (15.6, V3(0.2, 1.55, -0.2)), (19.0, V3(0.7, 1.55, 0))], t))
            // Watch flies in from the right.
            let arrive = easeOut(prog(t, 16.0, 17.8))
            s.watch.root.isHidden = t < 16.0
            s.watch.root.simdPosition = mix(V3(5.2, 1.9, 2.6), V3(2.3, 0.98 + Float(breathe), 1.2), arrive)
            s.watch.root.simdScale = V3(repeating: 1.5)
            s.watch.root.simdOrientation = heroOrientation(yaw: mix(-1.6, -0.52, arrive), tilt: 0.1, roll: 0.04)
            s.watch.display.emission.contents = WatchScreen.draw(.ready(appear: 1), time: t)

        // --- Pairing ---
        case ..<27.0:
            let focus = V3(0.7, 1.55, 0)
            s.mac.root.isHidden = false
            setLights(key: 1, rim: 0.42, target: V3(0.7, 0.95, 0))
            setPool(at: V3(0.6, 0, 0.3), intensity: 0.22 + 0.25 * bump(t, 23.0, 24.4), size: 1.3)
            s.mac.setOpen(1)
            let success = 23.0
            s.mac.keyboardGlow.emission.intensity = CGFloat(0.55 + 0.9 * bump(t, success, success + 0.9))
            let watchHome = V3(2.3, 0.98 + Float(breathe), 1.2)
            s.watch.root.isHidden = false
            s.watch.root.simdPosition = watchHome
            s.watch.root.simdScale = V3(repeating: 1.5 + 0.06 * Float(bump(t, success, success + 0.5)))
            s.watch.root.simdOrientation = heroOrientation(yaw: -0.52 + 0.05 * sin(t * 0.7), tilt: 0.1, roll: 0.04)
            let cam = keyed([(19.0, V3(0.95, 1.85, 6.8)), (23.0, V3(1.45, 1.7, 6.3)), (27.0, V3(1.2, 1.75, 6.5))], t)
            s.aim(s.cameraNode, from: cam, at: focus)

            if t < 19.6 {
                s.watch.display.emission.contents = WatchScreen.draw(.ready(appear: 1), time: t)
            } else if t < success {
                s.watch.display.emission.contents = WatchScreen.draw(.code(Self.pairingCode, appear: prog(t, 19.6, 20.1)), time: t)
            } else if t < 25.4 {
                s.watch.display.emission.contents = WatchScreen.draw(.paired(appear: prog(t, success, success + 0.45)), time: t)
            } else {
                s.watch.display.emission.contents = WatchScreen.draw(.ready(appear: 1), time: t)
            }
            if t < 19.9 {
                setMacScreen(key: "waiting") { MacScreen.app(self.appWaiting) }
            } else if t < 24.8 {
                setMacScreen(key: nil) {
                    MacScreen.pairing(over: self.appWaiting, code: Self.pairingCode, appear: prog(t, 19.9, 20.4),
                                      approve: prog(t, 22.45, 22.85), done: prog(t, success, success + 0.5))
                }
            } else if t < 25.4 {
                setMacScreen(key: nil) {
                    MacScreen.pairing(over: self.appPointing, code: Self.pairingCode, appear: 1 - prog(t, 24.8, 25.4), approve: 1, done: 1)
                }
            } else {
                setMacScreen(key: "pointing") { MacScreen.app(self.appPointing) }
            }

            // Pulses of light travelling from the watch to the Mac, then a burst on success.
            let from = watchHome + V3(-0.25, 0.1, 0.1)
            let to = screenPoint(CGPoint(x: 960, y: 600))
            let control = (from + to) / 2 + V3(0, 1.25, 0.5)
            func arc(_ u: Float) -> V3 { (1 - u) * (1 - u) * from + 2 * (1 - u) * u * control + u * u * to }
            if t > 20.5, t < success + 0.3 {
                let strength = ease(prog(t, 20.5, 21.0)) * (1 - ease(prog(t, success, success + 0.3)))
                for pulse in 0..<3 {
                    let head = ((t - 20.5) * 0.62 + Double(pulse) / 3).truncatingRemainder(dividingBy: 1)
                    for k in 0..<16 {
                        let u = head - Double(k) * 0.016
                        guard u > 0, u < 1 else { continue }
                        let fade = 1 - Double(k) / 16
                        s.spark(at: arc(Float(u)), size: Float(0.55 + 0.9 * fade), tone: k < 3 ? 2 : 0, alpha: strength * fade * sin(u * .pi))
                    }
                }
                // A faint guide line so the path reads even between pulses.
                for k in 0..<34 {
                    s.spark(at: arc(Float(k) / 33), size: 0.28, tone: 1, alpha: 0.35 * strength)
                }
            }
            if t >= success, t < success + 1.1 {
                let p = prog(t, success, success + 1.1)
                for k in 0..<40 {
                    let a = Float(k) / 40 * 2 * .pi
                    let r = Float(0.2 + 1.5 * easeOut(p))
                    s.spark(at: to + V3(cos(a) * r, sin(a) * r * 0.62, 0.02), size: 0.5, tone: 3, alpha: (1 - p))
                    s.spark(at: watchHome + V3(cos(a) * r * 0.5, sin(a) * r * 0.5, 0.25), size: 0.4, tone: 3, alpha: (1 - p))
                }
            }

        // --- Gestures ---
        case ..<46.5:
            let focus = V3(0.1, 1.12, -1.1)
            s.mac.root.isHidden = false
            setLights(key: 0.9, rim: 0.34, target: V3(0.6, 0.9, 0.2))
            setPool(at: V3(0.3, 0, 0.4), intensity: 0.2, size: 1.2)
            s.mac.setOpen(1)
            s.mac.keyboardGlow.emission.intensity = 0.55
            let state = Self.demoState(t)
            setMacScreen(key: nil) { MacScreen.demo(state, time: t) }
            let cam = keyed([(27.0, V3(-0.95, 1.5, 3.75)), (36.0, V3(-0.5, 1.46, 3.55)), (46.5, V3(0.05, 1.5, 3.65))], t)
            s.aim(s.cameraNode, from: cam, at: focus)

            // The watch on its unseen forearm, moving exactly as the pointer needs.
            let heading = Double(960 - state.cursor.x) / 960 * 0.36
            var elevation = 0.66 + Double(600 - state.cursor.y) / 600 * 0.17
            var roll = 0.0
            roll -= 0.75 * bump(t, Self.flickOut - 0.16, Self.flickOut + 0.2)            // outward (left wrist)
            roll += 0.75 * bump(t, Self.grab - 0.16, Self.grab + 0.2)                    // inward
            roll += 0.75 * bump(t, Self.drop - 0.16, Self.drop + 0.2)
            var dip: Float = 0
            for tap in Self.taps {
                dip += Float(0.035 * bump(t, tap - 0.05, tap + 0.2))
                elevation -= 0.03 * bump(t, tap - 0.05, tap + 0.2)
            }
            let home = inFrame(V3(0.93, -0.41 + Float(breathe) - dip, -2.25))
            s.watch.root.isHidden = false
            s.watch.root.simdPosition = home
            s.watch.root.simdScale = V3(repeating: 1.1)
            s.watch.root.simdOrientation = wornOrientation(heading: heading, elevation: elevation, roll: roll)

            // Which gesture is on stage.
            var symbol = "scope", color = Palette.cyan, flash = 0.0
            for tap in Self.taps {
                let f = 1 - prog(t, tap, tap + 0.45)
                if t >= tap, f > 0 { symbol = "hand.tap.fill"; flash = max(flash, f) }
                for i in 0..<3 where t >= tap {
                    s.watch.setRipple(i, progress: prog(t, tap + Double(i) * 0.12, tap + 0.7 + Double(i) * 0.12))
                }
            }
            if t > 35.6, t < 39.5 {
                color = Palette.violet; symbol = "arrow.clockwise"
                flash = max(flash, 1 - prog(t, Self.flickOut, Self.flickOut + 0.5)) * (t >= Self.flickOut ? 1 : 0)
            }
            if t >= 39.5, t < 43.0 {
                color = Palette.amber; symbol = "arrow.up.and.down"
                let turning = window(t, Self.scrollStart - 0.2, Self.scrollEnd + 0.2, fadeIn: 0.3, fadeOut: 0.4)
                s.watch.crownGlow.opacity = CGFloat(turning)
                s.watch.crown.eulerAngles.x = CGFloat(keyed([(Self.scrollStart, 0), (Self.scrollEnd, 9.5)], t))
            }
            if t >= 43.0 {
                color = Palette.violet; symbol = t >= Self.grab && t < Self.drop ? "hand.draw.fill" : "arrow.counterclockwise"
                for moment in [Self.grab, Self.drop] where t >= moment {
                    flash = max(flash, 1 - prog(t, moment, moment + 0.5))
                    for i in 0..<2 { s.watch.setRipple(i, progress: prog(t, moment + Double(i) * 0.12, moment + 0.6 + Double(i) * 0.12), color: Palette.violet) }
                }
            }
            if t >= Self.flickOut, t < Self.flickOut + 0.8 {
                for i in 0..<2 { s.watch.setRipple(i, progress: prog(t, Self.flickOut + Double(i) * 0.12, Self.flickOut + 0.6 + Double(i) * 0.12), color: Palette.violet) }
            }
            s.watch.display.emission.contents = WatchScreen.glyph(symbol: symbol, color: color, flash: flash, time: t)

            // A stream of light from the wrist to wherever the pointer is.
            let target = screenPoint(MacScreen.demoToScreen(state.cursor))
            let origin = home + s.watch.root.simdOrientation.act(V3(0.42, 0, 0.05))
            let tone = color == Palette.violet ? 1 : (color == Palette.amber ? 4 : 0)
            for k in 0..<30 {
                let u = (Double(k) / 30 + t * 0.55).truncatingRemainder(dividingBy: 1)
                let p = mix(origin, target, u) + V3(0, Float(sin(u * .pi)) * 0.10, 0)
                s.spark(at: p, size: Float(0.30 + 0.25 * sin(u * .pi)), tone: tone, alpha: 0.55 * sin(u * .pi))
            }

        // --- What is inside ---
        case ..<53.0:
            s.mac.root.isHidden = true
            s.watch.root.isHidden = false
            setLights(key: 0.9, rim: 0.6, target: V3(0, 1.1, 0))
            setPool(at: .zero, intensity: 0.26, size: 0.75)
            s.watch.root.simdPosition = V3(0, 1.12 + Float(breathe), 0)
            s.watch.root.simdScale = V3(repeating: 2.3)
            s.watch.root.simdOrientation = heroOrientation(yaw: keyed([(46.5, -1.05), (53.0, -0.38)], t), tilt: 0.14, roll: 0.03)
            s.aim(s.cameraNode, from: keyed([(46.5, V3(0.2, 1.2, 4.4)), (53.0, V3(-0.15, 1.28, 4.0))], t), at: V3(0, 1.08, 0))
            s.watch.display.emission.contents = WatchScreen.draw(.ready(appear: 1), time: t)
            s.watch.sensorGlow.emission.intensity = CGFloat(0.6 + 0.6 * sin(t * 6))
            s.watch.crownGlow.opacity = CGFloat(0.8 * window(t, 48.0, 49.6, fadeIn: 0.3, fadeOut: 0.5))

        // --- The Dojo ---
        case ..<59.0:
            s.mac.root.isHidden = false
            s.mac.setOpen(1)
            s.mac.keyboardGlow.emission.intensity = 0.55
            setLights(key: 0.85, rim: 0.34, target: V3(0.3, 0.9, 0))
            setPool(at: V3(0.2, 0, 0.3), intensity: 0.2, size: 1.2)
            let zoom = prog(t, 53.0, 59.0)
            setMacScreen(key: nil) { MacScreen.app(self.dojo, zoom: CGFloat(1 + 0.07 * zoom), focus: CGPoint(x: 0.5, y: 0.4)) }
            s.aim(s.cameraNode, from: keyed([(53.0, V3(-1.0, 1.55, 4.9)), (59.0, V3(-0.15, 1.36, 3.5))], t), at: V3(0.1, 1.1, -1.0))
            let swing = 0.22 * sin((t - 53) * 1.5), lift = 0.66 + 0.07 * sin((t - 53) * 3.0)
            s.watch.root.isHidden = false
            s.watch.root.simdPosition = inFrame(V3(0.93, -0.41 + Float(breathe), -2.25))
            s.watch.root.simdScale = V3(repeating: 1.1)
            s.watch.root.simdOrientation = wornOrientation(heading: swing, elevation: lift, roll: 0)
            s.watch.display.emission.contents = WatchScreen.glyph(symbol: "scope", color: Palette.cyan, flash: 0, time: t)

        // --- Finale ---
        default:
            s.mac.root.isHidden = false
            s.mac.setOpen(1)
            s.mac.keyboardGlow.emission.intensity = 0.55
            let focus = V3(0.55, 0.85, 0)
            setLights(key: 1, rim: 0.5, target: focus)
            setPool(at: V3(0.6, 0, 0.3), intensity: 0.26, size: 1.45)
            setMacScreen(key: "pointing") { MacScreen.app(self.appPointing) }
            s.aim(s.cameraNode, from: keyed([(59.0, V3(-1.3, 1.4, 6.5)), (66.0, V3(0.5, 1.6, 7.7))], t), at: V3(0.55, 2.05, 0))
            s.watch.root.isHidden = false
            s.watch.root.simdPosition = V3(2.35, 1.0 + Float(breathe), 1.15)
            s.watch.root.simdScale = V3(repeating: 1.5)
            s.watch.root.simdOrientation = heroOrientation(yaw: -0.5 + 0.08 * sin(t * 0.6), tilt: 0.1, roll: 0.04)
            s.watch.display.emission.contents = WatchScreen.draw(
                .mode(label: "POINTING", symbol: "cursorarrow.rays", color: Palette.cyan, flash: 0), time: t)
            let sweepT = prog(t, 59.6, 63.0)
            s.sweep.light?.intensity = CGFloat(380 * bump(t, 59.6, 63.0))
            s.aim(s.sweep, from: V3(Float(mix(-6, 6, sweepT)), 2.6, 4.5), at: focus)
        }
    }

    // MARK: - Overlay

    /// 0...1 of black laid over the frame: fades in, out, and dips at every cut.
    private func blackout(_ t: Double) -> Double {
        var a = 1 - ease(prog(t, 0, 0.6))
        a = max(a, ease(prog(t, Self.duration - 1.1, Self.duration - 0.15)))
        for cut in Self.cuts { a = max(a, 1 - ease(min(1, abs(t - cut) / 0.36))) }
        return a
    }

    func overlay(_ ctx: CGContext, t: Double, width: CGFloat, height: CGFloat) {
        let scale = width / 1920

        // Callouts sit under the fade so they cut with the picture.
        if t > 46.5, t < 53.0 { callouts(ctx, t: t, width: width, height: height, scale: scale) }

        let black = blackout(t)
        if black > 0.001 {
            ctx.setFillColor(NSColor(white: 0, alpha: black).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }

        func line(_ text: String, size: CGFloat, weight: NSFont.Weight, y: CGFloat, start: Double, end: Double,
                  color: NSColor = .white, x: CGFloat = 960, align: TextAlign = .center, tracking: CGFloat = 0, rounded: Bool = false) {
            let a = window(t, start, end, fadeIn: 0.6, fadeOut: 0.45)
            guard a > 0.004 else { return }
            let rise = (1 - easeOut(prog(t, start, start + 0.8))) * 26
            drawText(text, at: CGPoint(x: x * scale, y: (y + rise) * scale), font: font(size * scale, weight, rounded: rounded),
                     color: color.withAlphaComponent(color.alphaComponent * a), align: align, tracking: tracking * scale,
                     shadow: NSColor(white: 0, alpha: 0.75 * a), shadowBlur: 22 * scale)
        }

        /// A keyword with a coloured full stop and a supporting sentence, bottom-left.
        func beat(_ word: String, _ sentence: String, accent: NSColor, start: Double, end: Double) {
            let a = window(t, start, end, fadeIn: 0.45, fadeOut: 0.35)
            guard a > 0.004 else { return }
            radialGlow(ctx, center: CGPoint(x: 330 * scale, y: 900 * scale), radius: 820 * scale, color: NSColor(white: 0, alpha: 0.82 * a))
            let rise = (1 - easeOut(prog(t, start, start + 0.7))) * 34
            let big = font(168 * scale, .bold)
            let origin = CGPoint(x: 118 * scale, y: (742 + rise) * scale)
            let size = drawText(word, at: origin, font: big, color: NSColor(white: 1, alpha: a), tracking: -4 * scale,
                                shadow: NSColor(white: 0, alpha: 0.8 * a), shadowBlur: 30 * scale)
            drawText(".", at: CGPoint(x: origin.x + size.width - 2 * scale, y: origin.y), font: big, color: accent.withAlphaComponent(a),
                     shadow: accent.withAlphaComponent(0.7 * a), shadowBlur: 34 * scale)
            let sub = window(t, start + 0.25, end, fadeIn: 0.5, fadeOut: 0.35)
            drawText(sentence, at: CGPoint(x: 126 * scale, y: (742 + 196 + rise * 0.5) * scale), font: font(44 * scale, .medium),
                     color: NSColor(white: 1, alpha: 0.78 * sub), shadow: NSColor(white: 0, alpha: 0.8 * sub), shadowBlur: 20 * scale)
        }

        // Cold open.
        line("TEAM GESTURES PRESENTS", size: 30, weight: .semibold, y: 520, start: 0.8, end: 2.9,
             color: NSColor(white: 1, alpha: 0.62), tracking: 9)
        line("Your hand already knows how to point.", size: 78, weight: .semibold, y: 490, start: 3.0, end: 5.6, tracking: -1.5)

        // The watch.
        line("Gauntlet", size: 150, weight: .bold, y: 770, start: 9.0, end: 11.7, tracking: -4)
        line("Your watch is the mouse.", size: 46, weight: .medium, y: 946, start: 9.5, end: 11.7, color: NSColor(white: 1, alpha: 0.78))

        // The Mac.
        line("Nothing in your hand.", size: 96, weight: .bold, y: 96, start: 15.8, end: 18.7, tracking: -2.5)
        line("No mouse. No trackpad. Just your Mac and your watch.", size: 40, weight: .medium, y: 214, start: 16.2, end: 18.7,
             color: NSColor(white: 1, alpha: 0.75))

        // Pairing.
        line("Pair once.", size: 96, weight: .bold, y: 96, start: 20.0, end: 22.8, tracking: -2.5)
        line("Match the code on both screens.", size: 40, weight: .medium, y: 214, start: 20.4, end: 22.8, color: NSColor(white: 1, alpha: 0.75))
        line("Only your watch gets in.", size: 96, weight: .bold, y: 96, start: 23.4, end: 26.6, tracking: -2.5)
        line("A secure key exchange guards every session.", size: 40, weight: .medium, y: 214, start: 23.8, end: 26.6,
             color: NSColor(white: 1, alpha: 0.75))

        // Gestures.
        beat("Point", "Lift your arm. The pointer follows.", accent: Palette.cyan, start: 27.5, end: 31.3)
        beat("Tap", "Thumb to finger. That's a click.", accent: Palette.cyan, start: 31.7, end: 35.4)
        beat("Flick", "A twist of the wrist. Right-click.", accent: Palette.violet, start: 35.8, end: 39.4)
        beat("Scroll", "Turn the Digital Crown.", accent: Palette.amber, start: 39.8, end: 42.9)
        beat("Grab", "Flick in to pick up. Again to drop.", accent: Palette.violet, start: 43.2, end: 46.2)

        // Inside.
        line("100 Hz motion sensing.", size: 96, weight: .bold, y: 812, start: 47.0, end: 52.6, tracking: -2.5)
        line("Fifty updates a second, straight to your Mac over Bluetooth.", size: 40, weight: .medium, y: 932, start: 47.5, end: 52.6,
             color: NSColor(white: 1, alpha: 0.75))

        // Dojo.
        beat("Train", "A 3D dojo that calibrates to your arm.", accent: Palette.green, start: 53.5, end: 58.6)

        // Finale.
        line("Gauntlet", size: 190, weight: .bold, y: 70, start: 59.9, end: 65.2, tracking: -6)
        line("Your watch is the mouse.", size: 50, weight: .medium, y: 292, start: 60.9, end: 65.2, color: NSColor(white: 1, alpha: 0.8))
        line("TEAM GESTURES", size: 30, weight: .semibold, y: 388, start: 62.0, end: 65.2, color: Palette.cyan, tracking: 10)
    }

    private func callouts(_ ctx: CGContext, t: Double, width: CGFloat, height: CGFloat, scale: CGFloat) {
        let body = studio.watch.body
        let items: [(label: String, detail: String, local: V3, side: CGFloat, y: CGFloat, start: Double)] = [
            ("Gyroscope + accelerometer", "Tracks every turn of your wrist", V3(-0.06, 0.10, 0.05), -1, 250, 47.3),
            ("Digital Crown", "Scrolls with precision", V3(0.24, 0.092, 0), 1, 330, 48.1),
            ("Taptic Engine", "A tap on the wrist for every click", V3(-0.08, -0.14, 0.05), -1, 560, 48.9),
            ("Heart-rate sensor", "Live on your Mac's dashboard", V3(0.06, -0.06, -0.06), 1, 610, 49.7),
        ]
        for item in items {
            let a = window(t, item.start, 52.5, fadeIn: 0.5, fadeOut: 0.4)
            guard a > 0.004, let anchor = studio.project(body.simdConvertPosition(item.local, to: nil), width: width, height: height) else { continue }
            let textX = (item.side < 0 ? 150 : 1770) * scale
            let elbow = CGPoint(x: (item.side < 0 ? 640 : 1280) * scale, y: item.y * scale)
            let grow = easeOut(prog(t, item.start, item.start + 0.7))
            ctx.saveGState()
            ctx.setStrokeColor(NSColor(white: 1, alpha: 0.55 * a).cgColor)
            ctx.setLineWidth(1.6 * scale)
            ctx.move(to: anchor)
            let end = CGPoint(x: anchor.x + (elbow.x - anchor.x) * grow, y: anchor.y + (elbow.y - anchor.y) * grow)
            ctx.addLine(to: end)
            if grow > 0.98 { ctx.addLine(to: CGPoint(x: textX, y: elbow.y)) }
            ctx.strokePath()
            ctx.setFillColor(Palette.cyan.withAlphaComponent(a).cgColor)
            ctx.fillEllipse(in: CGRect(x: anchor.x - 6 * scale, y: anchor.y - 6 * scale, width: 12 * scale, height: 12 * scale))
            ctx.setStrokeColor(Palette.cyan.withAlphaComponent(0.4 * a).cgColor)
            ctx.strokeEllipse(in: CGRect(x: anchor.x - 13 * scale, y: anchor.y - 13 * scale, width: 26 * scale, height: 26 * scale))
            ctx.restoreGState()
            let align: TextAlign = item.side < 0 ? .left : .right
            let textAlpha = a * ease(prog(t, item.start + 0.35, item.start + 0.9))
            drawText(item.label, at: CGPoint(x: textX, y: elbow.y - 62 * scale), font: font(36 * scale, .semibold),
                     color: NSColor(white: 1, alpha: textAlpha), align: align)
            drawText(item.detail, at: CGPoint(x: textX, y: elbow.y + 12 * scale), font: font(25 * scale, .regular),
                     color: NSColor(white: 1, alpha: 0.6 * textAlpha), align: align)
        }
    }
}

extension WatchScreen {
    /// Symbol-only face for the worn pose. It is turned a quarter so it reads upright
    /// from behind the wearer's shoulder, where the camera sits.
    static func glyph(symbol: String, color: NSColor, flash: Double, time: Double) -> CGImage {
        drawImage(width: width, height: height) { ctx in
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let center = CGPoint(x: 200, y: 240)
            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: .pi / 2)
            ctx.translateBy(x: -center.x, y: -center.y)
            let radius: CGFloat = 132
            radialGlow(ctx, center: center, radius: 260, color: color.withAlphaComponent(0.22 + 0.4 * flash))
            ctx.setLineWidth(16)
            ctx.setLineCap(.round)
            ctx.setStrokeColor(color.withAlphaComponent(0.22).cgColor)
            ctx.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            let start = CGFloat(time * 1.8).truncatingRemainder(dividingBy: 2 * .pi)
            ctx.setStrokeColor(color.cgColor)
            ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: start + 4.2, clockwise: false)
            ctx.strokePath()
            if flash > 0.01 {
                ctx.setFillColor(color.withAlphaComponent(0.7 * flash).cgColor)
                ctx.fillEllipse(in: CGRect(x: center.x - radius + 18, y: center.y - radius + 18, width: radius * 2 - 36, height: radius * 2 - 36))
            }
            drawSymbol(symbol, center: center, pointSize: 96, color: flash > 0.55 ? .black : .white, in: ctx)
        }
    }
}
