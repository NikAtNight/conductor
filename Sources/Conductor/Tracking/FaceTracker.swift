import CoreMedia
import CoreVideo
import Vision

/// Wraps Vision's face requests. Reports one face, the largest, taken to be the user. Call `detect`
/// from the camera queue; it is synchronous.
final class FaceTracker {
    private let rectangles = VNDetectFaceRectanglesRequest()
    private let landmarks = VNDetectFaceLandmarksRequest()

    init() {
        // Pitch is only reported from revision 3 on.
        rectangles.revision = VNDetectFaceRectanglesRequestRevision3
        landmarks.revision = VNDetectFaceLandmarksRequestRevision3
        landmarks.constellation = .constellation76Points
    }

    /// Head angles and face size need only rectangles; diagnostics also request eye landmarks.
    func detect(in sampleBuffer: CMSampleBuffer, includeEyeDetails: Bool = true) -> FacePose? {
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up, options: [:])
        guard (try? handler.perform([rectangles])) != nil,
              let face = (rectangles.results ?? []).max(by: { area($0.boundingBox) < area($1.boundingBox) })
        else { return nil }
        var pose = FacePose(box: face.boundingBox, roll: face.roll?.doubleValue,
                            yaw: face.yaw?.doubleValue, pitch: face.pitch?.doubleValue)
        guard includeEyeDetails else { return pose }

        // Landmarks for the face already found, so detection doesn't run a second time.
        landmarks.inputFaceObservations = [face]
        try? handler.perform([landmarks])
        guard let marks = landmarks.results?.first?.landmarks else { return pose }
        let pixels = CMSampleBufferGetImageBuffer(sampleBuffer)
        pose.landmarkConfidence = marks.confidence
        pose.leftEye = eye(marks.leftEye, pupil: marks.leftPupil, in: face.boundingBox, pixels: pixels)
        pose.rightEye = eye(marks.rightEye, pupil: marks.rightPupil, in: face.boundingBox, pixels: pixels)
        return pose
    }

    private func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }

    /// Landmark points come normalized to the face box; this puts them in frame coordinates.
    private func eye(_ region: VNFaceLandmarkRegion2D?, pupil: VNFaceLandmarkRegion2D?, in box: CGRect,
                     pixels: CVPixelBuffer?) -> FacePose.Eye? {
        guard let region, region.pointCount > 0 else { return nil }
        func inFrame(_ p: CGPoint) -> CGPoint {
            CGPoint(x: box.minX + p.x * box.width, y: box.minY + p.y * box.height)
        }
        let outline = region.normalizedPoints.map(inFrame)
        let center = pupil?.normalizedPoints.first.map(inFrame)
        var eye = FacePose.Eye(outline: outline, pupil: center)
        if let pixels, let bounds = eye.bounds { eye.glare = Self.glare(in: pixels, over: bounds) }
        return eye
    }

    /// Share of near-white pixels in `rect` (Vision space), padded a little so a reflection on the
    /// lens just outside the lids still counts.
    static func glare(in buffer: CVPixelBuffer, over rect: CGRect) -> Double? {
        guard !rect.isNull, !rect.isInfinite, rect.width > 0, rect.height > 0,
              [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy({ $0.isFinite }) else { return nil }
        let padded = rect.insetBy(dx: -rect.width * 0.25, dy: -rect.height * 0.5)
        let clipped = padded.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        return FramePixels.read(buffer) { pixels -> Double? in
            let x0 = max(0, Int((clipped.minX * CGFloat(pixels.width)).rounded(.down)))
            let x1 = min(pixels.width, Int((clipped.maxX * CGFloat(pixels.width)).rounded(.up)))
            // Vision's y grows upward; pixel rows grow downward.
            let y0 = max(0, Int(((1 - clipped.maxY) * CGFloat(pixels.height)).rounded(.down)))
            let y1 = min(pixels.height, Int(((1 - clipped.minY) * CGFloat(pixels.height)).rounded(.up)))
            guard x1 > x0, y1 > y0 else { return nil }
            var bright = 0
            for y in y0..<y1 {
                for x in x0..<x1 {
                    if pixels.isNearWhite(x: x, y: y) { bright += 1 }
                }
            }
            return Double(bright) / Double((x1 - x0) * (y1 - y0))
        } ?? nil
    }
}
