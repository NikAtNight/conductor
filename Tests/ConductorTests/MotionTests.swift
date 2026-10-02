import XCTest
@testable import Conductor

final class SwipeTests: XCTestCase {
    let dt = 1.0 / 30
    let back = Shortcut(keyCode: 33, modifiers: CGEventFlags.maskCommand.rawValue)
    let forward = Shortcut(keyCode: 30, modifiers: CGEventFlags.maskCommand.rawValue)

    func testPoseDetection() {
        XCTAssertTrue(PoseFixtures.twoFingers().isTwoFingerPose)
        XCTAssertFalse(PoseFixtures.openHand().isTwoFingerPose)
        XCTAssertFalse(PoseFixtures.fist().isTwoFingerPose)
    }

    /// Moves the two-finger hand from x0 to x1 (Vision space) over `duration` and collects actions.
    private func swipe(from x0: CGFloat, to x1: CGFloat, duration: TimeInterval,
                       recognizer r: inout GestureRecognizer) -> [GestureRecognizer.Action] {
        var actions: [GestureRecognizer.Action] = []
        let steps = Int(duration / dt)
        for i in 0...steps {
            let x = x0 + (x1 - x0) * CGFloat(i) / CGFloat(steps)
            let out = r.update(hands: [PoseFixtures.twoFingers(at: CGPoint(x: x, y: 0.3))], at: Double(i) * dt)
            XCTAssertNil(out.pointer, "cursor holds still in the two-finger pose")
            actions += out.actions
        }
        return actions
    }

    func testQuickFlickToTheUsersRightGoesBackOnce() {
        var r = GestureRecognizer()
        // Mirrored: the user's right is Vision's smaller x.
        XCTAssertEqual(swipe(from: 0.6, to: 0.35, duration: 0.2, recognizer: &r), [.shortcut(back)])
    }

    func testQuickFlickToTheUsersLeftGoesForward() {
        var r = GestureRecognizer()
        XCTAssertEqual(swipe(from: 0.35, to: 0.6, duration: 0.2, recognizer: &r), [.shortcut(forward)])
    }

    func testSlowDriftIsNotASwipe() {
        var r = GestureRecognizer()
        XCTAssertEqual(swipe(from: 0.35, to: 0.6, duration: 2.0, recognizer: &r), [])
    }

    func testUnboundSwipesLeaveThePoseAlone() {
        var map = GestureMap.standard
        map[.swipeLeft] = .none
        map[.swipeRight] = .none
        var r = GestureRecognizer(map: map)
        XCTAssertNotNil(r.update(hands: [PoseFixtures.twoFingers()], at: 0).pointer)
    }

    func testSavedMapsFromBeforeSwipesGetTheDefaults() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "SwipeTests.\(UUID())"))
        var old = GestureMap.standard
        old.bindings[.swipeLeft] = nil
        old.bindings[.swipeRight] = nil
        old[.ringPinch] = .middleClick
        old.save(to: suite)
        let loaded = GestureMap.load(from: suite)
        XCTAssertEqual(loaded[.swipeRight], .shortcut(back))
        XCTAssertEqual(loaded[.ringPinch], .middleClick, "existing choices survive")
    }
}

final class RelativePointerTests: XCTestCase {
    func testFirstSampleHasNoDelta() {
        var p = RelativePointer()
        XCTAssertNil(p.delta(for: CGPoint(x: 0.5, y: 0.5), at: 0, screenWidth: 1000))
    }

    func testFastMovesTravelFartherPerUnitOfHandMotion() {
        var slow = RelativePointer()
        _ = slow.delta(for: CGPoint(x: 0.5, y: 0.5), at: 0, screenWidth: 1000)
        let s = slow.delta(for: CGPoint(x: 0.49, y: 0.5), at: 0.5, screenWidth: 1000)!   // 0.02 /s
        var fast = RelativePointer()
        _ = fast.delta(for: CGPoint(x: 0.5, y: 0.5), at: 0, screenWidth: 1000)
        let f = fast.delta(for: CGPoint(x: 0.49, y: 0.5), at: 0.005, screenWidth: 1000)! // 2 /s
        XCTAssertGreaterThan(abs(f.dx), abs(s.dx) * 3)
    }

    func testMirroredDirectionsMatchTheAbsoluteMapping() {
        var p = RelativePointer()
        _ = p.delta(for: CGPoint(x: 0.5, y: 0.5), at: 0, screenWidth: 1000)
        // Vision x down = user's right when mirrored; Vision y up = screen up (negative dy).
        let d = p.delta(for: CGPoint(x: 0.45, y: 0.55), at: 0.1, screenWidth: 1000)!
        XCTAssertGreaterThan(d.dx, 0)
        XCTAssertLessThan(d.dy, 0)
    }
}

final class MomentumScrollerTests: XCTestCase {
    func testAFlickCoastsAndSlowsToAStop() {
        var m = MomentumScroller()
        for _ in 0..<4 { m.scrolled(-40) }
        m.released()
        var steps: [CGFloat] = []
        while let step = m.tick() { steps.append(step) }
        XCTAssertEqual(steps.first, -40)
        XCTAssertTrue(zip(steps, steps.dropFirst()).allSatisfy { abs($1) < abs($0) }, "always slowing")
        XCTAssertGreaterThan(steps.count, 10)
        XCTAssertLessThan(steps.count, 60)
    }

    func testAGentleScrollDoesNotCoast() {
        var m = MomentumScroller()
        for _ in 0..<4 { m.scrolled(3) }
        m.released()
        XCTAssertNil(m.tick())
    }

    func testStopEndsCoasting() {
        var m = MomentumScroller()
        for _ in 0..<4 { m.scrolled(30) }
        m.released()
        _ = m.tick()
        m.stop()
        XCTAssertNil(m.tick())
    }
}
