import Foundation
import SwiftUI
import GauntletProtocol
import GauntletWatchCore

/// The main screen while connected.
///
/// The whole display is a small trackpad: drag for fine pointer movement, tap to click,
/// hold to right-click. The Digital Crown scrolls, and the system Double Tap gesture
/// triggers the capsule at the bottom. The ring shows what the Mac is doing, or what June is
/// doing while she listens and thinks. Hold the mic chip to talk to June; tap the gesture chip,
/// then move, to run a custom gesture.
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
        let june = JuneLook(session.assistantState)
        ZStack {
            touchSurface
            VStack(spacing: 2) {
                StatusOrb(mode: mode,
                          sandbox: flags.contains(.sandbox),
                          needsCalibration: flags.contains(.needsCalibration),
                          touching: touch.isTouching,
                          dim: dim,
                          june: june,
                          micLive: model.micLive)
                    .allowsHitTesting(false)      // touches fall through to the surface
                controls(mode: mode, june: june)
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

    private func controls(mode: ControlMode, june: JuneLook) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                NavigationLink {
                    ActionsView()
                } label: {
                    Image(systemName: "square.grid.2x2.fill")
                }
                .buttonStyle(ChipButtonStyle(color: Palette.cyan))
                .accessibilityLabel(Text("Actions"))

                // Tap, then make a gesture recorded on the Mac (Gestures page).
                Button {
                    model.armGesture()
                } label: {
                    Image(systemName: "scribble.variable")
                }
                .buttonStyle(ChipButtonStyle(color: Palette.violet))
                .accessibilityLabel(Text("Custom gesture"))

                // Hold to talk to June (works even when "Hey June" is off or the room is loud).
                HoldChip(symbol: june.takesOverRing ? june.symbol : "mic.fill",
                         color: Palette.june,
                         active: june.takesOverRing) { down in
                    model.setTalking(down)
                }
                .accessibilityLabel(Text("Hold to talk to June"))

                NavigationLink {
                    StatusView()
                } label: {
                    Image(systemName: "waveform.path.ecg")
                }
                .buttonStyle(ChipButtonStyle(color: Palette.cyan))
                .accessibilityLabel(Text("Status"))
            }

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
    var june: JuneLook = .quiet
    /// The watch mic is streaming to June.
    var micLive = false

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let juneOwns = june.takesOverRing
            ZStack {
                StatusRing(mode: mode, touching: touching, dim: dim,
                           override: juneOwns ? Palette.june : nil)
                    .frame(width: side, height: side)
                VStack(spacing: 1) {
                    if (june == .waiting || micLive) && !juneOwns {
                        // Hands-free indicator: the mic is open for "Hey June".
                        HStack(spacing: 3) {
                            Circle().fill(Palette.june).frame(width: 5, height: 5)
                            Text("JUNE")
                                .tracking(1.0)
                                .font(.system(size: max(8, side * 0.07), weight: .bold, design: .rounded))
                                .foregroundStyle(dim ? Palette.grey : Palette.june)
                        }
                    }
                    if sandbox && !juneOwns {
                        Text("DOJO")
                            .tracking(1.0)
                            .font(.system(size: max(8, side * 0.075), weight: .bold, design: .rounded))
                            .foregroundStyle(Palette.background)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(dim ? Palette.grey : Palette.violet))
                    }
                    Image(systemName: juneOwns ? june.symbol : mode.symbol)
                        .font(.system(size: max(12, side * 0.15), weight: .semibold))
                        .foregroundStyle(dim ? Palette.grey : (juneOwns ? Palette.june : mode.color))
                    Text(juneOwns ? june.label : mode.label)
                        .tracking(1.5)
                        .font(.system(size: max(12, side * 0.15), weight: .bold, design: .rounded))
                        .foregroundStyle(dim ? Palette.textDim : Color.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    if !dim {
                        Text(juneOwns ? june.hint : (needsCalibration ? "Calibrate on Mac" : mode.hint))
                            .font(.system(size: max(9, side * 0.082), weight: .medium, design: .rounded))
                            .foregroundStyle(!juneOwns && needsCalibration ? Palette.amber : Palette.textDim)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.6)
                    }
                }
                .frame(width: side * 0.6)
                .animation(dim ? nil : .easeInOut(duration: 0.2), value: mode)
                .animation(dim ? nil : .easeInOut(duration: 0.2), value: june)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}
