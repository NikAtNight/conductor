import SwiftUI
import Combine
import AVFoundation
import ApplicationServices

/// First-run walkthrough: permissions, camera position, calibration, and the basic gestures.
/// Every status updates live, so granting a permission in System Settings ticks the step.
struct SetupAssistantView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var state: TrackingState
    let calibrate: () -> Void
    let done: () -> Void

    @State private var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var trusted = AXIsProcessTrusted()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Set up Conductor").font(.title2.weight(.semibold))
            Text("Five quick steps. You can come back here any time from the menu bar.")
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
                    step(3, "Show where your camera is", done: preferences.cameraPlacement != nil) {
                        Text("Click the screen your camera sits on. Automatic is fine for a laptop camera.")
                        CameraPlacementView(preferences: preferences)
                    }
                    step(4, "Calibrate your reach", done: preferences.calibratedBox != nil) {
                        Text("Sit as you normally do. Press Calibrate, then trace the edge of the area you can reach comfortably for six seconds. Optional; skip it to use the automatic box.")
                        HStack {
                            Button("Calibrate", action: calibrate)
                                .disabled(cameraStatus != .authorized || isCalibrating)
                            Text(calibrationText).foregroundStyle(.secondary)
                        }
                    }
                    step(5, "The gestures", done: false) {
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
        .frame(width: 560, height: 680)
        .onReceive(tick) { _ in
            cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
            trusted = AXIsProcessTrusted()
        }
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
        case .failed: return "Didn't see enough movement. Try again with bigger moves."
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
