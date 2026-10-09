import XCTest
import CoreVideo
@testable import Conductor

final class PixelAnalysisTests: XCTestCase {
    private let fullFrame = CGRect(x: 0, y: 0, width: 1, height: 1)

    func testBGRARowPaddingDoesNotAffectBrightnessOrGlare() throws {
        let frame = try makeBGRA { _, _ in (100, 100, 100) }
        XCTAssertGreaterThan(CVPixelBufferGetBytesPerRow(frame), 10 * 4)
        XCTAssertEqual(try XCTUnwrap(TrackingQuality.meanLuma(of: frame)), 100, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(FaceTracker.glare(in: frame, over: fullFrame)), 0)
    }

    func testFullRangeYUVReadsPaddedLumaAndChromaRows() throws {
        let frame = try makeYUV(format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, luma: 245)
        XCTAssertGreaterThan(CVPixelBufferGetBytesPerRowOfPlane(frame, 0), 10)
        XCTAssertGreaterThan(CVPixelBufferGetBytesPerRowOfPlane(frame, 1), 10)
        XCTAssertEqual(try XCTUnwrap(TrackingQuality.meanLuma(of: frame)), 245)
        XCTAssertEqual(try XCTUnwrap(FaceTracker.glare(in: frame, over: fullFrame)), 1)
    }

    func testVideoRangeLumaNormalizesAndClampsToFullRange() throws {
        for (sample, expected) in [(UInt8(0), 0.0), (16, 0), (102, 86.0 * 255 / 219),
                                   (235, 255), (255, 255)] {
            let frame = try makeYUV(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, luma: sample)
            XCTAssertEqual(try XCTUnwrap(TrackingQuality.meanLuma(of: frame)), expected, accuracy: 0.001)
        }
    }

    func testVideoRangeUsesTheExistingDarknessThreshold() throws {
        for (sample, isDark) in [(UInt8(54), true), (55, false)] {
            let frame = try makeYUV(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, luma: sample)
            var quality = TrackingQuality()
            quality.addBrightness(try XCTUnwrap(TrackingQuality.meanLuma(of: frame)))
            XCTAssertEqual(quality.warning != nil, isDark)
        }
    }

    func testNearWhiteRequiresBrightNeutralChromaInBothRanges() throws {
        for format in [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                       kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] {
            let whiteLuma: UInt8 = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? 240 : 223
            for (luma, cb, cr, expected) in [(whiteLuma, UInt8(128), UInt8(128), 1.0),
                                            (whiteLuma - 1, 128, 128, 0),
                                            (whiteLuma, 180, 128, 0),
                                            (whiteLuma, 128, 180, 0)] {
                let frame = try makeYUV(format: format, luma: luma, cb: cb, cr: cr)
                XCTAssertEqual(try XCTUnwrap(FaceTracker.glare(in: frame, over: fullFrame)), expected)
            }
        }
    }

    func testVideoRangeChromaToleranceIsNormalized() throws {
        let full = try makeYUV(format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, luma: 255, cb: 136)
        let video = try makeYUV(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, luma: 235, cb: 135)
        let coloredVideo = try makeYUV(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, luma: 235, cb: 136)
        XCTAssertEqual(try XCTUnwrap(FaceTracker.glare(in: full, over: fullFrame)), 1)
        XCTAssertEqual(try XCTUnwrap(FaceTracker.glare(in: video, over: fullFrame)), 1)
        XCTAssertEqual(try XCTUnwrap(FaceTracker.glare(in: coloredVideo, over: fullFrame)), 0)
    }

    func testYUVGlareUsesSubsampledChromaAndVisionYCoordinates() throws {
        let frame = try makeYUV(format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, luma: 255)
        CVPixelBufferLockBaseAddress(frame, [])
        let chroma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(frame, 1)).assumingMemoryBound(to: UInt8.self)
        for x in 0..<5 { chroma[x * 2] = 180 }
        CVPixelBufferUnlockBaseAddress(frame, [])
        XCTAssertEqual(try XCTUnwrap(FaceTracker.glare(in: frame, over: fullFrame)), 2.0 / 3)
        XCTAssertEqual(try XCTUnwrap(FaceTracker.glare(in: frame,
            over: CGRect(x: 0, y: 0.9, width: 1, height: 0.1))), 0)
        XCTAssertEqual(try XCTUnwrap(FaceTracker.glare(in: frame,
            over: CGRect(x: 0, y: 0, width: 1, height: 0.1))), 1)
    }

    func testBGRAGlareKeepsAllThreeColorThresholds() throws {
        let white = try makeBGRA { _, _ in (240, 240, 240) }
        let yellow = try makeBGRA { _, _ in (0, 255, 255) }
        let almost = try makeBGRA { _, _ in (239, 255, 255) }
        XCTAssertEqual(try XCTUnwrap(FaceTracker.glare(in: white, over: fullFrame)), 1)
        XCTAssertEqual(try XCTUnwrap(FaceTracker.glare(in: yellow, over: fullFrame)), 0)
        XCTAssertEqual(try XCTUnwrap(FaceTracker.glare(in: almost, over: fullFrame)), 0)
    }

    func testGlareClipsPaddedBoundsAndUsesVisionYCoordinates() throws {
        let frame = try makeBGRA { _, y in y < 3 ? (255, 255, 255) : (0, 0, 0) }
        XCTAssertEqual(try XCTUnwrap(FaceTracker.glare(in: frame,
            over: CGRect(x: -0.2, y: 0.8, width: 0.4, height: 0.2))), 1)
        XCTAssertEqual(try XCTUnwrap(FaceTracker.glare(in: frame,
            over: CGRect(x: 0.8, y: -0.1, width: 0.4, height: 0.2))), 0)
        XCTAssertEqual(try XCTUnwrap(FaceTracker.glare(in: frame, over: fullFrame)), 0.5)
        XCTAssertNil(FaceTracker.glare(in: frame, over: CGRect(x: 2, y: 2, width: 0.1, height: 0.1)))
        XCTAssertNil(FaceTracker.glare(in: frame, over: .zero))
        XCTAssertNil(FaceTracker.glare(in: frame, over: .infinite))
        XCTAssertNil(FaceTracker.glare(in: frame, over: CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)))
    }

    func testUnsupportedFormatIsIgnored() throws {
        let frame = try makeBuffer(format: kCVPixelFormatType_OneComponent8)
        XCTAssertNil(TrackingQuality.meanLuma(of: frame))
        XCTAssertNil(FaceTracker.glare(in: frame, over: fullFrame))
    }

    private func makeBuffer(format: OSType) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferBytesPerRowAlignmentKey: 64] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(nil, 10, 6, format, attributes, &buffer), kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }

    private func makeBGRA(pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> CVPixelBuffer {
        let buffer = try makeBuffer(format: kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        memset(base, 255, rowBytes * 6)
        for y in 0..<6 {
            for x in 0..<10 {
                let color = pixel(x, y)
                let p = base + y * rowBytes + x * 4
                p[0] = color.0; p[1] = color.1; p[2] = color.2; p[3] = 255
            }
        }
        return buffer
    }

    private func makeYUV(format: OSType, luma: UInt8, cb: UInt8 = 128, cr: UInt8 = 128) throws -> CVPixelBuffer {
        let buffer = try makeBuffer(format: format)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<2 {
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, plane)).assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
            let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
            memset(base, 0, rowBytes * height)
            for y in 0..<height {
                for x in 0..<width {
                    if plane == 0 { base[y * rowBytes + x] = luma }
                    else {
                        base[y * rowBytes + x * 2] = cb
                        base[y * rowBytes + x * 2 + 1] = cr
                    }
                }
            }
        }
        return buffer
    }
}
