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
}
