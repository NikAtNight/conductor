import XCTest
@testable import Conductor

enum FaceFixtures {
    /// An eye opening 0.10 wide and 0.04 tall with its lower-left corner at `origin`.
    static func eye(at origin: CGPoint = CGPoint(x: 0.40, y: 0.50), pupil: CGPoint? = nil) -> FacePose.Eye {
        let outline = [
            CGPoint(x: origin.x, y: origin.y + 0.02),           // inner corner
            CGPoint(x: origin.x + 0.03, y: origin.y + 0.04),    // upper lid
            CGPoint(x: origin.x + 0.07, y: origin.y + 0.04),
            CGPoint(x: origin.x + 0.10, y: origin.y + 0.02),    // outer corner
            CGPoint(x: origin.x + 0.07, y: origin.y),           // lower lid
            CGPoint(x: origin.x + 0.03, y: origin.y),
        ]
        return FacePose.Eye(outline: outline, pupil: pupil)
    }

    static func face(pitchDegrees: Double, yawDegrees: Double = 0, faceHeight: Double = 0.4) -> FacePose {
        FacePose(box: CGRect(x: 0.3, y: 0.4, width: 0.3, height: faceHeight), roll: 0,
                 yaw: yawDegrees * .pi / 180,
                 pitch: pitchDegrees * .pi / 180,
                 leftEye: eye(pupil: CGPoint(x: 0.45, y: 0.53)), rightEye: eye(at: CGPoint(x: 0.55, y: 0.50)),
                 landmarkConfidence: 0.9)
    }
}

final class FacePoseTests: XCTestCase {
    func testAPupilInTheMiddleOfTheOpeningIsZeroGaze() throws {
        let eye = FaceFixtures.eye(pupil: CGPoint(x: 0.45, y: 0.52))
        let gaze = try XCTUnwrap(eye.gaze)
        XCTAssertEqual(gaze.dx, 0, accuracy: 1e-9)
        XCTAssertEqual(gaze.dy, 0, accuracy: 1e-9)
    }

    func testGazeIsPlusOneAtTheUpperLidAndOuterCorner() throws {
        let eye = FaceFixtures.eye(pupil: CGPoint(x: 0.50, y: 0.54))
        let gaze = try XCTUnwrap(eye.gaze)
        XCTAssertEqual(gaze.dx, 1, accuracy: 1e-9)
        XCTAssertEqual(gaze.dy, 1, accuracy: 1e-9)
    }

    func testOpennessIsHeightOverWidth() throws {
        XCTAssertEqual(try XCTUnwrap(FaceFixtures.eye().openness), 0.4, accuracy: 1e-9)
    }

    func testNoPupilOrNoOutlineMeansNoGaze() {
        XCTAssertNil(FaceFixtures.eye().gaze)
        XCTAssertNil(FacePose.Eye(outline: [], pupil: CGPoint(x: 0.5, y: 0.5)).gaze)
        XCTAssertNil(FacePose.Eye(outline: [], pupil: nil).openness)
    }
}
