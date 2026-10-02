import XCTest
@testable import Conductor

final class ScreenMapperTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 500)

    func testCenterMapsToCenter() {
        let mapper = ScreenMapper(boxOffsetY: 0, screen: screen)
        let p = mapper.map(CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(p.x, 500, accuracy: 0.01)
        XCTAssertEqual(p.y, 250, accuracy: 0.01)
    }

    func testMirroringFlipsX() {
        let mirrored = ScreenMapper(boxWidth: 1, boxHeight: 1, boxOffsetY: 0, mirrored: true, screen: screen)
        let plain = ScreenMapper(boxWidth: 1, boxHeight: 1, boxOffsetY: 0, mirrored: false, screen: screen)
        // Hand on the frame's left (vision x = 0.2) is the user's right when mirrored.
        XCTAssertEqual(mirrored.map(CGPoint(x: 0.2, y: 0.5)).x, 800, accuracy: 0.01)
        XCTAssertEqual(plain.map(CGPoint(x: 0.2, y: 0.5)).x, 200, accuracy: 0.01)
    }

    func testVisionBottomLeftBecomesScreenBottomLeftWhenMirrored() {
        let mapper = ScreenMapper(boxWidth: 1, boxHeight: 1, boxOffsetY: 0, mirrored: false, screen: screen)
        let p = mapper.map(CGPoint(x: 0, y: 0))
        XCTAssertEqual(p.x, 0, accuracy: 0.01)
        XCTAssertEqual(p.y, 500, accuracy: 0.01)
    }

    func testControlBoxEdgesReachScreenEdgesAndClamp() {
        let mapper = ScreenMapper(boxWidth: 0.5, boxHeight: 0.5, boxOffsetY: 0, mirrored: false, screen: screen)
        XCTAssertEqual(mapper.map(CGPoint(x: 0.25, y: 0.75)).x, 0, accuracy: 0.01)
        XCTAssertEqual(mapper.map(CGPoint(x: 0.75, y: 0.75)).x, 1000, accuracy: 0.01)
        XCTAssertEqual(mapper.map(CGPoint(x: 0.75, y: 0.75)).y, 0, accuracy: 0.01)
        XCTAssertEqual(mapper.map(CGPoint(x: 0.05, y: 0.95)), CGPoint(x: 0, y: 0))
        XCTAssertEqual(mapper.map(CGPoint(x: 0.95, y: 0.05)), CGPoint(x: 1000, y: 500))
    }

    func testOffsetMovesBoxUp() {
        let mapper = ScreenMapper(boxWidth: 1, boxHeight: 0.5, boxOffsetY: 0.1, mirrored: false, screen: screen)
        // Box center is now at vision y = 0.6 instead of 0.5.
        XCTAssertEqual(mapper.map(CGPoint(x: 0.5, y: 0.6)).y, 250, accuracy: 0.01)
    }
}

final class OneEuroFilterTests: XCTestCase {
    func testFirstSamplePassesThrough() {
        var f = OneEuroFilter()
        XCTAssertEqual(f.filter(42, at: 0), 42)
    }

    func testJitterIsDamped() {
        var f = OneEuroFilter(minCutoff: 1, beta: 0)
        var t = 0.0
        var outputs: [Double] = []
        for i in 0..<60 {
            t += 1.0 / 30
            let noisy = 100 + (i % 2 == 0 ? 2.0 : -2.0)
            outputs.append(f.filter(noisy, at: t))
        }
        let swing = outputs.suffix(10).max()! - outputs.suffix(10).min()!
        XCTAssertLessThan(swing, 1.5, "raw swing is 4, filtered should be well under that")
    }

    func testFastMotionTracksCloselyWithBeta() {
        var slow = OneEuroFilter(minCutoff: 1, beta: 0)
        var adaptive = OneEuroFilter(minCutoff: 1, beta: 0.5)
        var t = 0.0
        var lagSlow = 0.0, lagAdaptive = 0.0
        for i in 0..<30 {
            t += 1.0 / 30
            let truth = Double(i) * 20
            lagSlow = truth - slow.filter(truth, at: t)
            lagAdaptive = truth - adaptive.filter(truth, at: t)
        }
        XCTAssertLessThan(lagAdaptive, lagSlow)
    }
}
