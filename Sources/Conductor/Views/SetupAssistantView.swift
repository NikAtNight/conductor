import SwiftUI
import Combine
import AVFoundation
import ApplicationServices

/// First-run walkthrough: permissions, screens and camera, look and reach calibration, and the
/// basic gestures. Every status updates live, so granting a permission in System Settings ticks
/// the step.
struct SetupAssistantView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var state: TrackingState
    let calibrate: () -> Void
    let calibrateLook: () -> Void
    let done: () -> Void

    @State private var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var trusted = AXIsProcessTrusted()
    @State private var devices = CameraCapture.availableDevices()
    @State private var displays = DisplayLayout.current()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Set up Conductor").font(.title2.weight(.semibold))
            Text("Six quick steps. You can come back here any time from the menu bar.")
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    step(1, "Let Conductor see you", done: cameraStatus == .authorized) {
                        Text("The camera feed is read on this Mac and never saved or sent anywhere.")
                        switch cameraStatus {
                        case .notDetermined:
                            Button("Allow camera access") {
                                Task {
                                    _ = await CameraCapture.requestAccess()
                                    cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
                                }
                            }
                        case .authorized:
                            EmptyView()
                        default:
                            Button("Open Camera settings") { open("Privacy_Camera") }
                        }
                        if devices.count > 1 {
                            CameraPicker("Camera", preferences: preferences, devices: devices)
                        }
                    }
                    step(2, "Let Conductor move the pointer", done: trusted) {
                        Text("macOS asks for Accessibility access before any app can click or type for you. Turn Conductor on in the list.")
                        if !trusted {
                            Button("Open Accessibility settings") {
                                _ = Permissions.accessibilityGranted(prompt: true)
                                open("Privacy_Accessibility")
                            }
                        }
                    }
                    step(3, "Your screens and camera", done: preferences.cameraPlacement != nil) {
                        Text("\(displaySummary) Click the screen your camera sits on.")
                        CameraPlacementView(preferences: preferences)
                    }
                    step(4, "Show which screen you're looking at", done: preferences.lookModel != nil) {
                        if displays.count < 2 {
                            Text("You have one display, so this isn't needed.")
                        } else {
                            Text("Sit the way you usually do. A dot will walk around the corners of each screen; follow it with your eyes and let your head move naturally. About eight seconds per screen.")
                            Text("Run it from where you usually sit. If you also work leaning back, run it again from there; Conductor keeps one pass per distance and blends between them.")
                        }
                        HStack {
                            Button("Calibrate Look", action: calibrateLook)
                                .disabled(cameraStatus != .authorized || displays.count < 2)
                            Text(lookText).foregroundStyle(.secondary)
                        }
                    }
                    step(5, "Calibrate your reach and speed", done: preferences.calibratedBox != nil) {
                        Text("Sit as you normally do. Press Calibrate, then move your whole hand around the edge of the area you can reach comfortably for six seconds. Optional; skip it to use the automatic box.")
                        HStack {
                            Button("Calibrate", action: calibrate)
                                .disabled(cameraStatus != .authorized || isCalibrating)
                            Text(calibrationText).foregroundStyle(.secondary)
                        }
                        Text("Then point at something small and adjust the speed until it's easy to land on. Changes apply right away.")
                        if preferences.pointerMode == .absolute {
                            SettingSlider(title: "Slow-move speed", value: $preferences.slowMoveSpeed, range: 0.1...1.0, format: "%.0f%%", scale: 100)
                        } else {
                            SettingSlider(title: "Trackpad speed", value: $preferences.trackpadSpeed, range: 0.3...3.0, format: "%.1fx")
                        }
                    }
                    step(6, "The gestures", done: false) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("• Hold an open hand still for half a second to take control.")
                            Text("• Point with your hand; pinch thumb and index to click, hold the pinch to drag.")
                            Text("• Thumb to middle finger to right click. A fist moved up or down scrolls.")
                            Text("• Pinch with both hands and spread to zoom. Two fingers up and a flick to swipe.")
                            Text("• ⌃⌥⌘H turns tracking on and off from anywhere.")
                        }
                    }
                }
                .padding(.vertical, 18)
            }
            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560, height: 720)
        .onReceive(tick) { _ in
            cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
            trusted = AXIsProcessTrusted()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in
            devices = CameraCapture.availableDevices()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in
            devices = CameraCapture.availableDevices()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays = DisplayLayout.current()
        }
    }

    private var displaySummary: String {
        let names = ListFormatter.localizedString(byJoining: displays.map(\.name))
        return displays.count == 1 ? "Conductor sees 1 display: \(names)." : "Conductor sees \(displays.count) displays: \(names)."
    }

    private var lookText: String {
        guard let model = preferences.lookModel, let pass = model.passes.first else { return "" }
        let distances = model.passes.count == 1 ? "1 distance" : "\(model.passes.count) distances"
        return "Calibrated at \(distances) for \(pass.targets.count) displays."
    }

    private var isCalibrating: Bool {
        if case .running = state.calibration { return true }
        return false
    }

    private var calibrationText: String {
        switch state.calibration {
        case .none: return preferences.calibratedBox == nil ? "" : "Calibrated."
        case .running(let seconds): return "Trace your reach… \(seconds)s"
        case .finished: return "Calibrated."
        case .failed: return "Saw too small an area. Try again moving your whole hand, not just your fingers."
        }
    }

    private func step<Content: View>(_ number: Int, _ title: String, done: Bool,
                                     @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                .font(.title2)
                .foregroundStyle(done ? Color.green : Color.secondary)
                .accessibilityLabel(done ? "Step \(number), done" : "Step \(number)")
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content().fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func open(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
