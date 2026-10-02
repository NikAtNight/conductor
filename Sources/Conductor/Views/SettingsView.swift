import SwiftUI

struct TrackingSettingsView: View {
    @ObservedObject var preferences: Preferences
    let calibrate: () -> Void

    var body: some View {
        Form {
            Section("Pointer") {
                Picker("Cursor moves", selection: $preferences.pointerMode) {
                    ForEach(Preferences.PointerMode.allCases) { Text($0.title).tag($0) }
                }
                SettingSlider(title: "Trackpad speed", value: $preferences.trackpadSpeed, range: 0.3...3.0, format: "%.1fx")
                    .disabled(preferences.pointerMode != .relative)
                Caption("Like a trackpad: the cursor moves by how far your hand moves, faster when you move faster. To reposition, drop your hand out of view and bring it back. The control box only applies to the other mode.")
            }
            Section("Control box") {
                SettingSlider(title: "Width", value: $preferences.boxWidth, range: 0.2...1.0, format: "%.0f%%", scale: 100)
                Toggle("Match the shape of your screens", isOn: $preferences.matchScreenShape)
                SettingSlider(title: "Height", value: $preferences.boxHeight, range: 0.2...1.0, format: "%.0f%%", scale: 100)
                    .disabled(preferences.matchScreenShape)
                SettingSlider(title: "Vertical offset", value: $preferences.boxOffsetY, range: -0.3...0.3, format: "%+.0f%%", scale: 100)
                Toggle("Mirror camera (hand right = cursor right)", isOn: $preferences.mirrored)
                HStack {
                    Text(preferences.calibratedBox == nil ? "Automatic box" : "Using your calibrated reach")
                    Spacer()
                    if preferences.calibratedBox != nil {
                        Button("Use automatic") { preferences.calibratedBox = nil }
                    }
                    Button("Calibrate…", action: calibrate)
                }
                Caption("Calibrating measures the area you can comfortably reach and uses it as the box, replacing the size, shape, and camera-position settings. The dashed box in the preview maps to your screens. Smaller means less arm travel but coarser aim. Matching the shape keeps up-down and left-right moves at the same speed, which matters most for stacked screens.")
            }
            Section("Feel") {
                SettingSlider(title: "Smoothing cutoff", value: $preferences.smoothing, range: 0.1...3.0, format: "%.1f Hz")
                Caption("Lower is steadier but laggier. 0.6 is a good start; go down to 0.3 if the cursor still shivers.")
                SettingSlider(title: "Pinch engage", value: $preferences.pinchEngage, range: 0.15...0.6, format: "%.2f")
                SettingSlider(title: "Pinch release", value: $preferences.pinchRelease, range: 0.3...0.9, format: "%.2f")
                Caption("Thumb-to-index distance in hand widths. Release must stay above engage or clicks will chatter.")
                SettingSlider(title: "Click dead zone", value: $preferences.pinchDeadZone, range: 0.005...0.05, format: "%.1f%%", scale: 100)
                Caption("How far your hand can drift during a pinch before a click becomes a drag. Raise it if clicks keep turning into small drags.")
                SettingSlider(title: "Scroll speed", value: $preferences.scrollGain, range: 0.2...3.0, format: "%.1fx")
                Toggle("Keep scrolling after a flick", isOn: $preferences.momentumScroll)
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
