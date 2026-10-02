import SwiftUI

struct HandsSettingsView: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        Form {
            Section("Main hand") {
                Picker("Cursor follows", selection: $preferences.mainHand) {
                    ForEach(GestureRecognizer.MainHand.allCases) { Text($0.title).tag($0) }
                }
                Caption("With both hands in view, this one moves the cursor. The other only joins in for two-hand gestures.")
            }
            Section("Taking control") {
                Toggle("Hold an open hand still to take control", isOn: $preferences.requireReadyPose)
                Caption("Keeps the cursor from following your hand while you type, talk, or reach for a drink. Hold a flat, open hand still for half a second to take control. Drop your hand out of view for a couple of seconds to give it back.")
            }
            Section("Dwell click") {
                Toggle("Click by holding the cursor still", isOn: $preferences.dwellClick)
                SettingSlider(title: "Hold time", value: $preferences.dwellTime, range: 0.4...2.0, format: "%.1f s")
                    .disabled(!preferences.dwellClick)
                Caption("For when pinching is hard or tiring. Hold the cursor still to click, then move away before the next click.")
            }
            Section("Pausing") {
                Caption("Bind a gesture to Pause / resume in the Gestures tab to stop all input without turning the camera off. Make the same gesture again to resume. ⌃⌥⌘H turns the camera off completely.")
            }
        }
        .formStyle(.grouped)
    }
}
