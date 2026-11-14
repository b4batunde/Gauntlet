import AppKit
import SceneKit
import simd

/// Over-the-shoulder orbit camera.
///
/// The framing adapts to the view: it backs away until the virtual screen fits between the HUD
/// panels, and shifts the lens (not the camera) so the picture stays centred in the free area.
final class CameraRig {
    /// HUD-covered margins of the view, in points.
    struct Insets: Equatable {
        var left: CGFloat = 0, right: CGFloat = 0, top: CGFloat = 0, bottom: CGFloat = 0
    }

    let node = SCNNode()
    private let camera = SCNCamera()
    private let lock = NSLock()

    // User input (main thread), guarded by `lock`.
    private var userYaw: Float = 0
    private var userPitch: Float = 0
    private var userZoom: Float = 1

    // Render-thread state.
    private var yaw: Float = 0
    private var pitch: Float = 0
    private var distance = Stage.cameraDistance
    private var side: Float = 1
    private var shift = simd_float2(0, 0)
    private var primed = false

    init() {
        camera.fieldOfView = CGFloat(Stage.fieldOfView)
        camera.zNear = 0.05
        camera.zFar = 160
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.exposureOffset = 0
        camera.bloomIntensity = 0.7
        camera.bloomThreshold = 0.72
        camera.bloomBlurRadius = 14
        camera.vignettingIntensity = 0.3
        camera.vignettingPower = 0.8
        node.camera = camera
    }

    // MARK: User control (main thread)

    func orbit(dx: CGFloat, dy: CGFloat) {
        lock.lock()
        userYaw = (userYaw - Float(dx) * 0.006).clamped(-1.3, 1.3)
        userPitch = (userPitch + Float(dy) * 0.005).clamped(-0.25, 0.9)
        lock.unlock()
    }

    func zoom(by factor: CGFloat) {
        lock.lock()
        userZoom = (userZoom * Float(factor)).clamped(0.55, 2.6)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        userYaw = 0; userPitch = 0; userZoom = 1
        lock.unlock()
    }

    // MARK: Per frame (render thread)

    func update(dt: Float, time: Float, viewSize: CGSize, insets: Insets, rightWrist: Bool, released: Bool) {
        lock.lock()
        let (uYaw, uPitch, uZoom) = (userYaw, userPitch, userZoom)
        lock.unlock()
        guard viewSize.width > 10, viewSize.height > 10 else { return }

        let aspect = Float(viewSize.width / viewSize.height)
        let halfV = tan(Stage.fieldOfView * .pi / 360)
        let halfH = halfV * aspect

        // How far back the camera must be for the screen to fit the free part of the view.
        let freeWidth = Float(max(0.3, (viewSize.width - insets.left - insets.right) / viewSize.width))
        let freeHeight = Float(max(0.3, (viewSize.height - insets.top - insets.bottom) / viewSize.height))
        let forWidth = Stage.screenSize.x / (2 * halfH * freeWidth * 0.93)
        let forHeight = Stage.screenSize.y / (2 * halfV * freeHeight * 0.56)
        let nominal: Float = 5.14                       // screen distance the stage was laid out for
        let fit = max(forWidth, forHeight) / nominal

        let targetSide: Float = rightWrist ? 1 : -1
        let idleYaw = 0.022 * sin(time * 0.23)
        let idlePitch = 0.010 * sin(time * 0.31 + 1.3)
        let wantYaw = targetSide * 0.05 + uYaw + idleYaw
        let wantPitch = 0.105 + uPitch + idlePitch + (released ? 0.06 : 0)
        let wantDistance = Stage.cameraDistance * max(1, fit) * uZoom
        let wantShift = simd_float2(Float((insets.left - insets.right) / viewSize.width),
                                    Float((insets.bottom - insets.top) / viewSize.height))

        if primed {
            let k = 1 - exp(-dt / 0.28)
            yaw += (wantYaw - yaw) * k
            pitch += (wantPitch - pitch) * k
            distance += (wantDistance - distance) * k
            side += (targetSide - side) * k
            shift += (wantShift - shift) * k
        } else {
            (yaw, pitch, distance, side, shift, primed) = (wantYaw, wantPitch, wantDistance, targetSide, wantShift, true)
        }

        let target = Stage.cameraTarget + simd_float3(0.08 * side, 0, 0)
        let offset = simd_float3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * distance
        node.simdPosition = target + offset
        node.simdLook(at: target, up: simd_float3(0, 1, 0), localFront: simd_float3(0, 0, -1))

        // Off-axis projection: slides the whole picture so its centre sits in the free area.
        let near = Float(camera.zNear), far = Float(camera.zFar)
        var projection = matrix_identity_float4x4
        projection.columns.0 = simd_float4(1 / halfH, 0, 0, 0)
        projection.columns.1 = simd_float4(0, 1 / halfV, 0, 0)
        projection.columns.2 = simd_float4(-shift.x, -shift.y, -(far + near) / (far - near), -1)
        projection.columns.3 = simd_float4(0, 0, -2 * far * near / (far - near), 0)
        camera.projectionTransform = SCNMatrix4(projection)
    }
}
