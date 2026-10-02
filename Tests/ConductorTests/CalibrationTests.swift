import XCTest
@testable import Conductor

final class CalibrationTests: XCTestCase {
    /// Points around the edge of a rectangle, like a hand tracing its reach.
    private func trace(_ rect: CGRect, count: Int = 120) -> [CGPoint] {
        (0..<count).map { i in
            let t = CGFloat(i) / CGFloat(count) * 4
            switch Int(t) {
            case 0: return CGPoint(x: rect.minX + rect.width * (t - 0), y: rect.minY)
            case 1: return CGPoint(x: rect.maxX, y: rect.minY + rect.height * (t - 1))
            case 2: return CGPoint(x: rect.maxX - rect.width * (t - 2), y: rect.maxY)
            default: return CGPoint(x: rect.minX, y: rect.maxY - rect.height * (t - 3))
            }
        }
    }

    func testTracedRectangleBecomesTheBox() throws {
        let reach = CGRect(x: 0.3, y: 0.25, width: 0.4, height: 0.35)
        let box = try XCTUnwrap(Calibration.box(from: trace(reach)))
        XCTAssertEqual(box.minX, reach.minX + 0.01, accuracy: 0.02)
        XCTAssertEqual(box.maxX, reach.maxX - 0.01, accuracy: 0.02)
        XCTAssertEqual(box.minY, reach.minY + 0.01, accuracy: 0.02)
        XCTAssertEqual(box.maxY, reach.maxY - 0.01, accuracy: 0.02)
    }

    func testAFewWildFramesDoNotStretchTheBox() throws {
        let reach = CGRect(x: 0.3, y: 0.25, width: 0.4, height: 0.35)
        let points = trace(reach) + [CGPoint(x: 0.99, y: 0.99), CGPoint(x: 0.01, y: 0.01)]
        let box = try XCTUnwrap(Calibration.box(from: points))
        XCTAssertLessThan(box.maxX, 0.75)
        XCTAssertGreaterThan(box.minX, 0.25)
    }

    func testTooFewSamplesOrTooLittleMovementFails() {
        XCTAssertNil(Calibration.box(from: Array(repeating: CGPoint(x: 0.5, y: 0.5), count: 10)))
        XCTAssertNil(Calibration.box(from: trace(CGRect(x: 0.5, y: 0.5, width: 0.05, height: 0.05))))
    }
}
