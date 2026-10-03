import CoreGraphics

/// Turns six seconds of "trace the edge of your comfortable reach" into a control box.
enum Calibration {
    static let duration: Double = 6
    static let minimumSamples = 30
    /// Smallest believable reach, as a fraction of the frame. Anything smaller means the hand
    /// barely moved or wasn't tracked, and the old box is kept.
    static let minimumWidth: CGFloat = 0.12
    static let minimumHeight: CGFloat = 0.1

    /// The area the samples cover, from the 3rd to the 97th percentile on each axis so a few stray
    /// frames can't stretch it. Same space as the samples. Shown live while calibrating.
    static func extent(of points: [CGPoint]) -> CGRect? {
        guard !points.isEmpty else { return nil }
        let xs = points.map(\.x).sorted()
        let ys = points.map(\.y).sorted()
        func percentile(_ values: [CGFloat], _ q: Double) -> CGFloat {
            values[Int((Double(values.count - 1) * q).rounded())]
        }
        let minX = percentile(xs, 0.03), maxX = percentile(xs, 0.97)
        let minY = percentile(ys, 0.03), maxY = percentile(ys, 0.97)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Box in Vision space (bottom-left origin, un-mirrored) from pointer samples in that space:
    /// the traced extent, with each edge pulled in slightly so the screen edges are reachable
    /// without straining.
    static func box(from points: [CGPoint]) -> CGRect? {
        guard points.count >= minimumSamples, let traced = extent(of: points),
              traced.width >= minimumWidth, traced.height >= minimumHeight else { return nil }
        let inset: CGFloat = 0.01
        return traced.insetBy(dx: inset, dy: inset)
    }
}
