import Foundation
import Combine

/// User-tunable knobs, persisted in UserDefaults. The pipeline reads a snapshot each frame.
@MainActor
final class Preferences: ObservableObject {
    @Published var boxWidth: Double { didSet { save() } }
    @Published var boxHeight: Double { didSet { save() } }
    @Published var boxOffsetY: Double { didSet { save() } }
    @Published var mirrored: Bool { didSet { save() } }
    @Published var smoothing: Double { didSet { save() } }
    @Published var pinchEngage: Double { didSet { save() } }
    @Published var pinchRelease: Double { didSet { save() } }
    @Published var scrollGain: Double { didSet { save() } }
    @Published var zoomWithKeys: Bool { didSet { save() } }

    struct Snapshot: Sendable {
        var boxWidth: Double
        var boxHeight: Double
        var boxOffsetY: Double
        var mirrored: Bool
        var smoothing: Double
        var pinchEngage: Double
        var pinchRelease: Double
        var scrollGain: Double
        var zoomWithKeys: Bool
    }

    var snapshot: Snapshot {
        Snapshot(boxWidth: boxWidth, boxHeight: boxHeight, boxOffsetY: boxOffsetY, mirrored: mirrored,
                 smoothing: smoothing, pinchEngage: pinchEngage, pinchRelease: pinchRelease,
                 scrollGain: scrollGain, zoomWithKeys: zoomWithKeys)
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func d(_ key: String, _ fallback: Double) -> Double {
            defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key)
        }
        func b(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
        boxWidth = d("boxWidth", 0.6)
        boxHeight = d("boxHeight", 0.5)
        boxOffsetY = d("boxOffsetY", 0.05)
        mirrored = b("mirrored", true)
        smoothing = d("smoothing", 1.0)
        pinchEngage = d("pinchEngage", 0.35)
        pinchRelease = d("pinchRelease", 0.55)
        scrollGain = d("scrollGain", 1.0)
        zoomWithKeys = b("zoomWithKeys", false)
    }

    func resetToDefaults() {
        boxWidth = 0.6; boxHeight = 0.5; boxOffsetY = 0.05; mirrored = true
        smoothing = 1.0; pinchEngage = 0.35; pinchRelease = 0.55; scrollGain = 1.0; zoomWithKeys = false
    }

    private func save() {
        defaults.set(boxWidth, forKey: "boxWidth")
        defaults.set(boxHeight, forKey: "boxHeight")
        defaults.set(boxOffsetY, forKey: "boxOffsetY")
        defaults.set(mirrored, forKey: "mirrored")
        defaults.set(smoothing, forKey: "smoothing")
        defaults.set(pinchEngage, forKey: "pinchEngage")
        defaults.set(pinchRelease, forKey: "pinchRelease")
        defaults.set(scrollGain, forKey: "scrollGain")
        defaults.set(zoomWithKeys, forKey: "zoomWithKeys")
    }
}
