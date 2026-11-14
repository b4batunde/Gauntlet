import AppKit
import SceneKit
import simd

// Everything is modelled in code: no asset files. Units are decimetres (a MacBook is ~3 wide).

// MARK: - Materials

enum Mat {
    static func metal(_ color: NSColor, roughness: CGFloat = 0.32) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.metalness.contents = 1.0
        m.roughness.contents = roughness
        return m
    }

    static func glass() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = NSColor(white: 0.012, alpha: 1)
        m.metalness.contents = 0.0
        m.roughness.contents = 0.06
        m.clearCoat.contents = 1.0
        m.clearCoatRoughness.contents = 0.03
        return m
    }

    static func rubber(_ color: NSColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.metalness.contents = 0.0
        m.roughness.contents = 0.62
        return m
    }

    /// A self-lit display that still picks up glossy reflections like real cover glass.
    static func display() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = NSColor.black
        m.metalness.contents = 0.0
        m.roughness.contents = 0.08
        m.emission.contents = NSColor.black
        m.emission.intensity = 1.0
        return m
    }

    static func glow(_ color: NSColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSColor.black
        m.emission.contents = color
        m.blendMode = .add
        m.writesToDepthBuffer = false
        return m
    }
}

func roundedRect(_ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
    let path = NSBezierPath(roundedRect: NSRect(x: -w / 2, y: -h / 2, width: w, height: h), xRadius: r, yRadius: r)
    path.flatness = 0.0015
    return path
}

// MARK: - Watch

/// Local frame: +Z out of the display, +Y toward 12 o'clock, +X toward the Digital Crown.
final class WatchModel {
    let root = SCNNode()
    /// Child that gestures rotate, so the placement of `root` stays readable.
    let body = SCNNode()
    let crown = SCNNode()
    let crownGlow = SCNNode()
    let display = Mat.display()
    let band: SCNMaterial
    private(set) var ripples: [SCNNode] = []
    let sensorGlow = Mat.glow(Palette.green)

    static let width: CGFloat = 0.42
    static let height: CGFloat = 0.50
    static let depth: CGFloat = 0.105

    init() {
        root.addChildNode(body)
        let aluminium = Mat.metal(rgb(0xD6D8DC), roughness: 0.28)
        band = Mat.rubber(rgb(0x10182A))

        // Case: a squircle slab with softened edges.
        let caseShape = SCNShape(path: roundedRect(Self.width, Self.height, 0.118), extrusionDepth: 0.072)
        caseShape.chamferRadius = 0.026
        caseShape.chamferMode = .both
        caseShape.materials = [aluminium]
        let caseNode = SCNNode(geometry: caseShape)
        caseNode.position.z = -0.012
        body.addChildNode(caseNode)

        // Cover glass, curving down into the case.
        let glassShape = SCNShape(path: roundedRect(Self.width - 0.012, Self.height - 0.012, 0.114), extrusionDepth: 0.034)
        glassShape.chamferRadius = 0.017
        glassShape.chamferMode = .front
        glassShape.materials = [Mat.glass()]
        let glassNode = SCNNode(geometry: glassShape)
        glassNode.position.z = 0.036
        body.addChildNode(glassNode)

        // The lit panel under the glass.
        let panel = SCNPlane(width: Self.width - 0.062, height: Self.height - 0.062)
        panel.cornerRadius = 0.092
        panel.cornerSegmentCount = 24
        panel.materials = [display]
        let panelNode = SCNNode(geometry: panel)
        panelNode.position.z = 0.0536
        body.addChildNode(panelNode)

        // Back crystal with the optical heart sensor.
        let crystal = SCNCylinder(radius: 0.145, height: 0.012)
        crystal.radialSegmentCount = 64
        crystal.materials = [Mat.glass()]
        let crystalNode = SCNNode(geometry: crystal)
        crystalNode.eulerAngles.x = .pi / 2
        crystalNode.position.z = -0.052
        body.addChildNode(crystalNode)
        for i in 0..<4 {
            let led = SCNNode(geometry: SCNCylinder(radius: 0.016, height: 0.002))
            led.geometry?.materials = [sensorGlow]
            led.eulerAngles.x = .pi / 2
            let a = Double(i) * .pi / 2 + .pi / 4
            led.position = SCNVector3(cos(a) * 0.062, sin(a) * 0.062, -0.0592)
            body.addChildNode(led)
        }

        // Digital Crown: knurled side so its rotation reads on camera.
        let crownShape = SCNCylinder(radius: 0.052, height: 0.036)
        crownShape.radialSegmentCount = 72
        let knurl = Mat.metal(rgb(0xC9CCD2), roughness: 0.3)
        knurl.diffuse.contents = WatchModel.knurlTexture()
        knurl.diffuse.wrapS = .repeat
        let cap = Mat.rubber(rgb(0x14161A))            // matte, so it never flares into the lens
        crownShape.materials = [knurl, cap, cap]
        let crownMesh = SCNNode(geometry: crownShape)
        crownMesh.eulerAngles.z = -.pi / 2           // cylinder axis along +X
        crown.addChildNode(crownMesh)
        crown.position = SCNVector3(Self.width / 2 + 0.014, 0.092, -0.004)
        body.addChildNode(crown)

        let ring = SCNTorus(ringRadius: 0.058, pipeRadius: 0.006)
        ring.ringSegmentCount = 72
        ring.materials = [Mat.glow(Palette.amber)]
        crownGlow.geometry = ring
        crownGlow.eulerAngles.z = -.pi / 2
        crownGlow.position = SCNVector3(Self.width / 2 + 0.014, 0.092, -0.004)
        crownGlow.opacity = 0
        body.addChildNode(crownGlow)

        let button = SCNBox(width: 0.02, height: 0.112, length: 0.034, chamferRadius: 0.009)
        button.materials = [aluminium]
        let buttonNode = SCNNode(geometry: button)
        buttonNode.position = SCNVector3(Self.width / 2 + 0.001, -0.098, -0.004)
        body.addChildNode(buttonNode)

        buildBand()

        // Expanding rings that mark a finger tap.
        for _ in 0..<3 {
            let torus = SCNTorus(ringRadius: 0.2, pipeRadius: 0.0045)
            torus.ringSegmentCount = 96
            torus.materials = [Mat.glow(Palette.cyan)]
            let node = SCNNode(geometry: torus)
            node.eulerAngles.x = .pi / 2
            node.position.z = 0.06
            node.opacity = 0
            body.addChildNode(node)
            ripples.append(node)
        }
    }

    /// A closed sport-band loop behind the case, as if on an unseen wrist: one swept mesh,
    /// so the surface is smooth rather than faceted.
    private func buildBand() {
        let rz: Float = 0.30, ry: Float = 0.345
        let centerZ: Float = -0.045 - rz
        let steps = 160
        let gap: Float = 0.62                           // radians hidden behind the case
        let halfWidth: Float = 0.168, edge: Float = 0.014, halfThickness: Float = 0.013
        // Cross-section, walked around: (x, offset along the loop normal, normal blend toward +-X).
        let profile: [(x: Float, t: Float, side: Float)] = [
            (-halfWidth + edge, halfThickness, 0), (halfWidth - edge, halfThickness, 0), (halfWidth, 0, 1),
            (halfWidth - edge, -halfThickness, 0), (-halfWidth + edge, -halfThickness, 0), (-halfWidth, 0, -1),
        ]
        var vertices: [SCNVector3] = [], normals: [SCNVector3] = [], indices: [Int32] = []
        for i in 0...steps {
            let a = gap + (2 * Float.pi - 2 * gap) * Float(i) / Float(steps)
            let center = SIMD2(ry * sin(a), centerZ + rz * cos(a))
            let outward = simd_normalize(SIMD2(sin(a) / ry, cos(a) / rz))
            for point in profile {
                vertices.append(SCNVector3(point.x, center.x + outward.x * point.t, center.y + outward.y * point.t))
                let facing: Float = point.t > 0 ? 1 : (point.t < 0 ? -1 : 0)
                normals.append(SCNVector3(point.side, outward.x * facing, outward.y * facing))
            }
        }
        let ring = Int32(profile.count)
        for i in 0..<Int32(steps) {
            for k in 0..<ring {
                let a = i * ring + k, b = i * ring + (k + 1) % ring
                let c = (i + 1) * ring + (k + 1) % ring, d = (i + 1) * ring + k
                indices += [a, b, c, a, c, d]
            }
        }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
                                   elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        band.isDoubleSided = true
        geometry.materials = [band]
        body.addChildNode(SCNNode(geometry: geometry))
    }

    private static func knurlTexture() -> CGImage {
        drawImage(width: 512, height: 16) { ctx in
            ctx.setFillColor(rgb(0xC9CCD2).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: 512, height: 16))
            ctx.setFillColor(rgb(0x6E7178).cgColor)
            for i in 0..<64 { ctx.fill(CGRect(x: CGFloat(i) * 8, y: 0, width: 3, height: 16)) }
        }
    }

    /// `progress` 0...1 drives ring `index` outward and fades it.
    func setRipple(_ index: Int, progress: Double, color: NSColor = Palette.cyan) {
        guard ripples.indices.contains(index) else { return }
        let node = ripples[index]
        if progress <= 0 || progress >= 1 { node.opacity = 0; return }
        let s = 0.7 + 2.4 * easeOut(progress)
        node.scale = SCNVector3(s, s, s)
        node.opacity = CGFloat((1 - progress) * 0.95)
        node.geometry?.firstMaterial?.emission.contents = color
    }
}

// MARK: - Mac

/// A slim notebook. Origin at the centre of the base's footprint on the floor; the screen faces +Z.
final class MacModel {
    let root = SCNNode()
    let lid = SCNNode()
    let screen = Mat.display()
    let keyboardGlow: SCNMaterial

    static let width: CGFloat = 3.04
    static let depth: CGFloat = 2.12
    static let baseHeight: CGFloat = 0.1
    static let screenWidth: CGFloat = 2.84
    static let screenHeight: CGFloat = 2.84 / 1.6

    init() {
        let aluminium = Mat.metal(rgb(0xC4C7CC), roughness: 0.34)

        let base = SCNBox(width: Self.width, height: Self.baseHeight, length: Self.depth, chamferRadius: 0.045)
        base.chamferSegmentCount = 8
        base.materials = [aluminium]
        let baseNode = SCNNode(geometry: base)
        baseNode.position.y = Self.baseHeight / 2
        root.addChildNode(baseNode)

        // Keyboard deck.
        let keys = SCNPlane(width: 2.66, height: 1.02)
        keys.cornerRadius = 0.03
        keyboardGlow = SCNMaterial()
        keyboardGlow.lightingModel = .physicallyBased
        keyboardGlow.diffuse.contents = MacModel.keyboardTexture(lit: false)
        keyboardGlow.emission.contents = MacModel.keyboardTexture(lit: true)
        keyboardGlow.emission.intensity = 0
        keyboardGlow.roughness.contents = 0.55
        keyboardGlow.metalness.contents = 0.0
        keys.materials = [keyboardGlow]
        let keysNode = SCNNode(geometry: keys)
        keysNode.eulerAngles.x = -.pi / 2
        keysNode.position = SCNVector3(0, Self.baseHeight + 0.0012, -0.36)
        root.addChildNode(keysNode)

        let pad = SCNPlane(width: 1.22, height: 0.74)
        pad.cornerRadius = 0.035
        let padMaterial = Mat.metal(rgb(0xB4B7BC), roughness: 0.26)
        pad.materials = [padMaterial]
        let padNode = SCNNode(geometry: pad)
        padNode.eulerAngles.x = -.pi / 2
        padNode.position = SCNVector3(0, Self.baseHeight + 0.0012, 0.6)
        root.addChildNode(padNode)

        // Lid, hinged along the back edge. Angle 0 = upright; +90 degrees = closed.
        lid.position = SCNVector3(0, Self.baseHeight + 0.012, -Self.depth / 2 + 0.03)
        root.addChildNode(lid)

        let shell = SCNBox(width: Self.width, height: Self.depth, length: 0.044, chamferRadius: 0.02)
        shell.chamferSegmentCount = 6
        shell.materials = [aluminium]
        let shellNode = SCNNode(geometry: shell)
        shellNode.position.y = Self.depth / 2
        lid.addChildNode(shellNode)

        let bezel = SCNPlane(width: Self.width - 0.05, height: Self.depth - 0.05)
        bezel.cornerRadius = 0.05
        // The border around the picture stays black whatever the studio lights are doing.
        let bezelMaterial = SCNMaterial()
        bezelMaterial.lightingModel = .constant
        bezelMaterial.diffuse.contents = NSColor(white: 0.018, alpha: 1)
        bezel.materials = [bezelMaterial]
        let bezelNode = SCNNode(geometry: bezel)
        bezelNode.position = SCNVector3(0, Self.depth / 2, 0.0226)
        lid.addChildNode(bezelNode)

        let panel = SCNPlane(width: Self.screenWidth, height: Self.screenHeight)
        panel.cornerRadius = 0.03
        // Purely self-lit: studio lights must not glare off the picture.
        screen.lightingModel = .constant
        screen.diffuse.contents = NSColor.black
        panel.materials = [screen]
        let panelNode = SCNNode(geometry: panel)
        panelNode.position = SCNVector3(0, Self.depth / 2 + 0.03, 0.0232)
        lid.addChildNode(panelNode)
    }

    /// Centre of the display in the lid's local space.
    static let screenCenterInLid = SCNVector3(0, depth / 2 + 0.03, 0.03)

    /// 0 = closed, 1 = open to a comfortable viewing angle.
    func setOpen(_ amount: Double) {
        let closed = Double.pi / 2, open = -0.30
        lid.eulerAngles.x = CGFloat(closed + (open - closed) * amount)
    }

    private static func keyboardTexture(lit: Bool) -> CGImage {
        drawImage(width: 1330, height: 510) { ctx in
            ctx.setFillColor((lit ? NSColor.black : rgb(0x0B0C0E)).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: 1330, height: 510))
            let rows = 6, columns = 14
            let gap: CGFloat = 9
            let keyW = (1330 - gap * CGFloat(columns + 1)) / CGFloat(columns)
            let keyH = (510 - gap * CGFloat(rows + 1)) / CGFloat(rows)
            for r in 0..<rows {
                var c = 0
                while c < columns {
                    // A wide space bar on the bottom row.
                    let span = (r == rows - 1 && c == 4) ? 5 : 1
                    let rect = CGRect(x: gap + CGFloat(c) * (keyW + gap), y: gap + CGFloat(r) * (keyH + gap),
                                      width: keyW * CGFloat(span) + gap * CGFloat(span - 1), height: keyH)
                    ctx.addPath(roundedPath(rect, 9))
                    if lit {
                        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.55).cgColor)
                        ctx.setLineWidth(1.6)
                        ctx.strokePath()
                    } else {
                        ctx.setFillColor(rgb(0x17181B).cgColor)
                        ctx.fillPath()
                    }
                    c += span
                }
            }
        }
    }
}

// MARK: - Studio

final class Studio {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    let camera = SCNCamera()
    let key = SCNNode()
    let rimCool = SCNNode()
    let rimWarm = SCNNode()
    let sweep = SCNNode()
    let watch = WatchModel()
    let mac = MacModel()
    /// Soft light on the floor beneath the product.
    let pool = SCNMaterial()
    let poolNode = SCNNode()
    /// A pool of small glowing beads the director places each frame (beams, trails, arcs).
    private(set) var sparks: [SCNNode] = []
    let sparkMaterials: [SCNMaterial]

    init() {
        sparkMaterials = [Palette.cyan, Palette.violet, NSColor.white, Palette.green, Palette.amber].map { Mat.glow($0) }
        scene.background.contents = NSColor.black
        scene.lightingEnvironment.contents = Studio.environmentMap()
        scene.lightingEnvironment.intensity = 1.15

        camera.fieldOfView = 34
        camera.projectionDirection = .vertical
        camera.zNear = 0.05
        camera.zFar = 200
        camera.wantsHDR = true
        camera.bloomIntensity = 0.42
        camera.bloomThreshold = 0.92
        camera.bloomBlurRadius = 9
        camera.vignettingIntensity = 0.55
        camera.vignettingPower = 1.3
        camera.wantsDepthOfField = false
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)

        // A dark mirror floor: the classic product-film stage.
        let floor = SCNFloor()
        floor.reflectivity = 0.32
        floor.reflectionFalloffEnd = 3.2
        floor.reflectionResolutionScaleFactor = 1.0
        let floorMaterial = SCNMaterial()
        floorMaterial.lightingModel = .constant          // lights never wash it out; it only mirrors
        floorMaterial.diffuse.contents = NSColor.black
        floor.materials = [floorMaterial]
        scene.rootNode.addChildNode(SCNNode(geometry: floor))

        let poolPlane = SCNPlane(width: 9, height: 9)
        pool.lightingModel = .constant
        pool.diffuse.contents = NSColor.black
        pool.emission.contents = Studio.poolTexture()
        pool.emission.intensity = 0.5
        pool.blendMode = .add
        pool.writesToDepthBuffer = false
        poolPlane.materials = [pool]
        poolNode.geometry = poolPlane
        poolNode.eulerAngles.x = -.pi / 2
        poolNode.position.y = 0.004
        scene.rootNode.addChildNode(poolNode)

        func spot(_ node: SCNNode, color: NSColor, intensity: CGFloat, shadows: Bool) {
            let light = SCNLight()
            light.type = .spot
            light.color = color
            light.intensity = intensity
            light.spotInnerAngle = 30
            light.spotOuterAngle = 75
            light.castsShadow = shadows
            if shadows {
                light.shadowRadius = 10
                light.shadowSampleCount = 24
                light.shadowColor = NSColor(white: 0, alpha: 0.6)
                light.shadowMapSize = CGSize(width: 2048, height: 2048)
            }
            node.light = light
            scene.rootNode.addChildNode(node)
        }
        spot(key, color: NSColor(white: 1, alpha: 1), intensity: 520, shadows: true)
        spot(rimCool, color: Palette.cyan, intensity: 620, shadows: false)
        spot(rimWarm, color: Palette.violet, intensity: 560, shadows: false)
        spot(sweep, color: .white, intensity: 0, shadows: false)

        scene.rootNode.addChildNode(watch.root)
        scene.rootNode.addChildNode(mac.root)

        let bead = SCNSphere(radius: 0.02)
        bead.segmentCount = 12
        for _ in 0..<160 {
            let node = SCNNode(geometry: bead.copy() as? SCNGeometry)
            node.geometry?.materials = [sparkMaterials[0]]
            node.isHidden = true
            scene.rootNode.addChildNode(node)
            sparks.append(node)
        }
    }

    private var sparkCursor = 0
    func resetSparks() {
        for i in 0..<sparkCursor { sparks[i].isHidden = true }
        sparkCursor = 0
    }

    /// Places one glowing bead. `tone` indexes cyan, violet, white, green, amber.
    func spark(at position: V3, size: Float, tone: Int, alpha: Double) {
        guard sparkCursor < sparks.count, alpha > 0.01 else { return }
        let node = sparks[sparkCursor]
        sparkCursor += 1
        node.isHidden = false
        node.simdPosition = position
        node.simdScale = V3(repeating: size)
        node.opacity = CGFloat(min(1, alpha))
        node.geometry?.materials = [sparkMaterials[tone % sparkMaterials.count]]
    }

    func aim(_ node: SCNNode, from position: V3, at target: V3) {
        node.simdPosition = position
        node.simdLook(at: target, up: V3(0, 1, 0), localFront: V3(0, 0, -1))
    }

    /// Screen position (pixels, top-left origin) of a world point for the current camera.
    func project(_ world: V3, width: CGFloat, height: CGFloat) -> CGPoint? {
        let view = simd_inverse(cameraNode.simdWorldTransform)
        let p = view * SIMD4<Float>(world.x, world.y, world.z, 1)
        guard p.z < -0.01 else { return nil }
        let tanHalf = Float(tan(camera.fieldOfView * .pi / 360))
        let aspect = Float(width / height)
        let nx = (p.x / -p.z) / (tanHalf * aspect)
        let ny = (p.y / -p.z) / tanHalf
        return CGPoint(x: CGFloat((nx + 1) / 2) * width, y: CGFloat((1 - ny) / 2) * height)
    }

    private static func poolTexture() -> CGImage {
        drawImage(width: 512, height: 512) { ctx in
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
            radialGlow(ctx, center: CGPoint(x: 256, y: 256), radius: 250, color: NSColor(white: 1, alpha: 0.55))
        }
    }

    /// A drawn studio: soft boxes on black, so metal and glass have something elegant to reflect.
    private static func environmentMap() -> CGImage {
        drawImage(width: 2048, height: 1024) { ctx in
            ctx.setFillColor(NSColor(white: 0.012, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: 2048, height: 1024))
            func softBox(_ rect: CGRect, _ color: NSColor) {
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: 70, color: color.cgColor)
                ctx.setFillColor(color.cgColor)
                ctx.addPath(roundedPath(rect, 40))
                ctx.fillPath()
                ctx.restoreGState()
            }
            softBox(CGRect(x: 760, y: 40, width: 620, height: 170), NSColor(white: 1, alpha: 1))            // overhead
            softBox(CGRect(x: 250, y: 300, width: 90, height: 420), NSColor(white: 1, alpha: 0.95))         // left strip
            softBox(CGRect(x: 1560, y: 280, width: 120, height: 460), Palette.cyan.withAlphaComponent(0.9)) // right strip
            softBox(CGRect(x: 1020, y: 360, width: 60, height: 300), Palette.violet.withAlphaComponent(0.8))
            softBox(CGRect(x: 1900, y: 380, width: 110, height: 260), NSColor(white: 1, alpha: 0.7))
            softBox(CGRect(x: 40, y: 420, width: 80, height: 200), NSColor(white: 1, alpha: 0.5))
        }
    }
}
