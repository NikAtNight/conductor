import SwiftUI

struct TrackingSettingsView: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        Form {
            Section("Control box") {
                SettingSlider(title: "Width", value: $preferences.boxWidth, range: 0.2...1.0, format: "%.0f%%", scale: 100)
                Toggle("Match the shape of your screens", isOn: $preferences.matchScreenShape)
                SettingSlider(title: "Height", value: $preferences.boxHeight, range: 0.2...1.0, format: "%.0f%%", scale: 100)
                    .disabled(preferences.matchScreenShape)
                SettingSlider(title: "Vertical offset", value: $preferences.boxOffsetY, range: -0.3...0.3, format: "%+.0f%%", scale: 100)
                Toggle("Mirror camera (hand right = cursor right)", isOn: $preferences.mirrored)
                Caption("The dashed box in the preview maps to your screens. Smaller means less arm travel but coarser aim. Matching the shape keeps up-down and left-right moves at the same speed, which matters most for stacked screens.")
            }
            Section("Feel") {
                SettingSlider(title: "Smoothing cutoff", value: $preferences.smoothing, range: 0.1...3.0, format: "%.1f Hz")
                Caption("Lower is steadier but laggier. 0.6 is a good start; go down to 0.3 if the cursor still shivers.")
                SettingSlider(title: "Pinch engage", value: $preferences.pinchEngage, range: 0.15...0.6, format: "%.2f")
                SettingSlider(title: "Pinch release", value: $preferences.pinchRelease, range: 0.3...0.9, format: "%.2f")
                Caption("Thumb-to-index distance in hand widths. Release must stay above engage or clicks will chatter.")
                SettingSlider(title: "Scroll speed", value: $preferences.scrollGain, range: 0.2...3.0, format: "%.1fx")
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
}

struct DisplaySettingsView: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        Form {
            Section("Displays") {
                Picker("Hand controls", selection: $preferences.displayMode) {
                    ForEach(Preferences.DisplayMode.allCases) { Text($0.title).tag($0) }
                }
                Caption("All displays stretches the control box across every monitor. Display under the cursor re-targets whichever screen the cursor is on each time your hand comes back into view, so park the mouse on a monitor and raise your hand.")
            }
            Section("Camera position") {
                CameraPlacementView(preferences: preferences)
                Caption("The control box is laid out the way your screens sit around the camera. Reach toward a screen and the cursor goes there, whether your screens are side by side or stacked.")
            }
        }
        .formStyle(.grouped)
    }
}
