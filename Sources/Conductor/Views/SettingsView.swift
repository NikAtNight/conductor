import SwiftUI

struct SettingsView: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        TabView {
            tracking.tabItem { Text("Tracking") }
            GestureSettingsView(preferences: preferences).tabItem { Text("Gestures") }
        }
        .frame(width: 500, height: 640)
    }

    private var tracking: some View {
        Form {
            Section("Displays") {
                Picker("Hand controls", selection: $preferences.displayMode) {
                    ForEach(Preferences.DisplayMode.allCases) { Text($0.title).tag($0) }
                }
                Text("All displays stretches the control box across every monitor. Display under the cursor re-targets whichever screen the cursor is on each time your hand comes back into view, so park the mouse on a monitor and raise your hand.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Camera position") {
                CameraPlacementView(preferences: preferences)
                Text("The control box is laid out the way your screens sit around the camera. Reach toward a screen and the cursor goes there, whether your screens are side by side or stacked.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Control box") {
                slider("Width", value: $preferences.boxWidth, in: 0.2...1.0, format: "%.0f%%", scale: 100)
                Toggle("Match the shape of your screens", isOn: $preferences.matchScreenShape)
                slider("Height", value: $preferences.boxHeight, in: 0.2...1.0, format: "%.0f%%", scale: 100)
                    .disabled(preferences.matchScreenShape)
                slider("Vertical offset", value: $preferences.boxOffsetY, in: -0.3...0.3, format: "%+.0f%%", scale: 100)
                Toggle("Mirror camera (hand right = cursor right)", isOn: $preferences.mirrored)
                Text("The dashed box in the preview maps to your screens. Smaller means less arm travel but coarser aim. Matching the shape keeps up-down and left-right moves at the same speed, which matters most for stacked screens.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Feel") {
                slider("Smoothing cutoff", value: $preferences.smoothing, in: 0.1...3.0, format: "%.1f Hz")
                Text("Lower is steadier but laggier. 0.6 is a good start; go down to 0.3 if the cursor still shivers.")
                    .font(.caption).foregroundStyle(.secondary)
                slider("Pinch engage", value: $preferences.pinchEngage, in: 0.15...0.6, format: "%.2f")
                slider("Pinch release", value: $preferences.pinchRelease, in: 0.3...0.9, format: "%.2f")
                Text("Thumb-to-index distance in hand widths. Release must stay above engage or clicks will chatter.")
                    .font(.caption).foregroundStyle(.secondary)
                slider("Scroll speed", value: $preferences.scrollGain, in: 0.2...3.0, format: "%.1fx")
            }
            Section("Zoom") {
                Picker("Send zoom as", selection: $preferences.zoomWithKeys) {
                    Text("Cmd + scroll wheel").tag(false)
                    Text("Cmd + / Cmd - keys").tag(true)
                }
                .pickerStyle(.radioGroup)
            }
            Section {
                HStack {
                    Spacer()
                    Button("Reset to defaults") { preferences.resetToDefaults() }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: preferences.pinchEngage) { _, engage in
            if preferences.pinchRelease < engage + 0.1 { preferences.pinchRelease = engage + 0.1 }
        }
        .onChange(of: preferences.pinchRelease) { _, release in
            if preferences.pinchEngage > release - 0.1 { preferences.pinchEngage = release - 0.1 }
        }
    }

    private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>,
                        format: String, scale: Double = 1) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue * scale))
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }
}
