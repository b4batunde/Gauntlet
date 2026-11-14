import Foundation
import SwiftUI
import GauntletProtocol
import GauntletWatchCore

/// Large buttons for the things that are awkward to do with a gesture.
/// The Digital Crown scrolls this list; the Mac's state decides how each button looks.
struct ActionsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: WatchSessionController

    var body: some View {
        let flags = session.macState
        let paused = flags.contains(.paused)
        let dragging = flags.contains(.dragging)
        let scrolling = flags.contains(.scrollMode)
        ScrollView {
            VStack(spacing: 6) {
                ActionButton(title: paused ? "Resume" : "Pause",
                             symbol: paused ? "play.fill" : "pause.fill",
                             color: paused ? Palette.green : Palette.amber,
                             isOn: paused) {
                    model.perform(.togglePause)
                }
                ActionButton(title: "Recenter", symbol: "scope", color: Palette.cyan) {
                    model.perform(.recenter)
                }
                ActionButton(title: dragging ? "Release" : "Grab",
                             symbol: "hand.draw.fill",
                             color: Palette.violet,
                             isOn: dragging) {
                    model.perform(.toggleDrag)
                }
                ActionButton(title: "Air-scroll",
                             detail: scrolling ? "ON" : "OFF",
                             symbol: "arrow.up.and.down",
                             color: Palette.amber,
                             isOn: scrolling) {
                    model.perform(.toggleScrollMode)
                }
                ActionButton(title: "Right-click", symbol: "cursorarrow.click.2", color: Palette.green) {
                    model.perform(.rightClick)
                }
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 4)
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Actions")
    }
}
