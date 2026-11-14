import SwiftUI
import GauntletLink
import GauntletEngine
import GauntletDojo

struct SettingsPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "Settings", subtitle: "Make the pointer feel like yours.") {
                    Button("Restore Defaults") { model.resetSettings() }.buttonStyle(GlassButtonStyle())
                }

                RowGroup("Pointer feel") {
                    SliderRow(symbol: "hare.fill", color: UI.accent, title: "Speed",
                              value: $model.settings.sensitivity, range: 0.3...3.0) { String(format: "%.1f×", $0) }
                    SliderRow(symbol: "water.waves", color: UI.blue, title: "Steadiness",
                              detail: "Filters out hand tremor; higher feels slightly softer",
                              value: $model.settings.smoothing, range: 0...1) { String(format: "%.0f%%", $0 * 100) }
                    SliderRow(symbol: "scope", color: UI.violet, title: "Fine control",
                              detail: "How much slow movement is scaled down for precision",
                              value: $model.settings.precisionMultiplier, range: 0.15...1.0) { String(format: "%.2f×", $0) }
                    SliderRow(symbol: "arrow.left.and.right", color: UI.pink, title: "Sweep boost",
                              detail: "How much fast swings are amplified to cross the screen",
                              value: $model.settings.boostMultiplier, range: 1.0...4.0) { String(format: "%.1f×", $0) }
                    ToggleRow(symbol: "arrow.left.arrow.right", color: .gray, title: "Reverse left and right", isOn: $model.settings.invertX)
                    ToggleRow(symbol: "arrow.up.arrow.down", color: .gray, title: "Reverse up and down", isOn: $model.settings.invertY, showsDivider: false)
                }

                RowGroup("Taking and releasing control",
                         footer: model.settings.clutch == .raiseToPoint
                             ? "Lift your forearm above the angle to take control; lower it to the keyboard to let go."
                             : "The pointer follows your arm whenever it is not hanging at your side.") {
                    Row(symbol: "hand.raised.fill", color: UI.accent, title: "Pointer follows your arm") {
                        Picker("", selection: $model.settings.clutch) {
                            ForEach(ClutchMode.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 230)
                    }
                    if model.settings.clutch == .raiseToPoint {
                        SliderRow(symbol: "angle", color: UI.amber, title: "Lift angle",
                                  value: $model.settings.raiseAngleDeg, range: -10...35) { String(format: "%.0f°", $0) }
                    }
                    ToggleRow(symbol: "keyboard.fill", color: UI.green, title: "Hold still while typing",
                              detail: "Like a trackpad's palm rejection", isOn: $model.typingGuardEnabled, showsDivider: false)
                }

                RowGroup("Scrolling and touch") {
                    SliderRow(symbol: "digitalcrown.horizontal.arrow.clockwise.fill", color: UI.amber, title: "Digital Crown speed",
                              value: $model.settings.crownScrollGain, range: 200...2500) { String(format: "%.0f", $0) }
                    SliderRow(symbol: "wind", color: UI.blue, title: "Air-scroll speed",
                              value: $model.settings.airScrollGain, range: 400...4000) { String(format: "%.0f", $0) }
                    SliderRow(symbol: "hand.point.up.left.fill", color: UI.green, title: "Watch-face trackpad speed",
                              value: $model.settings.touchGain, range: 0.8...6) { String(format: "%.1f×", $0) }
                    ToggleRow(symbol: "arrow.up.arrow.down.circle.fill", color: .gray, title: "Reverse scroll direction",
                              isOn: $model.settings.scrollInverted, showsDivider: false)
                }

                RowGroup("Watch", footer: "Calibration sets the wearing direction. Flip it by hand only if up and down feel reversed.") {
                    ToggleRow(symbol: "iphone.radiowaves.left.and.right", color: UI.pink, title: "Haptic feedback", isOn: $model.settings.hapticsEnabled)
                    ToggleRow(symbol: "arrow.left.arrow.right.square.fill", color: UI.violet, title: "Watch is worn the other way round",
                              isOn: $model.settings.forearmAxisFlipped, showsDivider: model.trustedWatches.isEmpty ? false : true)
                    ForEach(Array(model.trustedWatches.enumerated()), id: \.element.id) { index, watch in
                        Row(symbol: "checkmark.shield.fill", color: UI.green, title: watch.name,
                            detail: "Paired \(watch.pairedAt.formatted(date: .abbreviated, time: .shortened))",
                            showsDivider: index < model.trustedWatches.count - 1) {
                            Button("Forget") { model.forget(watch) }.buttonStyle(GlassButtonStyle(color: UI.red))
                        }
                    }
                }

                RowGroup("Advanced", footer: "The developer link accepts a simulated watch from this Mac only. Leave it off for everyday use.") {
                    Row(symbol: model.accessibilityGranted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                        color: model.accessibilityGranted ? UI.green : UI.amber,
                        title: model.accessibilityGranted ? "Accessibility permission granted" : "Accessibility permission missing",
                        detail: testDetail) {
                        if model.accessibilityGranted {
                            Button("Test Pointer") { model.testPointer() }.buttonStyle(GlassButtonStyle())
                        } else {
                            Button("Open Settings") { model.requestAccessibility() }.buttonStyle(ProminentButtonStyle(color: UI.amber))
                        }
                    }
                    ToggleRow(symbol: "hammer.fill", color: .gray, title: "Developer link",
                              detail: "For the watchOS Simulator and fakewatch", isOn: $model.developerLinkEnabled, showsDivider: false)
                }
            }
            .padding(.horizontal, UI.pagePadding)
            .padding(.bottom, UI.pagePadding)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
    }

    private var testDetail: String? {
        switch model.pointerTestPassed {
        case .some(true): return "Pointer moved ✓"
        case .some(false): return "macOS ignored the test. Remove Gauntlet from the Accessibility list, add it again, relaunch."
        case .none: return model.accessibilityGranted ? nil : "Needed before Gauntlet can move the real cursor"
        }
    }
}
