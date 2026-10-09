import CoreVideo
import Foundation

/// Watches frame brightness and hand-tracking confidence and turns sustained trouble into one
/// plain warning. Short dips are ignored: both values are averaged over about a second.
struct TrackingQuality {
    /// Mean luma (0...255) below which the picture is too dark for reliable tracking.
    static let darkBelow: Double = 45
    /// Average joint confidence (0...1) below which tracking is guessing.
    static let unsureBelow: Double = 0.45
    /// Weight of each new sample in the running averages; about one second at 30 fps.
    static let smoothing: Double = 1.0 / 30

    private(set) var brightness: Double?
    private(set) var confidence: Double?

    mutating func addBrightness(_ luma: Double) {
        brightness = brightness.map { $0 + (luma - $0) * Self.smoothing * 15 } ?? luma
    }

    mutating func addConfidence(_ value: Double) {
        confidence = confidence.map { $0 + (value - $0) * Self.smoothing } ?? value
    }

    /// Forget confidence when no hand is visible, so an old low value doesn't linger.
    mutating func handLost() { confidence = nil }

    var warning: String? {
        if let brightness, brightness < Self.darkBelow {
            return "Too dark to track well. Add light in front of you."
        }
        if let confidence, confidence < Self.unsureBelow {
            return "Tracking is unsure. Keep your whole hand in view, with light on it."
        }
        return nil
    }

    /// Average luma on a coarse grid, normalized to 0...255 for either YUV range or BGRA.
    static func meanLuma(of buffer: CVPixelBuffer) -> Double? {
        FramePixels.read(buffer) { pixels in
            var total = 0.0
            for gy in 0..<12 {
                let y = (gy * 2 + 1) * pixels.height / 24
                for gx in 0..<16 {
                    let x = (gx * 2 + 1) * pixels.width / 32
                    total += pixels.luma(x: x, y: y)
                }
            }
            return total / 192
        }
    }
}
