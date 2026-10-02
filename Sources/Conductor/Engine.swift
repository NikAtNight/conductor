import AVFoundation
import AppKit

/// Runs the camera -> tracker -> gesture -> input pipeline. One instance for the app's life.
final class Engine {
    let camera = CameraCapture()
    let state: TrackingState

    private let tracker = HandTracker()
    private var frameTimes: [CFTimeInterval] = []

    @MainActor
    init(state: TrackingState) {
        self.state = state
        camera.onFrame = { [weak self] buffer in self?.process(buffer) }
    }

    @MainActor
    func start() async {
        guard await CameraCapture.requestAccess() else {
            state.error = "Camera access denied. Enable it in System Settings > Privacy & Security > Camera."
            return
        }
        do {
            try camera.configure()
        } catch {
            state.error = "Camera setup failed: \(error)"
            return
        }
        state.error = nil
        camera.start()
        state.isRunning = true
    }

    @MainActor
    func stop() {
        camera.stop()
        state.isRunning = false
        state.hands = []
        state.gestureLabel = "Paused"
    }

    /// Runs on the camera queue.
    private func process(_ buffer: CMSampleBuffer) {
        let hands = tracker.detect(in: buffer)
        let now = CACurrentMediaTime()
        frameTimes.append(now)
        frameTimes.removeAll { now - $0 > 1 }
        let fps = Double(frameTimes.count)
        let label = hands.isEmpty ? "No hand" : "\(hands.count) hand\(hands.count == 1 ? "" : "s")"

        Task { @MainActor in
            self.state.hands = hands
            self.state.fps = fps
            self.state.gestureLabel = label
        }
    }
}
