import CoreVideo

/// Locked access to luma and near-white samples in supported camera formats.
struct FramePixels {
    let width: Int
    let height: Int

    private enum Storage {
        case bgra(UnsafePointer<UInt8>, rowBytes: Int)
        case yuv(UnsafePointer<UInt8>, rowBytes: Int, chroma: UnsafePointer<UInt8>,
                 chromaRowBytes: Int, videoRange: Bool)
    }
    private let storage: Storage

    static func read<Result>(_ buffer: CVPixelBuffer, _ body: (FramePixels) -> Result) -> Result? {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let pixels = FramePixels(buffer) else { return nil }
        return body(pixels)
    }

    private init?(_ buffer: CVPixelBuffer) {
        width = CVPixelBufferGetWidth(buffer)
        height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else { return nil }
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_32BGRA:
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            guard rowBytes >= width * 4, let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            storage = .bgra(UnsafePointer(base.assumingMemoryBound(to: UInt8.self)), rowBytes: rowBytes)
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            guard CVPixelBufferGetPlaneCount(buffer) == 2,
                  CVPixelBufferGetWidthOfPlane(buffer, 0) >= width,
                  CVPixelBufferGetHeightOfPlane(buffer, 0) >= height,
                  CVPixelBufferGetWidthOfPlane(buffer, 1) >= (width + 1) / 2,
                  CVPixelBufferGetHeightOfPlane(buffer, 1) >= (height + 1) / 2,
                  let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
                  let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let chromaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            guard rowBytes >= width, chromaRowBytes >= ((width + 1) / 2) * 2 else { return nil }
            storage = .yuv(UnsafePointer(luma.assumingMemoryBound(to: UInt8.self)), rowBytes: rowBytes,
                           chroma: UnsafePointer(chroma.assumingMemoryBound(to: UInt8.self)),
                           chromaRowBytes: chromaRowBytes,
                           videoRange: CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        default: return nil
        }
    }

    func luma(x: Int, y: Int) -> Double {
        switch storage {
        case let .bgra(base, rowBytes):
            let p = base + y * rowBytes + x * 4
            return 0.114 * Double(p[0]) + 0.587 * Double(p[1]) + 0.299 * Double(p[2])
        case let .yuv(base, rowBytes, _, _, videoRange):
            let value = Double(base[y * rowBytes + x])
            return videoRange ? min(255, max(0, (value - 16) * 255 / 219)) : value
        }
    }

    func isNearWhite(x: Int, y: Int) -> Bool {
        switch storage {
        case let .bgra(base, rowBytes):
            let p = base + y * rowBytes + x * 4
            return p[0] >= 240 && p[1] >= 240 && p[2] >= 240
        case let .yuv(base, rowBytes, chroma, chromaRowBytes, videoRange):
            // These byte cutoffs equal normalized luma >= 240 and chroma offsets <= 8.
            guard base[y * rowBytes + x] >= (videoRange ? 223 : 240) else { return false }
            let p = chroma + (y / 2) * chromaRowBytes + (x / 2) * 2
            let tolerance = videoRange ? 7 : 8
            // Luma alone would count bright saturated colors as white reflections.
            return abs(Int(p[0]) - 128) <= tolerance && abs(Int(p[1]) - 128) <= tolerance
        }
    }
}
