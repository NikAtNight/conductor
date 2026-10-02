import CoreGraphics

/// Decides where the control box sits in the camera frame.
///
/// The box lives in view space: normalized 0...1, mirrored the same way as ScreenMapper, origin
/// top-left, y down. It's the screen layout as the camera sees it, scaled down: displays to the
/// camera's right sit to the right of the lens axis (frame center), displays above sit higher.
///
/// Horizontally the camera's own x position lines up with frame center. Vertically the camera's
/// display lines up with a comfortable rest height instead, because lining up with the lens would
/// push the box into the bottom of the frame, where the wrist drops out of view and tracking stops.
enum ControlBox {
    struct Input {
        /// Box width as a fraction of frame width (user setting).
        var width: CGFloat
        /// Box height as a fraction of frame height, used when `matchShape` is off.
        var height: CGFloat
        /// Raises the rest height. Positive moves the box up.
        var offsetY: CGFloat
        /// Derive height from the target's shape so both axes move the cursor at the same speed.
        var matchShape: Bool
        /// The screen area the box maps onto, global coordinates.
        var target: CGRect
        /// Camera position in global coordinates, and the display it's mounted on.
        var cameraX: CGFloat
        var cameraDisplay: CGRect
    }

    /// Width over height of the 640x480 capture.
    static let frameAspect: CGFloat = 4.0 / 3.0
    /// Margins keep fingertips and wrist in frame. The bottom needs more room because the wrist
    /// hangs below the pointer, and Vision drops a hand whose wrist it can't see.
    static let topMargin: CGFloat = 0.02
    static let sideMargin: CGFloat = 0.02
    static let bottomMargin: CGFloat = 0.1

    static func layout(_ input: Input) -> CGRect {
        let target = input.target
        guard target.width > 0, target.height > 0 else {
            return CGRect(x: (1 - input.width) / 2, y: (1 - input.height) / 2, width: input.width, height: input.height)
        }

        var w = min(input.width, 1)
        var h = input.matchShape ? w * frameAspect * target.height / target.width : min(input.height, 1)
        if input.matchShape {
            // A tall layout (stacked screens) wants a tall box. Shrink both sides to keep the shape.
            let maxH = 1 - topMargin - bottomMargin
            let maxW = 1 - 2 * sideMargin
            let shrink = min(1, maxH / h, maxW / w)
            w *= shrink
            h *= shrink
        }

        let restY = 0.5 - input.offsetY
        let cameraFractionX = (input.cameraX - target.minX) / target.width
        let displayFractionY = (input.cameraDisplay.midY - target.minY) / target.height

        let left = (0.5 - cameraFractionX * w).clamped(to: range(sideMargin, 1 - w - sideMargin))
        let top = (restY - displayFractionY * h).clamped(to: range(topMargin, 1 - h - bottomMargin))
        return CGRect(x: left, y: top, width: w, height: h)
    }

    /// A clamp range that collapses to its lower bound when the box is too big for both margins.
    private static func range(_ low: CGFloat, _ high: CGFloat) -> ClosedRange<CGFloat> {
        high >= low ? low...high : max(0, high)...max(0, high)
    }
}
