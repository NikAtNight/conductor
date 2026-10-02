import CoreGraphics

/// Maps a normalized Vision point to screen pixels.
///
/// Only a sub-rectangle of the camera frame (the control box, placed by ControlBox) maps to the
/// screen. Reaching the frame edges would mean waving your arm across the whole field of view; a
/// smaller box means a comfortable wrist-and-forearm motion covers everything. Points outside the
/// box clamp to its edge.
struct ScreenMapper {
    /// The control box in view space (mirrored per `mirrored`, origin top-left, y down).
    var box: CGRect
    /// Front cameras show the world un-mirrored, so your right is the frame's left. On by default.
    var mirrored: Bool
    var screen: CGRect

    /// Input uses Vision's bottom-left origin. Output uses CGEvent's top-left origin.
    func map(_ point: CGPoint) -> CGPoint {
        let viewX = mirrored ? 1 - point.x : point.x
        let viewY = 1 - point.y
        let x = ((viewX - box.minX) / box.width).clamped(to: 0...1)
        let y = ((viewY - box.minY) / box.height).clamped(to: 0...1)
        return CGPoint(x: screen.minX + x * screen.width, y: screen.minY + y * screen.height)
    }

    /// The box in Vision space (bottom-left origin, un-mirrored), for drawing over the camera preview.
    static func visionRect(forViewBox box: CGRect, mirrored: Bool) -> CGRect {
        CGRect(x: mirrored ? 1 - box.maxX : box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
