import AVFoundation
import XCTest
@testable import Conductor

final class CameraCaptureTests: XCTestCase {
    func testFormatPreferenceUsesSupportedYUVThenBGRA() {
        let full = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let video = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let bgra = kCVPixelFormatType_32BGRA
        XCTAssertEqual(CameraCapture.preferredPixelFormat(from: [bgra, video, full]), full)
        XCTAssertEqual(CameraCapture.preferredPixelFormat(from: [bgra, video]), video)
        XCTAssertEqual(CameraCapture.preferredPixelFormat(from: [bgra]), bgra)
        XCTAssertNil(CameraCapture.preferredPixelFormat(from: [kCVPixelFormatType_OneComponent8]))
    }

    func testBenchmarkOverrideRequiresSupportedBGRA() {
        let full = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let bgra = kCVPixelFormatType_32BGRA
        XCTAssertEqual(CameraCapture.preferredPixelFormat(from: [full, bgra], useBGRAForBenchmark: true), bgra)
        XCTAssertNil(CameraCapture.preferredPixelFormat(from: [full], useBGRAForBenchmark: true))
    }

    func testDropCallbackIncludesSampleTimingAndReason() throws {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixelBuffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(pixelBuffer)
        var description: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels,
                                                                  formatDescriptionOut: &description), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                       presentationTimeStamp: CMTime(value: 42, timescale: 30),
                                       decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels,
            formatDescription: try XCTUnwrap(description), sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer), noErr)
        let sample = try XCTUnwrap(sampleBuffer)
        CMSetAttachment(sample, key: kCMSampleBufferAttachmentKey_DroppedFrameReason,
                        value: kCMSampleBufferDroppedFrameReason_FrameWasLate,
                        attachmentMode: kCMAttachmentMode_ShouldNotPropagate)
        let camera = CameraCapture(useBGRAForBenchmark: false)
        let output = AVCaptureVideoDataOutput()
        let connection = AVCaptureConnection(inputPorts: [], output: output)
        var calls = 0
        camera.onDroppedFrame = { dropped, reason in
            calls += 1
            XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(dropped), timing.presentationTimeStamp)
            XCTAssertEqual(reason, kCMSampleBufferDroppedFrameReason_FrameWasLate as String)
        }
        camera.captureOutput(output, didDrop: sample, from: connection)
        XCTAssertEqual(calls, 1)

        CMRemoveAttachment(sample, key: kCMSampleBufferAttachmentKey_DroppedFrameReason)
        camera.onDroppedFrame = { _, reason in
            calls += 1
            XCTAssertNil(reason)
        }
        camera.captureOutput(output, didDrop: sample, from: connection)
        XCTAssertEqual(calls, 2)
    }
}
