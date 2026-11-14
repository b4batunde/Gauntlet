import AppKit
import SceneKit
import SwiftUI
import GauntletEngine
import GauntletDojo

/// In this SDK `@State` resolves to a macro whose compiler plugin ships only with full Xcode.
/// Going through a typealias selects the plain property wrapper, which builds everywhere.
typealias LocalState = SwiftUI.State

enum Page: String, CaseIterable, Identifiable {
    case control, dojo, gestures, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .control: return "Control"
        case .dojo: return "Dojo"
        case .gestures: return "Gestures"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .control: return "dot.scope"
        case .dojo: return "cube.transparent"
        case .gestures: return "hand.tap"
        case .settings: return "slider.horizontal.3"
        }
    }
}

struct RootView: View {
    @ObservedObject var model: AppModel
    @LocalState private var page = RootView.launchPage

    /// `--page dojo` opens straight onto a page (handy for demos and screenshots).
    private static var launchPage: Page {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--page"), args.indices.contains(flag + 1) else { return .control }
        return Page(rawValue: args[flag + 1]) ?? .control
    }

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model, telemetry: model.telemetry, page: $page)
            ZStack {
                if page == .dojo {
                    DojoView(host: model.dojoHost)
                } else {
                    Backdrop(tint: page == .control ? UI.accent : UI.violet)
                    Group {
                        switch page {
                        case .control: ControlPage(model: model) { page = .dojo }
                        case .gestures: GesturesPage(model: model)
                        case .settings: SettingsPage(model: model)
                        case .dojo: EmptyView()
                        }
                    }
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.18), value: page)
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .onAppear { model.start() }
    }
}

/// Translucent source-list sidebar: navigation on top, the watch at a glance at the bottom.
private struct Sidebar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var telemetry: Telemetry
    @Binding var page: Page

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(colors: [UI.accent, UI.violet], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 32, height: 32)
                        .shadow(color: UI.accent.opacity(0.5), radius: 8, y: 2)
                    Image(systemName: "applewatch.radiowaves.left.and.right")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("Gauntlet").font(.system(size: 16, weight: .bold, design: .rounded))
                    Text("Air mouse").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 50)
            .padding(.bottom, 20)

            ForEach(Page.allCases) { item in
                let selected = page == item
                Button { page = item } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(selected ? UI.accent : .secondary)
                            .frame(width: 22)
                        Text(item.title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(selected ? Color.white.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer()
            deviceCard
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
        .frame(width: 216)
        .background(VisualEffect(material: .sidebar))
        .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.08)).frame(width: 1) }
    }

    private var deviceCard: some View {
        let s = telemetry.snapshot
        let status: (text: String, color: Color) = {
            if !model.isConnected { return ("No watch", .gray) }
            if s.paused { return ("Paused", UI.amber) }
            if model.sandboxActive { return ("Dojo sandbox", UI.violet) }
            if s.engaged { return ("Pointing", UI.accent) }
            return ("Ready", UI.green)
        }()
        let name: String = {
            if case .connected(let name, _) = model.link { return name }
            return "Apple Watch"
        }()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: model.isConnected ? "applewatch" : "applewatch.slash")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(model.isConnected ? .primary : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(status.color).frame(width: 6, height: 6)
                            .shadow(color: status.color, radius: 3)
                        Text(status.text).font(.system(size: 11, weight: .medium)).foregroundStyle(status.color)
                    }
                }
                Spacer(minLength: 0)
            }
            if model.isConnected, let battery = s.battery {
                HStack(spacing: 6) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.10))
                            Capsule().fill(battery <= 15 ? UI.red : UI.green)
                                .frame(width: proxy.size.width * CGFloat(max(0.04, Double(battery) / 100)))
                        }
                    }
                    .frame(height: 4)
                    Text("\(battery)%").font(.system(size: 10, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }
}

private struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var telemetry: Telemetry
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusLine)
        Divider()
        Button(telemetry.snapshot.paused ? "Resume Control" : "Pause Control") { model.togglePause() }
            .keyboardShortcut("p")
        Button("Recenter") { model.recenter() }
        Divider()
        Button("Open Gauntlet") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit Gauntlet") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private var statusLine: String {
        switch model.link {
        case .connected(let name, _): return telemetry.snapshot.paused ? "\(name) — paused" : "\(name) — connected"
        case .awaitingApproval(let name, _): return "\(name) wants to pair"
        case .handshaking: return "Connecting…"
        case .waiting: return "Waiting for your watch"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched as a bare binary (swift run) rather than from the .app bundle: still behave like an app.
        if Bundle.main.bundleIdentifier == nil {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        scheduleSnapshotIfRequested()
    }

    /// `--snapshot <file.png> [--after <seconds>]` saves a picture of the main window and quits.
    /// Used to check the UI without needing screen-recording permission.
    private func scheduleSnapshotIfRequested() {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--snapshot"), args.indices.contains(flag + 1) else { return }
        let path = args[flag + 1]
        let delay = args.firstIndex(of: "--after").flatMap { args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil } ?? 3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            defer { NSApp.terminate(nil) }
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }),
                  let data = Self.capture(window) else { return }
            try? data.write(to: URL(fileURLWithPath: path))
            // The app's opaque background hides the 3D layer in the composite; save the scene alone too.
            if let content = window.contentView, let scene = Self.firstSceneView(in: content),
               let tiff = scene.snapshot().tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path + ".scene.png"))
            }
        }
    }

    private static func firstSceneView(in view: NSView) -> SCNView? {
        if let found = view as? SCNView { return found }
        for child in view.subviews { if let found = firstSceneView(in: child) { return found } }
        return nil
    }

    /// The window as the user sees it. AppKit cannot cache a Metal-backed view, so a 3D scene
    /// (the Dojo) comes from SceneKit's own snapshot with the SwiftUI layer composited on top.
    private static func capture(_ window: NSWindow) -> Data? {
        guard let content = window.contentView else { return nil }
        content.layoutSubtreeIfNeeded()
        let bounds = content.bounds
        let scale = window.backingScaleFactor
        func makeBitmap() -> NSBitmapImageRep? {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale),
                                       pixelsHigh: Int(bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0)
            rep?.size = bounds.size
            return rep
        }
        func findSceneView(in view: NSView) -> SCNView? {
            if let found = view as? SCNView { return found }
            for child in view.subviews { if let found = findSceneView(in: child) { return found } }
            return nil
        }
        let sceneView = findSceneView(in: content)
        let sceneImage = sceneView?.snapshot()
        sceneView?.isHidden = true
        defer { sceneView?.isHidden = false }
        guard let overlay = makeBitmap() else { return nil }
        content.cacheDisplay(in: bounds, to: overlay)

        guard let canvas = makeBitmap(), let graphics = NSGraphicsContext(bitmapImageRep: canvas) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        NSColor(red: 0.027, green: 0.043, blue: 0.078, alpha: 1).setFill()
        bounds.fill()
        if let sceneView, let sceneImage {
            var frame = sceneView.convert(sceneView.bounds, to: content)
            if content.isFlipped { frame.origin.y = bounds.height - frame.maxY }
            sceneImage.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
        }
        overlay.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return canvas.representation(using: .png, properties: [:])
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave a mouse button held down behind us.
        MainActor.assumeIsolated { AppModel.shared.shutdown() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

public struct GauntletApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppModel.shared

    public init() {}

    public var body: some Scene {
        Window("Gauntlet", id: "main") {
            RootView(model: model)
                .frame(minWidth: 1060, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 820)

        MenuBarExtra {
            MenuBarContent(model: model, telemetry: model.telemetry)
        } label: {
            Image(systemName: model.isConnected ? "applewatch.radiowaves.left.and.right" : "applewatch")
        }
    }
}

public enum GauntletMain {
    /// Entry point used by the executable target.
    public static func run() {
        GauntletApplication.main()
    }
}
