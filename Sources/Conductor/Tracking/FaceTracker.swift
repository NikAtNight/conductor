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

    func detect(in sampleBuffer: CMSampleBuffer) -> FacePose? {
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up, options: [:])
        guard (try? handler.perform([rectangles])) != nil,
              let face = (rectangles.results ?? []).max(by: { area($0.boundingBox) < area($1.boundingBox) })
        else { return nil }
        var pose = FacePose(box: face.boundingBox, roll: face.roll?.doubleValue,
                            yaw: face.yaw?.doubleValue, pitch: face.pitch?.doubleValue)

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
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)

        let padded = rect.insetBy(dx: -rect.width * 0.25, dy: -rect.height * 0.5)
        let x0 = max(0, Int(padded.minX * CGFloat(width)))
        let x1 = min(width, Int((padded.maxX * CGFloat(width)).rounded(.up)))
        // Vision's y grows upward; pixel rows grow downward.
        let y0 = max(0, Int((1 - padded.maxY) * CGFloat(height)))
        let y1 = min(height, Int(((1 - padded.minY) * CGFloat(height)).rounded(.up)))
        guard x1 > x0, y1 > y0 else { return nil }
        var bright = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let p = pixels + y * rowBytes + x * 4
                if p[0] >= 240, p[1] >= 240, p[2] >= 240 { bright += 1 }
            }
        }
        return Double(bright) / Double((x1 - x0) * (y1 - y0))
    }
}
