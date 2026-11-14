import AppKit
import SceneKit
import simd
import GauntletEngine

/// The 3D world of the Dojo and its per-frame update.
///
/// The render thread owns the scene graph: it reads the engine snapshot and the sandbox cursor
/// directly (both are thread-safe) and receives everything else from the main thread through a
/// small locked mailbox.
final class DojoScene: NSObject, SCNSceneRendererDelegate {
    let scene = SCNScene()
    let camera = CameraRig()

    private let engine: WristEngine
    private let sink: SandboxSink
    private let logicalSize: CGSize

    // Main thread -> render thread.
    private struct Mailbox {
        var mode = DojoMode.freePlay
        var ghost: GhostDemo?
        var feedback: [Feedback] = []
        var pinches = 0
        var screenImage: CGImage?
        var viewSize = CGSize(width: 1280, height: 800)
        var insets = CameraRig.Insets()
    }
    private let lock = NSLock()
    private var mailbox = Mailbox()

    // Render-thread state.
    private let avatar = ArmAvatar(style: .solid, rightWrist: false)
    private let avatarRig = SCNNode()
    private let ghost = ArmAvatar(style: .ghost, rightWrist: false)
    private let ghostRig = SCNNode()
    private let ghostTag = SCNNode()
    private let screenNode = SCNNode()
    private let screenMaterial = SCNMaterial()
    private var frameBars: [(edge: ScreenEdges, material: SCNMaterial, glow: Float)] = []
    private let cursor = CursorNode()
    private let beam = BeamNode()
    private let effects = ScreenEffects()

    private var lastTime: TimeInterval = 0
    private var startTime: TimeInterval = 0
    private var pose = simd_float3(0, -1.0, 0)           // heading, elevation, roll (smoothed)
    private var cursorPosition = simd_float3(0, 0, 0)
    private var hand = HandPose.relaxed
    private var beamOpacity: Float = 0
    private var pinchUntil: TimeInterval = 0
    private var mode = DojoMode.freePlay
    private var ghostDemo: GhostDemo?
    private var ghostClock: Float = 0
    private var viewSize = CGSize(width: 1280, height: 800)
    private var insets = CameraRig.Insets()
    private var toneKey = ""

    init(engine: WristEngine, sink: SandboxSink) {
        self.engine = engine
        self.sink = sink
        logicalSize = sink.screenSize
        super.init()
        buildEnvironment()
        buildScreen()
        buildActors()
    }

    // MARK: Main-thread interface

    func setMode(_ mode: DojoMode, ghost: GhostDemo?) {
        lock.lock(); mailbox.mode = mode; mailbox.ghost = ghost; lock.unlock()
    }

    func setScreenImage(_ image: CGImage) {
        lock.lock(); mailbox.screenImage = image; lock.unlock()
    }

    func enqueue(_ feedback: Feedback) {
        lock.lock()
        if mailbox.feedback.count < 64 { mailbox.feedback.append(feedback) }
        lock.unlock()
    }

    /// The hand visibly pinches when a finger tap is recognised.
    func pinch() {
        lock.lock(); mailbox.pinches += 1; lock.unlock()
    }

    func setLayout(viewSize: CGSize, insets: CameraRig.Insets) {
        lock.lock(); mailbox.viewSize = viewSize; mailbox.insets = insets; lock.unlock()
    }

    // MARK: Construction

    private func buildEnvironment() {
        scene.background.contents = ProceduralTextures.sky()
        scene.lightingEnvironment.contents = ProceduralTextures.environment()
        scene.lightingEnvironment.intensity = 1.3
        scene.fogColor = Palette.background
        scene.fogStartDistance = 7
        scene.fogEndDistance = 44
        scene.fogDensityExponent = 1.3

        // Infinite glowing grid, drawn analytically so the lines stay crisp at any distance.
        let floor = SCNFloor()
        floor.reflectivity = 0.16
        floor.reflectionFalloffEnd = 7
        floor.reflectionResolutionScaleFactor = 0.5
        let floorMaterial = SCNMaterial()
        floorMaterial.lightingModel = .constant
        floorMaterial.diffuse.contents = Palette.background.mixed(with: .black, 0.5)
        floorMaterial.setValue(Palette.accent.rgbVector, forKey: "gridColor")
        floorMaterial.shaderModifiers = [.surface: Self.gridShader]
        floor.materials = [floorMaterial]
        scene.rootNode.addChildNode(SCNNode(geometry: floor))

        // Mat under the arm.
        for (radius, alpha) in [(CGFloat(1.25), CGFloat(0.8)), (0.8, 0.35), (2.1, 0.22)] {
            let ring = SCNTube(innerRadius: radius - 0.012, outerRadius: radius, height: 0.004)
            ring.radialSegmentCount = 96
            ring.materials = [lightMaterial(Palette.accent, intensity: alpha)]
            let node = SCNNode(geometry: ring)
            node.position = SCNVector3(0, 0.004, CGFloat(Stage.elbow.z) - 0.4)
            scene.rootNode.addChildNode(node)
        }

        // Distant light pillars give the void some depth.
        var rng = SplitMix64(seed: 0xD0D0)
        for index in 0..<40 {
            let angle = Float(index) / 40 * 2 * .pi + Float.random(in: -0.05...0.05, using: &rng)
            let distance = Float.random(in: 15...34, using: &rng)
            let height = CGFloat.random(in: 2.5...15, using: &rng)
            let pillar = SCNBox(width: 0.09, height: height, length: 0.09, chamferRadius: 0)
            pillar.materials = [lightMaterial(index % 3 == 0 ? Palette.secondary : Palette.accent, intensity: 0.55)]
            let node = SCNNode(geometry: pillar)
            node.simdPosition = simd_float3(sin(angle) * distance, Float(height) / 2, cos(angle) * distance - 3)
            scene.rootNode.addChildNode(node)
        }

        // Dust motes drifting through the light.
        let dust = SCNParticleSystem()
        dust.particleImage = ProceduralTextures.softDot()
        dust.birthRate = 16
        dust.particleLifeSpan = 14
        dust.particleLifeSpanVariation = 4
        dust.emitterShape = SCNBox(width: 11, height: 4.5, length: 9, chamferRadius: 0)
        dust.particleVelocity = 0.04
        dust.particleVelocityVariation = 0.04
        dust.spreadingAngle = 180
        dust.particleSize = 0.022
        dust.particleSizeVariation = 0.014
        dust.particleColor = Palette.accent.alpha(0.5)
        dust.blendMode = .additive
        dust.isLightingEnabled = false
        dust.warmupDuration = 14
        let dustNode = SCNNode()
        dustNode.position = SCNVector3(0, 2.4, -1.2)
        dustNode.addParticleSystem(dust)
        scene.rootNode.addChildNode(dustNode)

        // Lights.
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 260
        ambient.color = Palette.accent.mixed(with: .white, 0.6)
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        let key = SCNLight()
        key.type = .directional
        key.intensity = 900
        key.color = NSColor(white: 1, alpha: 1)
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.eulerAngles = SCNVector3(-1.05, 0.5, 0)
        scene.rootNode.addChildNode(keyNode)

        let screenGlow = SCNLight()
        screenGlow.type = .omni
        screenGlow.intensity = 520
        screenGlow.color = Palette.accent
        screenGlow.attenuationStartDistance = 1
        screenGlow.attenuationEndDistance = 9
        let glowNode = SCNNode()
        glowNode.light = screenGlow
        glowNode.simdPosition = Stage.screenCenter + simd_float3(0, 0, 0.8)
        scene.rootNode.addChildNode(glowNode)

        scene.rootNode.addChildNode(camera.node)
    }

    /// Anti-aliased grid from world position: fine lines every unit, bold every four, a slow travelling pulse.
    private static let gridShader = """
    #pragma arguments
    float3 gridColor;
    #pragma body
    float4 gridWorld = scn_frame.inverseViewTransform * float4(_surface.position, 1.0);
    float2 gridP = gridWorld.xz;
    float2 gridW = fwidth(gridP) + 0.0001;
    float2 fineD = abs(fract(gridP - 0.5) - 0.5);
    float2 fineL = 1.0 - saturate((fineD - 0.006) / gridW);
    float fine = max(fineL.x, fineL.y) * saturate(1.0 - max(gridW.x, gridW.y) * 3.0);
    float2 boldP = gridP * 0.25;
    float2 boldW = fwidth(boldP) + 0.0001;
    float2 boldD = abs(fract(boldP - 0.5) - 0.5);
    float2 boldL = 1.0 - saturate((boldD - 0.004) / boldW);
    float bold = max(boldL.x, boldL.y) * saturate(1.0 - max(boldW.x, boldW.y) * 3.0);
    float gridDistance = length(gridP);
    float gridPulse = 0.75 + 0.25 * sin(gridDistance * 1.3 - scn_frame.time * 1.1);
    float gridFade = exp(-gridDistance * 0.07);
    _surface.emission.rgb = gridColor * (fine * 0.30 + bold * 0.75) * gridFade * gridPulse;
    """

    private func buildScreen() {
        screenNode.simdPosition = Stage.screenCenter
        let width = CGFloat(Stage.screenSize.x), height = CGFloat(Stage.screenSize.y)

        let plane = SCNPlane(width: width, height: height)
        plane.cornerRadius = 0.045
        screenMaterial.lightingModel = .constant
        screenMaterial.diffuse.contents = Palette.background
        screenMaterial.diffuse.magnificationFilter = .linear
        screenMaterial.diffuse.minificationFilter = .linear
        screenMaterial.diffuse.mipFilter = .linear
        plane.materials = [screenMaterial]
        screenNode.addChildNode(SCNNode(geometry: plane))

        // Housing behind the glass.
        let backing = SCNBox(width: width + 0.09, height: height + 0.09, length: 0.04, chamferRadius: 0.02)
        let backingMaterial = SCNMaterial()
        backingMaterial.lightingModel = .physicallyBased
        backingMaterial.diffuse.contents = Palette.panel.mixed(with: .black, 0.3)
        backingMaterial.metalness.contents = 0.8
        backingMaterial.roughness.contents = 0.35
        backing.materials = [backingMaterial]
        let backingNode = SCNNode(geometry: backing)
        backingNode.position.z = -0.026
        screenNode.addChildNode(backingNode)

        // Halo on the air behind the screen.
        let halo = SCNPlane(width: width * 2.1, height: height * 2.3)
        let haloMaterial = lightMaterial(.white, intensity: 0.55)
        haloMaterial.emission.contents = ProceduralTextures.radialGlow(Palette.accent.mixed(with: Palette.secondary, 0.35))
        halo.materials = [haloMaterial]
        let haloNode = SCNNode(geometry: halo)
        haloNode.position.z = -0.12
        screenNode.addChildNode(haloNode)

        // Light-strip bezel; each edge flares when the pointer is pinned against it.
        let t: CGFloat = 0.016
        let bars: [(ScreenEdges, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (.top, 0, height / 2 + t / 2, width + 2 * t, t), (.bottom, 0, -height / 2 - t / 2, width + 2 * t, t),
            (.left, -width / 2 - t / 2, 0, t, height), (.right, width / 2 + t / 2, 0, t, height),
        ]
        for (edge, x, y, w, h) in bars {
            let material = lightMaterial(Palette.accent, intensity: 0.5)
            let bar = SCNBox(width: w, height: h, length: t, chamferRadius: 0)
            bar.materials = [material]
            let node = SCNNode(geometry: bar)
            node.position = SCNVector3(x, y, 0.004)
            screenNode.addChildNode(node)
            frameBars.append((edge, material, 0))
        }

        // Tethers down to the floor so the screen reads as standing in the room.
        for x in [-width / 2 + 0.25, width / 2 - 0.25] {
            let tetherHeight = CGFloat(Stage.screenCenter.y) - height / 2
            let tether = SCNCylinder(radius: 0.006, height: tetherHeight)
            tether.materials = [lightMaterial(Palette.accent, intensity: 0.3)]
            let node = SCNNode(geometry: tether)
            node.position = SCNVector3(x, -height / 2 - tetherHeight / 2, -0.03)
            screenNode.addChildNode(node)
        }

        screenNode.addChildNode(cursor.root)
        screenNode.addChildNode(effects.root)
        scene.rootNode.addChildNode(screenNode)
    }

    private func buildActors() {
        avatarRig.simdScale = simd_float3(repeating: Stage.avatarScale)
        avatarRig.addChildNode(avatar.root)
        scene.rootNode.addChildNode(avatarRig)

        ghostRig.simdScale = simd_float3(repeating: Stage.avatarScale)
        ghostRig.addChildNode(ghost.root)
        ghostRig.isHidden = true
        scene.rootNode.addChildNode(ghostRig)

        let tag = SCNPlane(width: 0.6, height: 0.15)
        let tagMaterial = lightMaterial(.white)
        tagMaterial.emission.contents = ProceduralTextures.tag("DEMO", tone: Palette.secondary)
        tag.materials = [tagMaterial]
        ghostTag.geometry = tag
        ghostTag.constraints = [SCNBillboardConstraint()]
        ghostTag.isHidden = true
        scene.rootNode.addChildNode(ghostTag)

        scene.rootNode.addChildNode(beam.root)
    }

    // MARK: Frame update (render thread)

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        if lastTime == 0 { lastTime = time; startTime = time }
        let dt = Float((time - lastTime).clamped(0, 0.1))
        lastTime = time
        let clock = Float(time - startTime)

        lock.lock()
        let mail = mailbox
        mailbox.feedback.removeAll(keepingCapacity: true)
        mailbox.pinches = 0
        mailbox.screenImage = nil
        lock.unlock()
        mode = mail.mode
        viewSize = mail.viewSize
        insets = mail.insets
        if mail.ghost != ghostDemo { ghostDemo = mail.ghost; ghostClock = 0 }
        if mail.pinches > 0 { pinchUntil = time + 0.2 }
        if let image = mail.screenImage { screenMaterial.diffuse.contents = image }
        for feedback in mail.feedback { effects.spawn(feedback, logicalSize: logicalSize) }

        let snap = engine.snapshot()
        let mood = Self.mood(for: snap)
        let sideSign: Float = snap.rightWrist ? 1 : -1

        // Arm pose. A stalled stream lets the arm sink to rest instead of freezing mid-air.
        let target = snap.streaming
            ? simd_float3(Float(snap.heading), Float(snap.elevation), Float(snap.roll))
            : simd_float3(pose.x, -1.05, 0)
        let k = 1 - exp(-dt / 0.045)
        pose.x += (target.x - pose.x) * k
        pose.y += (target.y - pose.y) * k
        pose.z += Self.shortestAngle(from: pose.z, to: target.z) * k
        avatar.setWearing(rightWrist: snap.rightWrist, crownTowardHand: snap.rightWrist == snap.crownLeft)
        avatarRig.simdPosition = simd_float3(Stage.elbow.x * sideSign, Stage.elbow.y, Stage.elbow.z)
        avatar.setPose(heading: pose.x, elevation: pose.y, roll: pose.z)
        avatar.setMood(mood)

        var wanted: HandPose
        switch mood {
        case .offline, .resting, .paused: wanted = .relaxed
        case .pointing: wanted = .pointing
        case .dragging: wanted = .fist
        case .scrolling: wanted = .open
        }
        if time < pinchUntil { wanted = .pinch }
        hand = hand.mixed(with: wanted, 1 - exp(-dt / 0.07))
        avatar.setHand(hand)

        // Pointer, beam, bezel.
        let sandbox = mode.usesSandbox
        let cursorTarget = Stage.screenLocal(sink.cursor, logicalSize: logicalSize)
        cursorPosition += (cursorTarget - cursorPosition) * (1 - exp(-dt / 0.02))
        cursor.root.simdPosition = cursorPosition
        cursor.root.isHidden = !sandbox
        cursor.animate(time: clock, grabbing: snap.dragging)
        let key = "\(mood)-\(snap.engaged)"
        if key != toneKey {
            toneKey = key
            cursor.setTone(mood.tone, haloVisible: snap.engaged)
            beam.setTone(mood.tone)
        }
        let beamTarget: Float = (sandbox && snap.engaged) ? 0.85 : 0
        beamOpacity += (beamTarget - beamOpacity) * (1 - exp(-dt / 0.12))
        beam.update(from: avatar.fingertip, to: screenNode.simdConvertPosition(cursorPosition, to: nil), opacity: beamOpacity)

        let pinned = sandbox ? sink.pinnedEdges : []
        for index in frameBars.indices {
            let goal: Float = pinned.contains(frameBars[index].edge) ? 1 : 0
            let rate: Float = goal > frameBars[index].glow ? 0.03 : 0.3
            frameBars[index].glow += (goal - frameBars[index].glow) * (1 - exp(-dt / rate))
            guard abs(goal - frameBars[index].glow) > 0.004 else { continue }
            let glow = CGFloat(frameBars[index].glow)
            frameBars[index].material.emission.intensity = 0.5 + 2.2 * glow
            frameBars[index].material.emission.contents = Palette.accent.mixed(with: Palette.warning, glow)
        }

        // Calibration demo: a hologram arm beside the real one shows the motion to make.
        if let demo = ghostDemo {
            ghostClock += dt
            ghostRig.isHidden = false
            ghost.setWearing(rightWrist: snap.rightWrist, crownTowardHand: snap.rightWrist == snap.crownLeft)
            ghostRig.simdPosition = simd_float3(-Stage.elbow.x * sideSign * 0.9, Stage.elbow.y, Stage.elbow.z - 0.25)
            let choreography = demo.pose(at: ghostClock, rightWrist: snap.rightWrist)
            ghost.setPose(heading: choreography.heading, elevation: choreography.elevation, roll: choreography.roll)
            ghost.setHand(HandPose.pointing.mixed(with: .pinch, choreography.pinch))
            ghostTag.isHidden = false
            ghostTag.simdPosition = ghost.fingertip + simd_float3(0, 0.3, 0)
        } else {
            ghostRig.isHidden = true
            ghostTag.isHidden = true
        }

        camera.update(dt: dt, time: clock, viewSize: viewSize, insets: insets, rightWrist: snap.rightWrist,
                      released: snap.streaming && !snap.engaged)
    }

    private static func mood(for snap: WristSnapshot) -> AvatarMood {
        if !snap.streaming { return .offline }
        if snap.paused { return .paused }
        if !snap.engaged { return .resting }
        if snap.dragging { return .dragging }
        if snap.scrollMode { return .scrolling }
        return .pointing
    }

    private static func shortestAngle(from: Float, to: Float) -> Float {
        var delta = (to - from).truncatingRemainder(dividingBy: 2 * .pi)
        if delta > .pi { delta -= 2 * .pi }
        if delta < -.pi { delta += 2 * .pi }
        return delta
    }
}

/// The motion the hologram arm loops through for each calibration step.
extension GhostDemo {
    struct Pose {
        var heading: Float = 0
        var elevation: Float = 0.42
        var roll: Float = 0
        var pinch: Float = 0
    }

    func pose(at t: Float, rightWrist: Bool) -> Pose {
        /// 0 -> 1 -> 0 with holds at both ends.
        func swing(period: Float) -> Float {
            let phase = (t / period).truncatingRemainder(dividingBy: 1)
            let ramp = phase < 0.5 ? phase * 2 : (1 - phase) * 2
            let eased = min(1, max(0, (ramp - 0.15) / 0.7))
            return eased * eased * (3 - 2 * eased)
        }
        var pose = Pose()
        switch self {
        case .hold:
            pose.elevation = 0.42 + 0.008 * sin(t * 1.8)
        case .raise:
            pose.elevation = 0.38 + 0.85 * swing(period: 3.4)
        case .sweepHorizontal:
            pose.heading = 0.36 - 0.72 * swing(period: 4.2)
        case .sweepVertical:
            pose.elevation = 0.68 - 0.5 * swing(period: 4.2)
        case .tap:
            let phase = (t / 0.9).truncatingRemainder(dividingBy: 1)
            pose.pinch = phase < 0.3 ? sin(phase / 0.3 * .pi) : 0
        case .wander:
            pose.heading = 0.26 * sin(t * 1.5)
            pose.elevation = 0.44 + 0.14 * sin(t * 2.3)
        case .flick:
            // Out, pause, in, pause. Outward is thumb-up: negative roll on the left wrist.
            let phase = (t / 2.4).truncatingRemainder(dividingBy: 1)
            let outward: Float = rightWrist ? 1 : -1
            if phase < 0.12 {
                pose.roll = outward * 0.62 * sin(phase / 0.12 * .pi)
            } else if phase > 0.5, phase < 0.62 {
                pose.roll = -outward * 0.62 * sin((phase - 0.5) / 0.12 * .pi)
            }
        }
        return pose
    }
}
