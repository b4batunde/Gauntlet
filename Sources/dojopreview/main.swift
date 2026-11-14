// Standalone Dojo window driven by the virtual watch (no Bluetooth, no real cursor).
//
//   swift run dojopreview                                    open the Dojo
//   dojopreview --mode targets --autopilot                   start in a mode and let the autopilot play
//   dojopreview --snapshot out.png [--mode m] [--after s]    autopilot plays for a while, then the whole
//               [--size WxH] [--right-wrist] [--stats]       window is saved as a PNG and the app exits
//               [--hide-help] [--manual]
//   dojopreview --selfcheck                                  headless logic checks; exit code 1 on failure
//   dojopreview --inputcheck                                 synthetic mouse and key events through the real
//                                                            window; exit code 1 if any does not arrive
//
//   modes: freeplay, calibration, targets, drag, scroll, simon, live
import AppKit
import SceneKit
import SwiftUI
import GauntletEngine
import GauntletProtocol
import GauntletDojo

struct Arguments {
    var snapshotPath: String?
    var mode = DojoMode.freePlay
    var after = 4.0
    var size = CGSize(width: 1440, height: 900)
    var autopilot = false
    var manual = false
    var selfCheck = false
    var inputCheck = false
    var showStats = false
    var rightWrist = false
    var hideHelp = false

    static let modeNames: [String: DojoMode] = [
        "freeplay": .freePlay, "calibration": .calibration, "targets": .targets,
        "drag": .drag, "scroll": .scroll, "simon": .simon, "live": .live,
    ]

    init(_ raw: [String]) {
        var iterator = raw.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--selfcheck": selfCheck = true
            case "--inputcheck": inputCheck = true
            case "--autopilot": autopilot = true
            case "--manual": manual = true
            case "--stats": showStats = true
            case "--right-wrist": rightWrist = true
            case "--hide-help": hideHelp = true
            case "--snapshot":
                guard let path = iterator.next() else { Self.fail("--snapshot expects a file path") }
                snapshotPath = path
            case "--mode":
                guard let name = iterator.next(), let parsed = Self.modeNames[name.lowercased()] else {
                    Self.fail("--mode expects one of: " + Self.modeNames.keys.sorted().joined(separator: ", "))
                }
                mode = parsed
            case "--after":
                guard let text = iterator.next(), let seconds = Double(text), seconds > 0 else { Self.fail("--after expects seconds") }
                after = seconds
            case "--size":
                let parts = (iterator.next() ?? "").lowercased().split(separator: "x").compactMap { Double($0) }
                guard parts.count == 2, parts[0] >= 400, parts[1] >= 300 else { Self.fail("--size expects WIDTHxHEIGHT") }
                size = CGSize(width: parts[0], height: parts[1])
            default:
                Self.fail("unknown argument \(argument)")
            }
        }
        // A snapshot shows the Dojo in action unless asked otherwise.
        if snapshotPath != nil, !manual { autopilot = true }
        if inputCheck { autopilot = false }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("dojopreview: \(message)\n".utf8))
        exit(2)
    }
}

/// Forwards to the Dojo's sandbox sink and remembers how much scrolling went through.
final class SpySink: PointerSink, @unchecked Sendable {
    private let wrapped: PointerSink
    private let lock = NSLock()
    private var scrolledBy = 0.0

    init(wrapping sink: PointerSink) { wrapped = sink }

    var scrolled: Double {
        lock.lock(); defer { lock.unlock() }
        return scrolledBy
    }

    func movePointer(dx: Double, dy: Double) { wrapped.movePointer(dx: dx, dy: dy) }
    func button(_ button: MouseButton, isDown: Bool, clickCount: Int) { wrapped.button(button, isDown: isDown, clickCount: clickCount) }
    func shortcut(_ shortcut: SystemShortcut) { wrapped.shortcut(shortcut) }
    func scroll(dx: Double, dy: Double) {
        lock.lock(); scrolledBy += abs(dy); lock.unlock()
        wrapped.scroll(dx: dx, dy: dy)
    }
}

final class PreviewDelegate: NSObject, NSApplicationDelegate {
    private let arguments: Arguments
    private let engine = WristEngine()
    private var window: NSWindow?
    private var spy: SpySink?
    private var observer: ObserverToken?
    private let seen = SeenEvents()

    /// Engine events noted for the input check (they arrive on the virtual watch's thread).
    private final class SeenEvents: @unchecked Sendable {
        private let lock = NSLock()
        private var gestures: [GestureKind] = []
        func note(_ gesture: GestureKind) { lock.lock(); gestures.append(gesture); lock.unlock() }
        func contains(_ gesture: GestureKind) -> Bool { lock.lock(); defer { lock.unlock() }; return gestures.contains(gesture) }
    }

    init(arguments: Arguments) {
        self.arguments = arguments
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Wrist and help-panel choices for this launch only: the argument domain is never written to disk.
        var overrides: [String: Any] = [:]
        if arguments.rightWrist { overrides["dojo.virtualRightWrist"] = true }
        if arguments.hideHelp { overrides["dojo.showHelp"] = false }
        if !overrides.isEmpty {
            var domain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            domain.merge(overrides) { _, new in new }
            UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
        }

        // No real watch here: the Dojo drives the engine with its virtual watch,
        // and "the real cursor" is nothing at all.
        let host = DojoHost(engine: engine)
        host.isRealWatchConnected = { false }
        host.setSandboxSink = { [weak self] sink in
            guard let self else { return }
            let spy = sink.map { SpySink(wrapping: $0) }
            self.spy = spy
            self.engine.sink = spy
        }

        let options = DojoOptions(initialMode: arguments.mode, autopilot: arguments.autopilot, showStats: arguments.showStats)
        let content = NSHostingView(rootView: DojoView(host: host, options: options))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: arguments.size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Gauntlet Dojo"
        window.backgroundColor = NSColor(srgbRed: 0.027, green: 0.043, blue: 0.078, alpha: 1)
        window.contentView = content
        window.setContentSize(arguments.size)
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window

        if let path = arguments.snapshotPath {
            // Shown without taking focus, so a snapshot run does not interrupt typing elsewhere.
            window.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + arguments.after) { [weak self] in
                self?.saveSnapshot(to: path)
            }
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if arguments.inputCheck {
                let seen = self.seen
                observer = engine.addObserver { event in
                    if case .gesture(let kind, _) = event { seen.note(kind) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.runInputCheck() }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { arguments.snapshotPath == nil }

    func applicationWillTerminate(_ notification: Notification) {
        if arguments.snapshotPath != nil {
            FileHandle.standardError.write(Data("dojopreview: terminated before the snapshot was taken\n".utf8))
        }
    }

    // MARK: Snapshot

    private func saveSnapshot(to path: String) {
        guard let window, let data = Self.capture(window) else {
            FileHandle.standardError.write(Data("dojopreview: could not capture the window\n".utf8))
            exit(1)
        }
        do {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            print("wrote \(path)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("dojopreview: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    /// The window as the user sees it. AppKit cannot cache a Metal-backed view, so the 3D scene
    /// comes from SceneKit's own snapshot and the SwiftUI HUD is composited on top of it.
    private static func capture(_ window: NSWindow) -> Data? {
        guard let content = window.contentView else { return nil }
        content.layoutSubtreeIfNeeded()
        let bounds = content.bounds
        let scale = window.backingScaleFactor
        let pixelsWide = Int(bounds.width * scale), pixelsHigh = Int(bounds.height * scale)
        let sceneView = findSceneView(in: content)
        let sceneImage = sceneView?.snapshot()

        func makeBitmap() -> NSBitmapImageRep? {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            rep?.size = bounds.size         // points, so drawing below is in view coordinates
            return rep
        }

        // The HUD alone, on a transparent bitmap.
        sceneView?.isHidden = true
        defer { sceneView?.isHidden = false }
        guard let hud = makeBitmap() else { return nil }
        content.cacheDisplay(in: bounds, to: hud)

        guard let canvas = makeBitmap(), let graphics = NSGraphicsContext(bitmapImageRep: canvas) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        (window.backgroundColor ?? .black).setFill()
        bounds.fill()
        if let sceneView, let sceneImage {
            var frame = sceneView.convert(sceneView.bounds, to: content)
            if content.isFlipped { frame.origin.y = bounds.height - frame.maxY }
            sceneImage.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
        }
        // An image rep's plain draw(in:) copies, which would punch the HUD's transparency through the scene.
        hud.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return canvas.representation(using: .png, properties: [:])
    }

    private static func findSceneView(in view: NSView) -> SCNView? {
        if let found = view as? SCNView { return found }
        for child in view.subviews {
            if let found = findSceneView(in: child) { return found }
        }
        return nil
    }

    // MARK: Input check

    /// Sends synthetic mouse and key events through the application, exactly where real ones
    /// would enter, and watches the engine for the gestures they should cause.
    private func runInputCheck() {
        guard let window, let content = window.contentView, let sceneView = Self.findSceneView(in: content) else {
            print("  FAIL the window has no scene view")
            exit(1)
        }
        let engine = self.engine
        let seen = self.seen
        var failures = 0
        func report(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            print("  \(ok ? "ok  " : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }
        func point(u: CGFloat, v: CGFloat) -> NSPoint {
            sceneView.convert(NSPoint(x: sceneView.bounds.width * u, y: sceneView.bounds.height * (sceneView.isFlipped ? 1 - v : v)), to: nil)
        }
        func mouse(_ type: NSEvent.EventType, u: CGFloat = 0.5, v: CGFloat = 0.45, flags: NSEvent.ModifierFlags = []) {
            guard let event = NSEvent.mouseEvent(with: type, location: point(u: u, v: v), modifierFlags: flags,
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: type == .mouseMoved ? 0 : 1, pressure: 1) else { return }
            NSApp.postEvent(event, atStart: false)
        }
        func key(_ characters: String, code: UInt16) {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                               context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                               isARepeat: false, keyCode: code) else { return }
            NSApp.postEvent(event, atStart: false)
        }
        func scroll(by pixels: Int32) {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0),
                  let screen = window.screen else { return }
            let onScreen = window.convertPoint(toScreen: point(u: 0.5, v: 0.45))
            cg.location = CGPoint(x: onScreen.x, y: screen.frame.maxY - onScreen.y)
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
            if let event = NSEvent(cgEvent: cg) { window.sendEvent(event) }
        }

        print("Input through the window")
        /// Mouse-moved events reach the view through its tracking area, which AppKit feeds from the
        /// real pointer only. So the handler is driven directly — and repeatedly, because a person
        /// using the Mac while this runs is steering the arm too.
        func steer(u: CGFloat) {
            var remaining = 35
            Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { timer in
                remaining -= 1
                if remaining <= 0 { timer.invalidate() }
                if let event = NSEvent.mouseEvent(with: .mouseMoved, location: point(u: u, v: 0.45), modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                  context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                    sceneView.mouseMoved(with: event)
                }
            }
        }
        let steps: [(delay: Double, action: () -> Void)] = [
            (0.0, { steer(u: 0.15) }),
            (0.75, {
                report("moving the mouse left swings the arm left", engine.snapshot().heading > 0.15,
                       String(format: "heading %.2f", engine.snapshot().heading))
                steer(u: 0.85)
            }),
            (0.75, {
                report("moving the mouse right swings the arm right", engine.snapshot().heading < -0.15,
                       String(format: "heading %.2f", engine.snapshot().heading))
                mouse(.leftMouseDown); mouse(.leftMouseUp)
            }),
            (0.6, {
                report("a click on the 3D view is a finger tap", seen.contains(.pinchTap))
                mouse(.rightMouseDown); mouse(.rightMouseUp)
            }),
            (0.7, {
                report("a right-click is a wrist flick out", seen.contains(.flickOut))
                key("f", code: 3)
            }),
            (0.7, {
                report("F is a wrist flick in, which grabs", seen.contains(.flickIn) && engine.snapshot().dragging)
                mouse(.leftMouseDown, flags: .option); mouse(.leftMouseUp, flags: .option)
            }),
            (0.7, {
                report("Option-click flicks in again, which lets go", !engine.snapshot().dragging)
                scroll(by: -60)
            }),
            (0.4, {
                report("the scroll wheel turns the Digital Crown", (self.spy?.scrolled ?? 0) > 10,
                       String(format: "%.0f px", self.spy?.scrolled ?? 0))
                key("p", code: 35)
            }),
            (0.4, {
                report("P pauses", engine.snapshot().paused)
                key("p", code: 35)
            }),
            (0.5, {
                report("P resumes", !engine.snapshot().paused && engine.snapshot().engaged)
                key(" ", code: 49)
            }),
            (0.9, {
                report("Space lowers the arm and releases the pointer", !engine.snapshot().engaged)
                key(" ", code: 49)
            }),
            (0.9, {
                report("Space raises it again", engine.snapshot().engaged)
                print(failures == 0 ? "all input reached the Dojo" : "\(failures) failure\(failures == 1 ? "" : "s")")
                exit(failures == 0 ? 0 : 1)
            }),
        ]
        var next = 0
        func advance() {
            guard next < steps.count else { return }
            let step = steps[next]
            next += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + step.delay) {
                step.action()
                advance()
            }
        }
        advance()
    }
}

let arguments = Arguments(CommandLine.arguments)

if arguments.selfCheck {
    let outcome = DojoSelfCheck.run()
    print(outcome.report)
    exit(outcome.passed ? 0 : 1)
}

let application = NSApplication.shared
let delegate = PreviewDelegate(arguments: arguments)
application.delegate = delegate
application.setActivationPolicy(arguments.snapshotPath == nil ? .regular : .accessory)
application.run()
