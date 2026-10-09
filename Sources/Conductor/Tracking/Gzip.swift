import Foundation
import zlib

/// Gzip for the log upload. Streams file to file, so an hour-long recording (a few hundred
/// megabytes) is never read into memory at once.
enum Gzip {
    struct Failure: Error, CustomStringConvertible {
        var step: String
        var code: Int32
        var description: String { "gzip \(step) failed with zlib code \(code)" }
    }

    private static let chunk = 1 << 20

    static func compress(_ source: URL, to destination: URL, isCancelled: () -> Bool = { false }) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        var stream = z_stream()
        // 15 window bits plus 16 asks zlib for the gzip wrapper instead of a bare zlib one.
        let status = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY,
                                   ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw Failure(step: "init", code: status) }
        defer { deflateEnd(&stream) }

        var out = [UInt8](repeating: 0, count: chunk)
        var finished = false
        while !finished {
            if isCancelled() { throw CancellationError() }
            var data = try input.read(upToCount: chunk) ?? Data()
            let flush = data.isEmpty ? Z_FINISH : Z_NO_FLUSH
            try data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
                stream.next_in = bytes.baseAddress?.assumingMemoryBound(to: Bytef.self)
                stream.avail_in = UInt32(bytes.count)
                repeat {
                    let produced = try out.withUnsafeMutableBufferPointer { buffer -> Int in
                        stream.next_out = buffer.baseAddress
                        stream.avail_out = UInt32(buffer.count)
                        let result = deflate(&stream, flush)
                        guard result == Z_OK || result == Z_STREAM_END || result == Z_BUF_ERROR else {
                            throw Failure(step: "deflate", code: result)
                        }
                        finished = result == Z_STREAM_END
                        return buffer.count - Int(stream.avail_out)
                    }
                    if produced > 0 { try output.write(contentsOf: Data(out[0..<produced])) }
                } while stream.avail_out == 0
            }
        }
    }
}
