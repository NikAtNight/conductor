import Foundation
import Combine

/// What the UI shows. Latest camera snapshots publish at 30 Hz on the main actor;
/// clicks and control events are delivered separately so preview coalescing cannot drop them.
@MainActor
final class TrackingState: ObservableObject {
    @Published var hands: [HandPose] = []
    /// The user's face, while it's being detected: the gesture log is on, the display mode is
    /// "Display you're looking at", or look calibration is running.
    @Published var face: FacePose?
    /// Name of the display the control box currently maps onto, in modes where that can change.
    @Published var targetDisplayName: String?
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
    /// The trigger held or forming, for the preview's gesture panel.
    @Published var activeTrigger: Trigger?
    /// Fires once per click Conductor sends (left, right, middle, dwell).
    let clicks = PassthroughSubject<Void, Never>()
    let events = PassthroughSubject<GestureRecognizer.Event, Never>()
}
