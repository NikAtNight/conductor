import XCTest
@testable import Conductor

/// The cursor moves between the pipeline's 30 fps targets instead of jumping to each one.
final class CursorGlideTests: XCTestCase {
    let tick = 1 / CursorGlide.rate
    let frame = 1.0 / 30

    /// Positions reported from `start` until the glide ends, at the Engine's rate.
    private func run(_ glide: inout CursorGlide, from start: TimeInterval) -> [CGPoint] {
        var points: [CGPoint] = []
        var t = start
        while let p = glide.position(at: t) {
            points.append(p)
            t += tick
        }
        return points
    }

    func testTheCursorGlidesToTheTargetOverOneFrame() {
        var g = CursorGlide()
        g.aim(at: CGPoint(x: 100, y: 0), from: .zero, at: 0)
        g.aim(at: CGPoint(x: 200, y: 0), from: CGPoint(x: 100, y: 0), at: frame)
        let points = run(&g, from: frame + tick)
        XCTAssertEqual(points.count, 4, "four ticks of 120 Hz fit in a 30 fps frame")
        XCTAssertTrue(zip(points, points.dropFirst()).allSatisfy { $1.x > $0.x }, "always moving forward: \(points)")
        XCTAssertEqual(points.last, CGPoint(x: 200, y: 0), "lands exactly on the target")
        XCTAssertEqual(points[0].x, 125, accuracy: 0.01)
        XCTAssertFalse(g.isGliding)
        XCTAssertNil(g.position(at: 1), "nothing more to post once it has arrived")
    }

    func testANewTargetMidGlideCarriesOnFromWhereTheCursorIs() {
        var g = CursorGlide()
        g.aim(at: CGPoint(x: 100, y: 0), from: .zero, at: 0)
        g.aim(at: CGPoint(x: 200, y: 0), from: CGPoint(x: 100, y: 0), at: frame)
        let midway = g.position(at: frame + 2 * tick)!
        XCTAssertEqual(midway.x, 150, accuracy: 0.01)
        // The camera is early with the next target. No jump: the glide restarts from midway.
        g.aim(at: CGPoint(x: 300, y: 0), from: midway, at: frame + 2 * tick)
        let next = g.position(at: frame + 3 * tick)!
        XCTAssertGreaterThan(next.x, 150)
        XCTAssertLessThan(next.x, 300)
    }

    func testAGlideTakesAsLongAsTheGapBetweenTargets() {
        var g = CursorGlide()
        g.aim(at: .zero, from: .zero, at: 0)
        g.aim(at: CGPoint(x: 100, y: 0), from: .zero, at: 1.0 / 60)
        XCTAssertEqual(run(&g, from: 1.0 / 60 + tick).count, 2, "a 60 fps camera gets two ticks per frame")
    }

    func testALongGapDoesNotBecomeASlowDrift() {
        var g = CursorGlide()
        g.aim(at: .zero, from: .zero, at: 0)
        // The hand was gone for two seconds. The cursor reaches the new spot within a tenth of a second.
        g.aim(at: CGPoint(x: 1000, y: 0), from: .zero, at: 2)
        XCTAssertEqual(g.position(at: 2.09)!.x, 900, accuracy: 0.01)
        XCTAssertEqual(g.position(at: 2.1 + tick), CGPoint(x: 1000, y: 0), "the tick that gets there posts the target")
        XCTAssertNil(g.position(at: 2.2))
        // And the very first target after a start takes a normal frame.
        var fresh = CursorGlide()
        fresh.aim(at: CGPoint(x: 100, y: 0), from: .zero, at: 5)
        XCTAssertEqual(run(&fresh, from: 5 + tick).count, 4)
    }

    func testStopLeavesTheCursorWhereItIs() {
        var g = CursorGlide()
        g.aim(at: CGPoint(x: 100, y: 100), from: .zero, at: 0)
        g.stop()
        XCTAssertFalse(g.isGliding)
        XCTAssertNil(g.position(at: tick))
    }
}
