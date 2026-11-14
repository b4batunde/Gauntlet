import Foundation
import SwiftUI
import GauntletProtocol
import GauntletWatchCore

/// The main screen while connected.
///
/// The whole display is a small trackpad: drag for fine pointer movement, tap to click,
/// hold to right-click. The Digital Crown scrolls, and the system Double Tap gesture
/// triggers the capsule at the bottom. The ring shows what the Mac is doing.
struct ControlView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: WatchSessionController
    @Environment(\.isLuminanceReduced) private var dim
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var touch = TouchSurfaceController()
    @GestureState private var fingerDown = false

    var body: some View {
        let flags = session.macState
        let mode = ControlMode(flags)
        ZStack {
            touchSurface
            VStack(spacing: 2) {
                StatusOrb(mode: mode,
                          sandbox: flags.contains(.sandbox),
                          needsCalibration: flags.contains(.needsCalibration),
                          touching: touch.isTouching,
                          dim: dim)
                    .allowsHitTesting(false)      // touches fall through to the surface
                controls(mode: mode)
            }
            .padding(.horizontal, 2)
        }
        .modifier(CrownScrollModifier(hapticsEnabled: model.hapticsEnabled) { turns in
            model.crownMoved(turns: turns)
        })
        .navigationTitle("Gauntlet")
        .onAppear {
            let model = self.model
            touch.emit = { [weak model] output in model?.handle(output) }
        }
        .onDisappear { touch.cancel() }
        .onChange(of: fingerDown) { _, down in
            if !down { touch.gestureBecameInactive() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { touch.cancel() }
        }
    }

    /// Sits behind everything and takes every touch that does not land on a button.
    private var touchSurface: some View {
        Palette.background
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .updating($fingerDown) { _, state, _ in state = true }
                    .onChanged { value in touch.changed(translation: value.translation) }
                    .onEnded { _ in touch.ended() }
            )
    }

    private func controls(mode: ControlMode) -> some View {
        HStack(spacing: 4) {
            NavigationLink {
                ActionsView()
            } label: {
                Image(systemName: "square.grid.2x2.fill")
            }
            .buttonStyle(ChipButtonStyle(color: Palette.cyan))
            .accessibilityLabel(Text("Actions"))

            // The system Double Tap gesture (thumb and index finger, twice) presses this.
            Button {
                model.perform(.handDoubleTap)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "hand.tap.fill")
                    Text("Double Tap")
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            .buttonStyle(PillButtonStyle(color: dim ? Palette.grey : Palette.cyan))
            .doubleTapPrimaryAction()

            NavigationLink {
                StatusView()
            } label: {
                Image(systemName: "waveform.path.ecg")
            }
            .buttonStyle(ChipButtonStyle(color: Palette.cyan))
            .accessibilityLabel(Text("Status"))
        }
        .opacity(dim ? 0.5 : 1.0)
    }
}

/// Ring plus a one-word state label, sized to whatever space the watch has.
struct StatusOrb: View {
    var mode: ControlMode
    var sandbox: Bool
    var needsCalibration: Bool
    var touching: Bool
    var dim: Bool

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                StatusRing(mode: mode, touching: touching, dim: dim)
                    .frame(width: side, height: side)
                VStack(spacing: 1) {
                    if sandbox {
                        Text("DOJO")
                            .tracking(1.0)
                            .font(.system(size: max(8, side * 0.075), weight: .bold, design: .rounded))
                            .foregroundStyle(Palette.background)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(dim ? Palette.grey : Palette.violet))
                    }
                    Image(systemName: mode.symbol)
                        .font(.system(size: max(12, side * 0.15), weight: .semibold))
                        .foregroundStyle(dim ? Palette.grey : mode.color)
                    Text(mode.label)
                        .tracking(1.5)
                        .font(.system(size: max(12, side * 0.15), weight: .bold, design: .rounded))
                        .foregroundStyle(dim ? Palette.textDim : Color.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    if !dim {
                        Text(needsCalibration ? "Calibrate on Mac" : mode.hint)
                            .font(.system(size: max(9, side * 0.082), weight: .medium, design: .rounded))
                            .foregroundStyle(needsCalibration ? Palette.amber : Palette.textDim)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.6)
                    }
                }
                .frame(width: side * 0.6)
                .animation(dim ? nil : .easeInOut(duration: 0.2), value: mode)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}
