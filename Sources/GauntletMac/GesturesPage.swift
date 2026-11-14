import SwiftUI
import GauntletEngine
import GauntletDojo

struct GesturesPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "Gestures", subtitle: "Choose what each gesture does, and how eagerly it is recognised.") {
                    EmptyView()
                }

                RowGroup("Hands-free") {
                    bindingRow(.pinchTap, "hand.pinch.fill", UI.blue, "Tap thumb and index finger together")
                    bindingRow(.flickOut, "arrow.clockwise", UI.violet, "Twist the wrist outward and let it spring back")
                    bindingRow(.flickIn, "arrow.counterclockwise", UI.pink, "Twist the wrist inward and let it spring back")
                    bindingRow(.handDoubleTap, "hand.tap.fill", UI.accent, "Apple's double-pinch, while the watch display is awake")
                    bindingRow(.dwell, "timer", UI.amber, "Keep the pointer still for a moment", last: true)
                }

                RowGroup("On the watch face") {
                    bindingRow(.screenTap, "applewatch", UI.green, "Tap the display. Two quick taps double-click.")
                    bindingRow(.screenLongPress, "applewatch.watchface", UI.amber, "Press and hold the display", last: true)
                }

                RowGroup("Finger tap", footer: "Dojo calibration sets the strength from your own taps. Raise it if you get clicks you did not make; lower it if taps are missed.") {
                    ToggleRow(symbol: "hand.pinch.fill", color: UI.blue, title: "Recognise finger taps", isOn: $model.settings.gestures.tapEnabled)
                    SliderRow(symbol: "gauge.with.dots.needle.33percent", color: UI.accent, title: "Tap strength needed",
                              value: $model.settings.gestures.tapThreshold, range: 0.06...0.5) { String(format: "%.2f g", $0) }
                    SliderRow(symbol: "waveform.path", color: UI.violet, title: "Stand-out factor",
                              detail: "How far a tap must rise above surrounding movement",
                              value: $model.settings.gestures.tapQuietRatio, range: 2...6) { String(format: "%.1f×", $0) }
                    TapMeterRow(model: model, telemetry: model.telemetry)
                }

                RowGroup("Wrist flick") {
                    ToggleRow(symbol: "arrow.triangle.2.circlepath", color: UI.violet, title: "Recognise wrist flicks", isOn: $model.settings.gestures.flickEnabled)
                    SliderRow(symbol: "speedometer", color: UI.pink, title: "Flick speed needed",
                              detail: "A flick is a quick twist that springs straight back",
                              value: $model.settings.gestures.flickRate, range: 3...9, showsDivider: false) { String(format: "%.1f rad/s", $0) }
                }

                RowGroup("Dwell") {
                    ToggleRow(symbol: "timer", color: UI.amber, title: "Act when the pointer is held still", isOn: $model.settings.gestures.dwellEnabled)
                    SliderRow(symbol: "hourglass", color: UI.green, title: "Hold time",
                              value: $model.settings.gestures.dwellTime, range: 0.4...2.0, showsDivider: false) { String(format: "%.1f s", $0) }
                }
            }
            .padding(.horizontal, UI.pagePadding)
            .padding(.bottom, UI.pagePadding)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
    }

    private func bindingRow(_ gesture: GestureKind, _ symbol: String, _ color: Color, _ hint: String, last: Bool = false) -> some View {
        Row(symbol: symbol, color: color, title: gesture.title, detail: hint, showsDivider: !last) {
            Picker("", selection: Binding(get: { model.settings.action(for: gesture) },
                                          set: { model.settings.setAction($0, for: gesture) })) {
                ForEach(PointerAction.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 190)
        }
    }
}

/// Live accelerometer energy against the click threshold, so the sliders can be tuned by eye.
private struct TapMeterRow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var telemetry: Telemetry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Live tap energy").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text("dashed line = clicks above this").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Sparkline(values: telemetry.tapHistory, ceiling: max(0.4, model.settings.gestures.tapThreshold * 2),
                      color: UI.accent, marker: model.settings.gestures.tapThreshold)
                .frame(height: 58)
                .padding(6)
                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
