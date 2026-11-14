import Foundation
import SwiftUI
import GauntletLink
import GauntletWatchCore

/// Chooses the screen for the current link state.
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: WatchSessionController
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            content
        }
        .onAppear { model.launch() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.sceneBecameActive() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !model.sessionActive {
            EndedView()
        } else if let reason = model.rejection {
            RejectedView(reason: reason)
        } else {
            switch session.state {
            case .connected:
                NavigationStack {
                    ControlView()
                }
            case .awaitingApproval(let code, let macName):
                PairingCodeView(code: code, macName: macName)
            case .rejected(let reason):
                RejectedView(reason: reason)
            case .searching(let status):
                SearchingView(status: status)
            case .handshaking:
                SearchingView(status: "Securing the link…")
            case .idle:
                SearchingView(status: "Starting…")
            }
        }
    }
}
