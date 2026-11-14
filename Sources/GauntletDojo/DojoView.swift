import SwiftUI
import GauntletEngine

/// The 3D training environment: a SceneKit world with a SwiftUI HUD on top.
public struct DojoView: View {
    @StateObject private var controller: DojoController

    public init(host: DojoHost) {
        self.init(host: host, options: DojoOptions())
    }

    public init(host: DojoHost, options: DojoOptions) {
        _controller = StateObject(wrappedValue: DojoController(host: host, options: options))
    }

    public var body: some View {
        ZStack {
            DojoSceneView(controller: controller)
            DojoHUD(controller: controller)
        }
        .frame(minWidth: 800, minHeight: 640)
        .environment(\.colorScheme, .dark)
        .onAppear { controller.start() }
        .onDisappear { controller.stop() }
    }
}
