import Foundation

/// One-click starting points. Each sets a handful of existing preferences; everything stays
/// adjustable afterwards.
enum Preset: String, CaseIterable, Identifiable {
    case standard, steady, large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Standard"
        case .steady: return "Steadier"
        case .large: return "Bigger movements"
        }
    }

    var summary: String {
        switch self {
        case .standard: return "The defaults."
        case .steady: return "For tremor or shaky hands: heavier smoothing, more room before a click turns into a drag, a wider pinch range, and dwell click with extra wobble allowed."
        case .large: return "For limited finger control: a bigger box, an easier pinch, and dwell click so pinching is optional."
        }
    }

    @MainActor
    func apply(to p: Preferences) {
        switch self {
        case .standard:
            p.smoothing = 0.6
            p.pinchEngage = 0.35
            p.pinchRelease = 0.55
            p.pinchDeadZone = 0.012
            p.dwellClick = false
            p.dwellTime = 0.8
            p.dwellRadius = 0.015
            p.boxWidth = 0.6
            p.requireReadyPose = true
        case .steady:
            p.smoothing = 0.3
            p.pinchEngage = 0.3
            p.pinchRelease = 0.6
            p.pinchDeadZone = 0.03
            p.dwellClick = true
            p.dwellTime = 1.0
            p.dwellRadius = 0.03
            p.boxWidth = 0.6
            p.requireReadyPose = true
        case .large:
            p.smoothing = 0.6
            p.pinchEngage = 0.45
            p.pinchRelease = 0.7
            p.pinchDeadZone = 0.02
            p.dwellClick = true
            p.dwellTime = 1.0
            p.dwellRadius = 0.025
            p.boxWidth = 0.85
            p.requireReadyPose = true
        }
    }
}

/// Gesture bindings for one app, used while that app is frontmost.
struct AppProfile: Codable, Equatable, Identifiable {
    var bundleID: String
    var name: String
    var map: GestureMap
    var id: String { bundleID }
}
