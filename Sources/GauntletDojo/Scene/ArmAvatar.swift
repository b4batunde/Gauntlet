import AppKit
import SceneKit
import simd

/// Finger positions, 0 = straight / out, 1 = fully curled / folded in.
struct HandPose: Equatable {
    var index: Float
    var others: Float
    var thumb: Float

    static let relaxed = HandPose(index: 0.26, others: 0.36, thumb: 0.25)
    static let pointing = HandPose(index: 0.03, others: 0.95, thumb: 0.8)
    static let pinch = HandPose(index: 0.58, others: 0.8, thumb: 1.0)
    static let fist = HandPose(index: 1.0, others: 1.0, thumb: 0.9)
    static let open = HandPose(index: 0.02, others: 0.04, thumb: 0.0)

    func mixed(with other: HandPose, _ t: Float) -> HandPose {
        HandPose(index: index + (other.index - index) * t,
                 others: others + (other.others - others) * t,
                 thumb: thumb + (other.thumb - thumb) * t)
    }
}

/// A forearm, hand and Apple Watch built from primitives, in real-world metres
/// (the owner scales `root`). The elbow sits at the origin and the arm runs along local -Z.
final class ArmAvatar {
    enum Style { case solid, ghost }

    let root = SCNNode()
    private(set) var rightWrist: Bool
    private(set) var crownTowardHand = true

    private let style: Style
    private let poseNode = SCNNode()
    private var fingers: [Finger] = []
    private var thumb: Finger?
    private let indexTip = SCNNode()
    private let watchAnchor = SCNNode()

    private let shell = SCNMaterial()
    private let skin = SCNMaterial()
    private let glow = SCNMaterial()
    private let metal = SCNMaterial()
    private let band = SCNMaterial()
    private let glass = SCNMaterial()
    private let face = SCNMaterial()
    private let crownRing = SCNMaterial()

    private var faces: [AvatarMood: CGImage] = [:]
    private var mood: AvatarMood?

    private struct Finger {
        let knuckle: SCNNode
        let middle: SCNNode
    }

    private enum Size {
        static let forearm: CGFloat = 0.25
        static let elbowRadius: CGFloat = 0.043
        static let wristRadius: CGFloat = 0.0285
        static let squash = SCNVector3(1.12, 0.86, 1)
        static let watchAlong: CGFloat = 0.205

        /// Forearm radius `distance` metres from the elbow.
        static func radius(at distance: CGFloat) -> CGFloat {
            elbowRadius - (elbowRadius - wristRadius) * distance / forearm
        }
    }

    init(style: Style, rightWrist: Bool) {
        self.style = style
        self.rightWrist = rightWrist
        root.addChildNode(poseNode)
        configureMaterials()
        if style == .solid {
            for mood in AvatarMood.allCases { faces[mood] = ProceduralTextures.watchFace(mood) }
        }
        build()
        setHand(.relaxed)
        setMood(.resting)
    }

    // MARK: Driving

    /// Mirrors the hand and moves the crown when the wearing arrangement changes.
    func setWearing(rightWrist: Bool, crownTowardHand: Bool) {
        guard rightWrist != self.rightWrist || crownTowardHand != self.crownTowardHand else { return }
        self.rightWrist = rightWrist
        self.crownTowardHand = crownTowardHand
        build()
    }

    /// - Parameters:
    ///   - heading: yaw, positive = left.
    ///   - elevation: pitch above horizontal.
    ///   - roll: wrist twist, 0 = watch face up, positive = face tipping to the wearer's right.
    func setPose(heading: Float, elevation: Float, roll: Float) {
        poseNode.simdOrientation = simd_quatf(angle: heading, axis: simd_float3(0, 1, 0))
            * simd_quatf(angle: elevation, axis: simd_float3(1, 0, 0))
            * simd_quatf(angle: -roll, axis: simd_float3(0, 0, 1))
    }

    func setHand(_ pose: HandPose) {
        for (number, finger) in fingers.enumerated() {
            let curl = CGFloat(number == 0 ? pose.index : pose.others)
            finger.knuckle.eulerAngles.x = -curl * 1.25
            finger.middle.eulerAngles.x = -curl * 1.5
        }
        if let thumb {
            let side: CGFloat = rightWrist ? -1 : 1
            let fold = CGFloat(pose.thumb)
            thumb.knuckle.eulerAngles = SCNVector3(-0.12 - 0.5 * fold, -side * (0.9 - 0.78 * fold), 0)
            thumb.middle.eulerAngles.x = -0.15 - 0.55 * fold
        }
    }

    func setMood(_ newMood: AvatarMood) {
        guard newMood != mood else { return }
        mood = newMood
        guard style == .solid else { return }
        let tone = newMood.tone
        glow.emission.contents = tone
        shell.setValue(tone.rgbVector, forKey: "rimColor")
        skin.setValue(tone.rgbVector, forKey: "rimColor")
        let strength: CGFloat
        switch newMood {
        case .offline: strength = 0.12
        case .resting, .paused: strength = 0.22
        case .pointing, .dragging, .scrolling: strength = 0.6
        }
        shell.setValue(strength, forKey: "rimStrength")
        skin.setValue(strength * 0.8, forKey: "rimStrength")
        glow.emission.intensity = newMood == .offline ? 0.2 : (newMood == .resting ? 0.5 : 1.15)
        face.diffuse.contents = faces[newMood]
    }

    /// World position of the index fingertip — where the pointing beam starts.
    var fingertip: simd_float3 { indexTip.simdWorldPosition }

    /// World position of the watch.
    var watchPosition: simd_float3 { watchAnchor.simdWorldPosition }

    // MARK: Materials

    private static let rimShader = """
    #pragma arguments
    float3 rimColor;
    float rimStrength;
    #pragma body
    float rimFacing = 1.0 - saturate(dot(normalize(_surface.normal), normalize(_surface.view)));
    _surface.emission.rgb += rimColor * (pow(rimFacing, 2.2) * rimStrength);
    """

    private static let hologramShader = """
    #pragma body
    float holoFacing = 1.0 - saturate(dot(normalize(_surface.normal), normalize(_surface.view)));
    _surface.diffuse.rgb *= 0.22 + 1.9 * pow(holoFacing, 1.6);
    """

    private func configureMaterials() {
        switch style {
        case .solid:
            shell.lightingModel = .physicallyBased
            shell.diffuse.contents = Palette.panel.mixed(with: Palette.accent, 0.14).mixed(with: .white, 0.05)
            shell.metalness.contents = 0.55
            shell.roughness.contents = 0.36
            shell.shaderModifiers = [.surface: Self.rimShader]

            skin.lightingModel = .physicallyBased
            skin.diffuse.contents = Palette.panel.mixed(with: .white, 0.13)
            skin.metalness.contents = 0.25
            skin.roughness.contents = 0.5
            skin.shaderModifiers = [.surface: Self.rimShader]

            glow.lightingModel = .constant
            glow.diffuse.contents = NSColor.black
            glow.emission.contents = Palette.accent

            metal.lightingModel = .physicallyBased
            metal.diffuse.contents = NSColor(white: 0.16, alpha: 1)
            metal.metalness.contents = 1.0
            metal.roughness.contents = 0.24

            band.lightingModel = .physicallyBased
            band.diffuse.contents = Palette.secondary.mixed(with: .black, 0.35)
            band.metalness.contents = 0.0
            band.roughness.contents = 0.7

            glass.lightingModel = .physicallyBased
            glass.diffuse.contents = NSColor.black
            glass.metalness.contents = 0.2
            glass.roughness.contents = 0.08

            face.lightingModel = .constant
            face.diffuse.contents = NSColor.black

            crownRing.lightingModel = .constant
            crownRing.diffuse.contents = NSColor.black
            crownRing.emission.contents = Palette.warning
        case .ghost:
            // One translucent hologram material for everything.
            for material in [shell, skin, glow, metal, band, glass, face, crownRing] {
                material.lightingModel = .constant
                material.diffuse.contents = Palette.secondary.mixed(with: .white, 0.25)
                material.transparency = 0.5
                material.blendMode = .add
                material.writesToDepthBuffer = false
                material.shaderModifiers = [.surface: Self.hologramShader]
            }
        }
    }

    // MARK: Geometry

    private func build() {
        poseNode.childNodes.forEach { $0.removeFromParentNode() }
        fingers = []
        let side: CGFloat = rightWrist ? -1 : 1          // which way the thumb points (+X for a left hand)

        poseNode.addChildNode(makeForearm())
        poseNode.addChildNode(makeWatch(side: side))
        poseNode.addChildNode(makeHand(side: side))
        if let current = mood { mood = nil; setMood(current) }
    }

    private func node(_ geometry: SCNGeometry, _ material: SCNMaterial) -> SCNNode {
        geometry.materials = [material]
        return SCNNode(geometry: geometry)
    }

    /// A node whose geometry axis (SceneKit's +Y) is turned to run along the arm (-Z).
    private func alongArm(_ geometry: SCNGeometry, _ material: SCNMaterial) -> SCNNode {
        let result = node(geometry, material)
        result.eulerAngles.x = -.pi / 2
        return result
    }

    private func makeForearm() -> SCNNode {
        let forearm = SCNNode()
        forearm.scale = Size.squash

        let cone = SCNCone(topRadius: Size.wristRadius, bottomRadius: Size.elbowRadius, height: Size.forearm)
        cone.radialSegmentCount = 40
        let sleeve = alongArm(cone, shell)
        sleeve.position.z = -Size.forearm / 2
        forearm.addChildNode(sleeve)

        let elbow = SCNSphere(radius: Size.elbowRadius)
        elbow.segmentCount = 32
        forearm.addChildNode(node(elbow, shell))

        // Glowing seams: the "armour" lines of the gauntlet.
        for distance in [CGFloat(0.05), 0.10, 0.165] {
            let radius = Size.radius(at: distance)
            let seam = SCNTube(innerRadius: radius - 0.001, outerRadius: radius + 0.0012, height: 0.0035)
            seam.radialSegmentCount = 40
            let seamNode = alongArm(seam, glow)
            seamNode.position.z = -distance
            forearm.addChildNode(seamNode)
        }

        // Watch band hugging the wrist.
        let radius = Size.radius(at: Size.watchAlong)
        let strap = SCNTube(innerRadius: radius - 0.001, outerRadius: radius + 0.0028, height: 0.03)
        strap.radialSegmentCount = 40
        let strapNode = alongArm(strap, band)
        strapNode.position.z = -Size.watchAlong
        forearm.addChildNode(strapNode)
        return forearm
    }

    private func roundedSlab(width: CGFloat, length: CGFloat, corner: CGFloat, thickness: CGFloat, chamfer: CGFloat) -> SCNShape {
        let path = NSBezierPath(roundedRect: CGRect(x: -width / 2, y: -length / 2, width: width, height: length),
                                xRadius: corner, yRadius: corner)
        path.flatness = 0.0002          // these shapes are centimetres across
        let shape = SCNShape(path: path, extrusionDepth: thickness)
        shape.chamferRadius = chamfer
        shape.chamferMode = .both
        return shape
    }

    private func makeWatch(side: CGFloat) -> SCNNode {
        let watch = SCNNode()
        let top = Size.radius(at: Size.watchAlong) * CGFloat(Size.squash.y)
        watch.position = SCNVector3(0, top - 0.0008, -Size.watchAlong)
        watch.scale = SCNVector3(1.3, 1.3, 1.3)
        watchAnchor.position = SCNVector3(0, 0.012, 0)
        watch.addChildNode(watchAnchor)

        // Device X (toward the crown) runs along the arm; device Y runs across the wrist.
        let across: CGFloat = 0.046, along: CGFloat = 0.039, thickness: CGFloat = 0.0112
        let body = node(roundedSlab(width: across, length: along, corner: 0.0115, thickness: thickness, chamfer: 0.003), metal)
        body.eulerAngles.x = -.pi / 2                   // lay the slab flat on the wrist
        body.position.y = thickness / 2
        watch.addChildNode(body)

        let cover = node(roundedSlab(width: across - 0.004, length: along - 0.004, corner: 0.0098, thickness: 0.0008, chamfer: 0), glass)
        cover.eulerAngles.x = -.pi / 2
        cover.position.y = thickness + 0.0002
        watch.addChildNode(cover)

        // The lit part of the display. Its "up" points away from the body: across the wrist, to the outside.
        let screen = SCNPlane(width: along - 0.0085, height: across - 0.0085)
        screen.cornerRadius = 0.0075
        let screenNode = node(screen, face)
        screenNode.eulerAngles.x = -.pi / 2
        let turn = SCNNode()
        turn.eulerAngles.y = side * .pi / 2
        turn.position.y = thickness + 0.0008
        turn.addChildNode(screenNode)
        watch.addChildNode(turn)

        // Digital Crown and side button, on the face that looks toward the hand (or elbow).
        let facing: CGFloat = crownTowardHand ? -1 : 1
        let crown = alongArm(SCNCylinder(radius: 0.0052, height: 0.0042), metal)
        crown.position = SCNVector3(-side * 0.0095, thickness * 0.52, facing * (along / 2 + 0.0019))
        watch.addChildNode(crown)
        let ring = alongArm(SCNCylinder(radius: 0.0054, height: 0.0011), crownRing)
        ring.position = SCNVector3(-side * 0.0095, thickness * 0.52, facing * (along / 2 + 0.0034))
        watch.addChildNode(ring)
        let button = node(SCNBox(width: 0.012, height: 0.0036, length: 0.0016, chamferRadius: 0.0007), metal)
        button.position = SCNVector3(side * 0.0085, thickness * 0.5, facing * (along / 2 + 0.0006))
        watch.addChildNode(button)
        return watch
    }

    private func makeHand(side: CGFloat) -> SCNNode {
        let hand = SCNNode()
        hand.position.z = -Size.forearm

        let wrist = alongArm(SCNCapsule(capRadius: 0.024, height: 0.075), skin)
        wrist.scale = SCNVector3(1.18, 1, 0.72)          // scaled before the turn: Z here is the hand's thickness
        wrist.position.z = -0.012
        hand.addChildNode(wrist)

        let palmShape = SCNBox(width: 0.086, height: 0.027, length: 0.094, chamferRadius: 0.0125)
        palmShape.chamferSegmentCount = 8
        let palm = node(palmShape, skin)
        palm.position.z = -0.062
        hand.addChildNode(palm)

        // Emblem on the back of the hand.
        let emblem = node(SCNCylinder(radius: 0.0105, height: 0.0012), glow)
        emblem.position = SCNVector3(0, 0.0138, -0.058)
        hand.addChildNode(emblem)
        let stripe = node(SCNBox(width: 0.0028, height: 0.0012, length: 0.034, chamferRadius: 0.0005), glow)
        stripe.position = SCNVector3(0, 0.0138, -0.088)
        hand.addChildNode(stripe)

        // Index first, then middle, ring, little.
        let specs: [(offset: CGFloat, length: CGFloat, radius: CGFloat)] = [
            (0.031, 0.074, 0.0092), (0.0105, 0.082, 0.0095), (-0.0105, 0.075, 0.009), (-0.031, 0.058, 0.008),
        ]
        for (number, spec) in specs.enumerated() {
            let (finger, tip) = makeFinger(length: spec.length, radius: spec.radius)
            finger.knuckle.position = SCNVector3(side * spec.offset, 0.001, -0.107)
            hand.addChildNode(finger.knuckle)
            fingers.append(finger)
            if number == 0 {
                indexTip.removeFromParentNode()
                indexTip.position = SCNVector3Zero
                tip.addChildNode(indexTip)
                let spark = SCNSphere(radius: 0.0062)
                spark.segmentCount = 16
                tip.addChildNode(node(spark, glow))
            }
        }

        let (thumbFinger, _) = makeFinger(length: 0.066, radius: 0.0105)
        thumbFinger.knuckle.position = SCNVector3(side * 0.04, -0.004, -0.032)
        hand.addChildNode(thumbFinger.knuckle)
        thumb = thumbFinger
        return hand
    }

    /// Two capsule segments hinged at the knuckle and the middle joint.
    private func makeFinger(length: CGFloat, radius: CGFloat) -> (Finger, tip: SCNNode) {
        let first = length * 0.55, second = length * 0.45
        let knuckle = SCNNode()
        let lower = alongArm(SCNCapsule(capRadius: radius, height: first + radius * 2), skin)
        lower.position.z = -first / 2
        knuckle.addChildNode(lower)

        let middle = SCNNode()
        middle.position.z = -first
        knuckle.addChildNode(middle)
        let upper = alongArm(SCNCapsule(capRadius: radius * 0.94, height: second + radius * 2), skin)
        upper.position.z = -second / 2
        middle.addChildNode(upper)

        let tip = SCNNode()
        tip.position.z = -second
        middle.addChildNode(tip)
        return (Finger(knuckle: knuckle, middle: middle), tip)
    }
}
