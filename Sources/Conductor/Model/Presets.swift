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

    /// Sets this preset's knobs. Standard is `Settings()`; the others start from it.
    func apply(to settings: inout Settings) {
        var p = Settings()
        switch self {
        case .standard:
            break
        case .steady:
            p.smoothing = 0.3
            p.setPinchEngage(0.3)
            p.setPinchRelease(0.6)
            p.pinchDeadZone = 0.05
            p.dwellClick = true
            p.dwellTime = 1.0
            p.dwellRadius = 0.03
        case .large:
            p.setPinchEngage(0.45)
            p.setPinchRelease(0.7)
            p.pinchDeadZone = 0.045
            p.dwellClick = true
            p.dwellTime = 1.0
            p.dwellRadius = 0.025
            p.boxWidth = 0.85
        }
        settings.smoothing = p.smoothing
        settings.setPinchEngage(p.pinchEngage)
        settings.setPinchRelease(p.pinchRelease)
        settings.pinchDeadZone = p.pinchDeadZone
        settings.dwellClick = p.dwellClick
        settings.dwellTime = p.dwellTime
        settings.dwellRadius = p.dwellRadius
        settings.boxWidth = p.boxWidth
        settings.requireReadyPose = p.requireReadyPose
    }
}

/// Gesture bindings for one app, used while that app is frontmost.
struct AppProfile: Codable, Equatable, Identifiable {
    var bundleID: String
    var name: String
    var map: GestureMap
    var id: String { bundleID }
}
