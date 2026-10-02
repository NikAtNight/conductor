import XCTest
import CoreVideo
@testable import Conductor

final class TrackingQualityTests: XCTestCase {
    func testSustainedDarknessWarnsAndLightClearsIt() {
        var q = TrackingQuality()
        XCTAssertNil(q.warning)
        for _ in 0..<10 { q.addBrightness(20) }
        XCTAssertNotNil(q.warning)
        XCTAssertTrue(q.warning!.contains("dark"))
        for _ in 0..<10 { q.addBrightness(140) }
        XCTAssertNil(q.warning)
    }

    func testOneDarkFrameAfterGoodLightDoesNotWarn() {
        var q = TrackingQuality()
        for _ in 0..<10 { q.addBrightness(140) }
        q.addBrightness(5)
        XCTAssertNil(q.warning)
    }

    func testLowConfidenceWarnsAndLosingTheHandForgetsIt() {
        var q = TrackingQuality()
        for _ in 0..<90 { q.addConfidence(0.2) }
        XCTAssertTrue(q.warning?.contains("unsure") == true)
        q.handLost()
        XCTAssertNil(q.warning)
    }

    func testMeanLumaOfAFlatGreyFrame() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 48, kCVPixelFormatType_32BGRA, nil, &buffer)
        let frame = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(frame, [])
        memset(CVPixelBufferGetBaseAddress(frame), 100, CVPixelBufferGetBytesPerRow(frame) * 48)
        CVPixelBufferUnlockBaseAddress(frame, [])
        XCTAssertEqual(try XCTUnwrap(TrackingQuality.meanLuma(of: frame)), 100, accuracy: 0.5)
    }
}
