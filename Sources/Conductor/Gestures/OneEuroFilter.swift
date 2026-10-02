import Foundation

/// Adaptive low-pass filter (Casiez, Roussel, Vogel 2012). Smooths hard when the hand is still,
/// so the cursor doesn't shiver, and loosens up when it moves fast, so there's no rubber-band lag.
struct OneEuroFilter {
    var minCutoff: Double
    var beta: Double
    var derivativeCutoff: Double

    private var lastValue: Double?
    private var lastDerivative: Double = 0
    private var lastTime: TimeInterval?

    init(minCutoff: Double = 1.0, beta: Double = 0.4, derivativeCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    mutating func reset() {
        lastValue = nil
        lastDerivative = 0
        lastTime = nil
    }

    mutating func filter(_ value: Double, at time: TimeInterval) -> Double {
        guard let previous = lastValue, let previousTime = lastTime, time > previousTime else {
            lastValue = value
            lastTime = time
            return value
        }
        let dt = time - previousTime
        let rawDerivative = (value - previous) / dt
        let derivativeAlpha = Self.alpha(cutoff: derivativeCutoff, dt: dt)
        let derivative = derivativeAlpha * rawDerivative + (1 - derivativeAlpha) * lastDerivative
        let cutoff = minCutoff + beta * abs(derivative)
        let alpha = Self.alpha(cutoff: cutoff, dt: dt)
        let filtered = alpha * value + (1 - alpha) * previous
        lastValue = filtered
        lastDerivative = derivative
        lastTime = time
        return filtered
    }

    private static func alpha(cutoff: Double, dt: TimeInterval) -> Double {
        let tau = 1 / (2 * Double.pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}

/// Two filters, one per axis, sharing settings.
struct PointFilter {
    private var x: OneEuroFilter
    private var y: OneEuroFilter

    init(minCutoff: Double = 1.0, beta: Double = 0.4) {
        x = OneEuroFilter(minCutoff: minCutoff, beta: beta)
        y = OneEuroFilter(minCutoff: minCutoff, beta: beta)
    }

    mutating func reset() {
        x.reset()
        y.reset()
    }

    mutating func filter(_ point: CGPoint, at time: TimeInterval) -> CGPoint {
        CGPoint(x: x.filter(point.x, at: time), y: y.filter(point.y, at: time))
    }
}
