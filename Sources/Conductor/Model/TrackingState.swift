import Foundation
import Combine

/// What the UI shows. Updated on the main actor from the camera pipeline.
@MainActor
final class TrackingState: ObservableObject {
    @Published var hands: [HandPose] = []
    @Published var gestureLabel: String = "No hand"
    @Published var isRunning = false
    @Published var fps: Double = 0
    @Published var error: String?
    /// Lighting or confidence trouble. Tracking still runs; it just won't be reliable.
    @Published var warning: String?
    /// True while power saving is checking for a hand only a few times a second.
    @Published var idle = false
    @Published var calibration: CalibrationStatus = .none

    enum CalibrationStatus: Equatable {
        case none
        case running(secondsLeft: Int)
        case finished
        case failed
    }
    /// The control box the pipeline is using, in view space (see ControlBox).
    @Published var controlBox = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.5)
    @Published var mode: GestureRecognizer.Mode = .idle
    @Published var feedback = GestureRecognizer.Feedback()
    /// Fires once per click Conductor sends (left, right, middle, dwell).
    let clicks = PassthroughSubject<Void, Never>()
    let events = PassthroughSubject<GestureRecognizer.Event, Never>()
}
