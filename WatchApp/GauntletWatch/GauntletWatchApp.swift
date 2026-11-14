#if os(watchOS)
import Foundation
import SwiftUI

@main
struct GauntletWatchApp: App {
    @StateObject private var model = AppModel(services: PlatformServices.live())

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.session)
        }
    }
}
#endif
