import CoreGraphics

/// Maps a normalized Vision point to screen pixels.
///
/// Only a centered sub-rectangle of the camera frame (the control box) maps to the screen. Reaching
/// the frame edges would mean waving your arm across the whole field of view; a 60% box means a
/// comfortable wrist-and-forearm motion covers everything. Points outside the box clamp to the edge.
struct ScreenMapper {
    /// Fraction of the frame width and height used as the active area, 0 < value <= 1.
    var boxWidth: CGFloat
    var boxHeight: CGFloat
    /// Vertical offset of the box center as a fraction of frame height. Positive moves the box up,
    /// which suits a laptop camera looking slightly down at a hand held in front of the chest.
    var boxOffsetY: CGFloat
    /// Front cameras show the world un-mirrored, so your right is the frame's left. On by default.
    var mirrored: Bool
    var screen: CGRect

    init(boxWidth: CGFloat = 0.6, boxHeight: CGFloat = 0.5, boxOffsetY: CGFloat = 0.0,
         mirrored: Bool = true, screen: CGRect) {
        self.boxWidth = boxWidth
        self.boxHeight = boxHeight
        self.boxOffsetY = boxOffsetY
        self.mirrored = mirrored
        self.screen = screen
    }

    /// Input uses Vision's bottom-left origin. Output uses CGEvent's top-left origin.
    func map(_ point: CGPoint) -> CGPoint {
        var x = mirrored ? 1 - point.x : point.x
        var y = 1 - point.y

        let left = (1 - boxWidth) / 2
        let top = (1 - boxHeight) / 2 - boxOffsetY
        x = ((x - left) / boxWidth).clamped(to: 0...1)
        y = ((y - top) / boxHeight).clamped(to: 0...1)

        return CGPoint(x: screen.minX + x * screen.width, y: screen.minY + y * screen.height)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
