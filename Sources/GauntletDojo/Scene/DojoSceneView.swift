import AppKit
import SceneKit
import SwiftUI

/// Mouse input over the 3D view, already sorted into what it means.
protocol DojoInputTarget: AnyObject {
    /// Pointer position, 0...1 on both axes with v growing upward.
    func pointerMoved(u: Double, v: Double)
    func primaryClick(option: Bool)
    func secondaryClick()
    /// Scroll that is meant for the virtual watch's Digital Crown.
    func crownScrolled(deltaY: Double, precise: Bool)
    func cameraOrbit(dx: CGFloat, dy: CGFloat)
    func cameraZoom(by factor: CGFloat)
    func viewResized(to size: CGSize)
    /// True when the mouse is free to drive the camera without a modifier (a real watch is in charge).
    var mouseDrivesCamera: Bool { get }
}

/// `SCNView` that turns mouse events into virtual-watch and camera input.
///
/// With the virtual watch active the plain mouse steers the arm, so the camera needs Command:
/// Command-drag orbits, Command-scroll (or a pinch) zooms.
final class DojoSCNView: SCNView {
    weak var input: DojoInputTarget?
    private var tracking: NSTrackingArea?
    private var orbiting = false

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        input?.viewResized(to: newSize)
    }

    private func report(_ event: NSEvent) {
        guard bounds.width > 1, bounds.height > 1 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let v = isFlipped ? 1 - point.y / bounds.height : point.y / bounds.height
        input?.pointerMoved(u: Double(point.x / bounds.width), v: Double(v))
    }

    private func wantsCamera(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(.command) || (input?.mouseDrivesCamera ?? false)
    }

    override func mouseMoved(with event: NSEvent) { report(event) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if wantsCamera(event) {
            orbiting = true
        } else {
            input?.primaryClick(option: event.modifierFlags.contains(.option))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if orbiting {
            input?.cameraOrbit(dx: event.deltaX, dy: event.deltaY)
        } else {
            report(event)
        }
    }

    override func mouseUp(with event: NSEvent) { orbiting = false }

    override func rightMouseDown(with event: NSEvent) {
        if input?.mouseDrivesCamera ?? false { return }
        input?.secondaryClick()
    }

    override func rightMouseDragged(with event: NSEvent) { report(event) }

    override func otherMouseDown(with event: NSEvent) {
        if input?.mouseDrivesCamera ?? false { return }
        input?.primaryClick(option: true)
    }

    override func scrollWheel(with event: NSEvent) {
        if wantsCamera(event) {
            let amount = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.004 : event.scrollingDeltaY * 0.04
            input?.cameraZoom(by: exp(-amount))
        } else {
            input?.crownScrolled(deltaY: Double(event.scrollingDeltaY), precise: event.hasPreciseScrollingDeltas)
        }
    }

    override func magnify(with event: NSEvent) {
        input?.cameraZoom(by: 1 / max(0.2, 1 + event.magnification))
    }
}

/// Hosts the SceneKit view inside SwiftUI.
struct DojoSceneView: NSViewRepresentable {
    let controller: DojoController

    func makeNSView(context: Context) -> DojoSCNView {
        let view = DojoSCNView(frame: .zero, options: nil)
        view.scene = controller.scene.scene
        view.delegate = controller.scene
        view.pointOfView = controller.scene.camera.node
        view.input = controller
        controller.attach(view: view)
        view.backgroundColor = Palette.background
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 120
        view.rendersContinuously = true
        view.isPlaying = true
        view.allowsCameraControl = false
        return view
    }

    func updateNSView(_ view: DojoSCNView, context: Context) {}

    static func dismantleNSView(_ view: DojoSCNView, coordinator: ()) {
        view.isPlaying = false
        view.delegate = nil
        view.input = nil
    }
}
