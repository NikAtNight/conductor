import SwiftUI
import AVFoundation

struct CameraSettingsView: View {
    @ObservedObject var preferences: Preferences
    @State private var devices = CameraCapture.availableDevices()

    var body: some View {
        Form {
            Section("Camera") {
                CameraPicker("Use", preferences: preferences, devices: devices)
                Caption(summary)
            }
            Section("Power") {
                Toggle("Save power when no hand is around", isOn: $preferences.powerSaving)
                Caption("After a minute without a hand in view, Conductor checks for one a few times a second instead of thirty. It goes back to full speed as soon as your hand appears. The camera stays on either way.")
            }
            Section("Picture quality") {
                Caption("If the picture is too dark or Conductor keeps losing track of your hand, the preview and the menu say so. Light from in front of you works best; a bright window behind you makes your hand a silhouette.")
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in
            devices = CameraCapture.availableDevices()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in
            devices = CameraCapture.availableDevices()
        }
    }

    private var summary: String {
        let current = CameraCapture.preferredDevice(id: preferences.cameraDeviceID)?.localizedName ?? "no camera found"
        if preferences.cameraDeviceID != nil, !devices.contains(where: { $0.uniqueID == preferences.cameraDeviceID }) {
            return "The chosen camera isn't connected, so Conductor is using \(current)."
        }
        return preferences.cameraDeviceID == nil ? "Automatic picks \(current)." : "Using \(current)."
    }
}

/// Automatic or one of the connected cameras. The caller owns the device list so it can refresh
/// it when cameras come and go.
struct CameraPicker: View {
    let title: String
    @ObservedObject var preferences: Preferences
    let devices: [AVCaptureDevice]

    init(_ title: String, preferences: Preferences, devices: [AVCaptureDevice]) {
        self.title = title
        self.preferences = preferences
        self.devices = devices
    }

    var body: some View {
        Picker(title, selection: $preferences.cameraDeviceID) {
            Text("Automatic").tag(String?.none)
            ForEach(devices, id: \.uniqueID) { device in
                Text(device.localizedName).tag(Optional(device.uniqueID))
            }
        }
    }
}
