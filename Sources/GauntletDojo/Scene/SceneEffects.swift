import AppKit
import SceneKit
import simd

/// Unlit, additive material: the look of everything that is "made of light".
func lightMaterial(_ color: NSColor, intensity: CGFloat = 1) -> SCNMaterial {
    let material = SCNMaterial()
    material.lightingModel = .constant
    material.diffuse.contents = NSColor.black
    material.emission.contents = color
    material.emission.intensity = intensity
    material.blendMode = .add
    material.writesToDepthBuffer = false
    material.isDoubleSided = true
    return material
}

/// The virtual pointer drawn on the 3D screen: a classic arrow with a halo.
final class CursorNode {
    let root = SCNNode()
    private let halo: SCNNode
    private let haloMaterial = lightMaterial(Palette.accent)
    private let outline = SCNMaterial()

    init() {
        // Arrow outline in units of its own height, tip at the origin.
        let outlinePoints: [(CGFloat, CGFloat)] = [(0, 0), (0, -0.80), (0.19, -0.62), (0.32, -0.93), (0.44, -0.88),
                                                   (0.31, -0.58), (0.56, -0.58)]
        let height: CGFloat = 0.12
        let path = NSBezierPath()
        for (number, point) in outlinePoints.enumerated() {
            let p = CGPoint(x: point.0 * height, y: point.1 * height)
            if number == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        path.close()
        path.flatness = 0.0005

        let fill = SCNMaterial()
        fill.lightingModel = .constant
        fill.diffuse.contents = NSColor.white
        let arrow = SCNShape(path: path, extrusionDepth: 0.004)
        arrow.materials = [fill]
        let arrowNode = SCNNode(geometry: arrow)
        arrowNode.position.z = 0.006

        outline.lightingModel = .constant
        outline.diffuse.contents = NSColor.black
        outline.emission.contents = Palette.accent
        let stroked = path.cgPath.copy(strokingWithWidth: 0.014, lineCap: .round, lineJoin: .round, miterLimit: 4)
        let border = NSBezierPath(cgPath: stroked)
        border.flatness = 0.0005
        let rim = SCNShape(path: border, extrusionDepth: 0.002)
        rim.materials = [outline]
        let rimNode = SCNNode(geometry: rim)
        rimNode.position.z = 0.003

        let ring = SCNTube(innerRadius: 0.052, outerRadius: 0.058, height: 0.001)
        ring.radialSegmentCount = 48
        ring.materials = [haloMaterial]
        halo = SCNNode(geometry: ring)
        halo.eulerAngles.x = .pi / 2
        halo.position.z = 0.002

        root.addChildNode(halo)
        root.addChildNode(rimNode)
        root.addChildNode(arrowNode)
    }

    func setTone(_ color: NSColor, haloVisible: Bool) {
        haloMaterial.emission.contents = color
        outline.emission.contents = color
        halo.opacity = haloVisible ? 0.9 : 0.25
    }

    /// Breathing halo; a held button shrinks it around the tip.
    func animate(time: Float, grabbing: Bool) {
        let base: Float = grabbing ? 0.55 : 1.0
        let scale = base + 0.06 * sin(time * 3.2)
        halo.simdScale = simd_float3(scale, 1, scale)
    }
}

/// The beam of light from the fingertip to the pointer.
final class BeamNode {
    let root = SCNNode()
    private let core = lightMaterial(Palette.accent)
    private let sheath = lightMaterial(Palette.accent, intensity: 0.22)

    init() {
        let inner = SCNCylinder(radius: 0.0045, height: 1)
        inner.radialSegmentCount = 8
        inner.materials = [core]
        let outer = SCNCylinder(radius: 0.016, height: 1)
        outer.radialSegmentCount = 12
        outer.materials = [sheath]
        for geometry in [inner, outer] {
            let node = SCNNode(geometry: geometry)
            node.position.y = 0.5               // base at the origin, length along +Y
            root.addChildNode(node)
        }
    }

    func setTone(_ color: NSColor) {
        core.emission.contents = color
        sheath.emission.contents = color
    }

    func update(from start: simd_float3, to end: simd_float3, opacity: Float) {
        let delta = end - start
        let length = simd_length(delta)
        root.isHidden = opacity < 0.02 || length < 0.01
        guard !root.isHidden else { return }
        root.simdPosition = start
        root.simdOrientation = simd_quatf(from: simd_float3(0, 1, 0), to: delta / length)
        root.simdScale = simd_float3(1, length, 1)
        root.opacity = CGFloat(opacity)
    }
}

/// Ripples, particle bursts and confetti on the face of the 3D screen.
final class ScreenEffects {
    /// Child of the screen node; positions are in its local space.
    let root = SCNNode()
    private let dot = ProceduralTextures.softDot()
    private let ringGeometry: SCNTube = {
        let tube = SCNTube(innerRadius: 0.9, outerRadius: 1.0, height: 0.001)
        tube.radialSegmentCount = 48
        return tube
    }()
    private var materials: [Tone: SCNMaterial] = [:]
    private var rng = SplitMix64(seed: 0xFEED)

    func spawn(_ feedback: Feedback, logicalSize: CGSize) {
        switch feedback {
        case .ripple(let point, let tone):
            ripple(at: Stage.screenLocal(point, logicalSize: logicalSize), tone: tone, size: 0.2)
        case .burst(let point, let tone):
            let position = Stage.screenLocal(point, logicalSize: logicalSize)
            ripple(at: position, tone: tone, size: 0.34)
            burst(at: position, color: tone.ns, count: 9, speed: 1.6)
        case .celebrate:
            let tones: [Tone] = [.accent, .success, .secondary, .warning, .accent, .success]
            for (number, tone) in tones.enumerated() {
                let x = Float.random(in: -1.3...1.3, using: &rng), y = Float.random(in: -0.5...0.8, using: &rng)
                let position = simd_float3(x, y, 0)
                root.runAction(.sequence([.wait(duration: 0.14 * Double(number)), .run { [weak self] _ in
                    self?.burst(at: position, color: tone.ns, count: 22, speed: 2.4)
                    self?.ripple(at: position, tone: tone, size: 0.5)
                }]))
            }
        case .haptic:
            break
        }
    }

    private func material(for tone: Tone) -> SCNMaterial {
        if let existing = materials[tone] { return existing }
        let created = lightMaterial(tone.ns)
        materials[tone] = created
        return created
    }

    private func ripple(at position: simd_float3, tone: Tone, size: Float) {
        // Geometry is shared; a copy lets each ring carry its own tone.
        guard let geometry = ringGeometry.copy() as? SCNGeometry else { return }
        geometry.materials = [material(for: tone)]
        let node = SCNNode(geometry: geometry)
        node.eulerAngles.x = .pi / 2
        node.simdPosition = position + simd_float3(0, 0, 0.012)
        node.simdScale = simd_float3(repeating: 0.03)
        root.addChildNode(node)
        let grow = SCNAction.scale(to: CGFloat(size), duration: 0.5)
        grow.timingMode = .easeOut
        let fade = SCNAction.sequence([.wait(duration: 0.12), .fadeOut(duration: 0.38)])
        node.runAction(.sequence([.group([grow, fade]), .removeFromParentNode()]))
    }

    private func burst(at position: simd_float3, color: NSColor, count: CGFloat, speed: CGFloat) {
        let system = SCNParticleSystem()
        system.particleImage = dot
        system.birthRate = count * 8
        system.emissionDuration = 0.12
        system.loops = false
        system.particleLifeSpan = 0.45
        system.particleLifeSpanVariation = 0.2
        system.particleVelocity = speed
        system.particleVelocityVariation = speed * 0.7
        system.emittingDirection = SCNVector3(0, 0, 1)
        system.spreadingAngle = 180
        system.particleSize = 0.018
        system.particleSizeVariation = 0.01
        system.particleColor = color
        system.particleColorVariation = SCNVector4(0.04, 0.1, 0.1, 0)
        system.blendMode = .additive
        system.isLightingEnabled = false
        system.acceleration = SCNVector3(0, -1.6, 0)
        system.dampingFactor = 0.9
        let fade = CABasicAnimation()
        fade.fromValue = 1.0
        fade.toValue = 0.0
        system.propertyControllers = [.opacity: SCNParticlePropertyController(animation: fade)]

        let node = SCNNode()
        node.simdPosition = position + simd_float3(0, 0, 0.03)
        node.addParticleSystem(system)
        root.addChildNode(node)
        node.runAction(.sequence([.wait(duration: 1.4), .removeFromParentNode()]))
    }
}
