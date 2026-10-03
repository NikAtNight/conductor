import CoreGraphics

/// The face Vision found in one camera frame: where it is, which way the head points, and where
/// the eyes are. Points are normalized to the camera frame like HandPose: origin bottom-left,
/// x right, y up, un-mirrored.
struct FacePose: Equatable {
    /// Height doubles as a distance gauge: a face half as tall is about twice as far from the camera.
    var box: CGRect
    /// Head angles in radians, Vision's conventions. Pitch is positive nodding down. Nil when Vision
    /// didn't compute one.
    var roll: Double?
    var yaw: Double?
    var pitch: Double?
    var leftEye: Eye?
    var rightEye: Eye?
    /// Vision's confidence in the landmark placement, 0...1. Low with glasses glare or a turned head.
    var landmarkConfidence: Float?

    struct Eye: Equatable {
        /// The eye opening, corners and lids.
        var outline: [CGPoint]
        var pupil: CGPoint?
        /// Share of near-white pixels over the eye, 0...1. Reflections in glasses push it up and make
        /// the pupil untrustworthy.
        var glare: Double?

        var bounds: CGRect? {
            guard let first = outline.first else { return nil }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for p in outline.dropFirst() {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }

        /// Where the pupil sits inside the opening, -1...1 on each axis: 0 is centred, +x toward the
        /// frame's right, +y toward the upper lid. A rough gaze direction relative to the head.
        var gaze: CGVector? {
            guard let pupil, let bounds, bounds.width > 0, bounds.height > 0 else { return nil }
            return CGVector(dx: (pupil.x - bounds.midX) / (bounds.width / 2),
                            dy: (pupil.y - bounds.midY) / (bounds.height / 2))
        }

        /// Height over width of the opening. Drops toward 0 in a blink.
        var openness: CGFloat? {
            guard let bounds, bounds.width > 0 else { return nil }
            return bounds.height / bounds.width
        }
    }
}
