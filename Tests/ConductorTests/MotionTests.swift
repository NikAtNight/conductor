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

    /// Two fingers also scroll by palm travel. These moves are level, so the deltas are all zero;
    /// drop them to look at the swipes alone.
    private func withoutScroll(_ actions: [GestureRecognizer.Action]) -> [GestureRecognizer.Action] {
        actions.filter { if case .scroll = $0 { return false } else { return true } }
    }

    /// Moves the two-finger hand from x0 to x1 (Vision space) over `duration` and collects actions.
    private func swipe(from x0: CGFloat, to x1: CGFloat, duration: TimeInterval,
                       recognizer r: inout GestureRecognizer) -> [GestureRecognizer.Action] {
        var actions: [GestureRecognizer.Action] = []
        let steps = Int(duration / dt)
        for i in 0...steps {
            let x = x0 + (x1 - x0) * CGFloat(i) / CGFloat(steps)
            let out = r.update(hands: [PoseFixtures.twoFingers(at: CGPoint(x: x, y: 0.3))], at: Double(i) * dt)
            if i >= GestureRecognizer.poseFrames - 1 {
                XCTAssertNil(out.pointer, "cursor holds still once the two-finger pose is held")
            }
            actions += withoutScroll(out.actions)
        }
        return actions
    }

    func testQuickFlickToTheUsersRightGoesBackOnce() {
        var r = GestureRecognizer(config: .instant)
        // Mirrored: the user's right is Vision's smaller x.
        XCTAssertEqual(swipe(from: 0.6, to: 0.35, duration: 0.2, recognizer: &r), [.shortcut(back)])
    }

    func testQuickFlickToTheUsersLeftGoesForward() {
        var r = GestureRecognizer(config: .instant)
        XCTAssertEqual(swipe(from: 0.35, to: 0.6, duration: 0.2, recognizer: &r), [.shortcut(forward)])
    }

    func testAWristFlickOfSixHundredthsSwipes() {
        var r = GestureRecognizer(config: .instant)
        // Nikhil's flicks measured 0.04 to 0.066 of the frame in about 0.2 s, from a pose already
        // held. At 0.12 none ever fired.
        var actions: [GestureRecognizer.Action] = []
        var t = 0.0
        func frame(_ x: CGFloat) { actions += withoutScroll(r.update(hands: [PoseFixtures.twoFingers(at: CGPoint(x: x, y: 0.3))], at: t).actions); t += dt }
        for _ in 0..<10 { frame(0.5) }
        for i in 1...6 { frame(0.5 - 0.01 * CGFloat(i)) }
        XCTAssertEqual(actions, [.shortcut(back)])
    }

    func testAShortHorizontalFlickSwipesButVerticalTravelDoesNot() {
        for direction: CGFloat in [-1, 1] {
            var r = GestureRecognizer(config: .instant)
            XCTAssertEqual(swipe(from: 0.5, to: 0.5 + direction * 0.045, duration: 0.2, recognizer: &r),
                           [.shortcut(direction < 0 ? back : forward)])
        }
        var r = GestureRecognizer(config: .instant)
        var actions: [GestureRecognizer.Action] = []
        for i in 0...12 {
            let hand = PoseFixtures.twoFingers(at: CGPoint(x: 0.5 + CGFloat(i) * 0.005,
                                                         y: 0.3 + CGFloat(i) * 0.015))
            actions += withoutScroll(r.update(hands: [hand], at: Double(i) * dt).actions)
        }
        XCTAssertEqual(actions, [], "sideways drift during vertical scrolling must not swipe")
    }

    func testRestingInThePoseAllowsAnotherSwipeWithoutLoweringTheFingers() {
        var r = GestureRecognizer(config: .instant)
        var actions: [GestureRecognizer.Action] = []
        var t = 0.0
        func frame(_ x: CGFloat) {
            actions += withoutScroll(r.update(hands: [PoseFixtures.twoFingers(at: CGPoint(x: x, y: 0.3))], at: t).actions)
            t += dt
        }
        for _ in 0..<10 { frame(0.5) }
        for i in 1...6 { frame(0.5 - 0.01 * CGFloat(i)) }
        for _ in 0..<20 { frame(0.44) }
        for i in 1...6 { frame(0.44 + 0.01 * CGFloat(i)) }
        XCTAssertEqual(actions, [.shortcut(back), .shortcut(forward)])
    }

    func testSidewaysDriftWhileScrollingIsNotASwipe() {
        var r = GestureRecognizer(config: .instant)
        // Two-finger scrolling wandered sideways at most 0.027 in 0.3 s in recorded logs.
        XCTAssertEqual(swipe(from: 0.5, to: 0.47, duration: 0.3, recognizer: &r), [])
    }

    func testSlowDriftIsNotASwipe() {
        var r = GestureRecognizer(config: .instant)
        XCTAssertEqual(swipe(from: 0.35, to: 0.6, duration: 2.0, recognizer: &r), [])
    }

    func testAOneFrameFlickerOutOfThePoseCannotSwipeTwice() {
        var r = GestureRecognizer(config: .instant)
        var actions: [GestureRecognizer.Action] = []
        var t = 0.0
        func frame(_ hand: HandPose) { actions += withoutScroll(r.update(hands: [hand], at: t).actions); t += dt }
        for i in 0...6 { frame(PoseFixtures.twoFingers(at: CGPoint(x: 0.6 - 0.25 * CGFloat(i) / 6, y: 0.3))) }
        frame(PoseFixtures.openHand(at: CGPoint(x: 0.35, y: 0.3)))       // one bad frame
        for i in 0...6 { frame(PoseFixtures.twoFingers(at: CGPoint(x: 0.35 + 0.25 * CGFloat(i) / 6, y: 0.3))) }
        XCTAssertEqual(actions, [.shortcut(back)], "still the same pose, so still one swipe")
    }

    func testABriefPassThroughThePoseDoesNotSwipe() {
        var r = GestureRecognizer(config: .instant)
        var actions: [GestureRecognizer.Action] = []
        for i in 0..<2 {
            actions += r.update(hands: [PoseFixtures.twoFingers(at: CGPoint(x: 0.6 - 0.15 * CGFloat(i), y: 0.3))], at: Double(i) * dt).actions
        }
        actions += r.update(hands: [PoseFixtures.openHand(at: CGPoint(x: 0.3, y: 0.3))], at: 2 * dt).actions
        XCTAssertEqual(actions, [])
    }

    func testAnUnboundPoseLeavesTheCursorAlone() {
        var map = GestureMap.standard
        map[.swipeLeft] = .none
        map[.swipeRight] = .none
        map[.twoFingers] = .none
        var r = GestureRecognizer(config: .instant, map: map)
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

final class PrecisionPointerTests: XCTestCase {
    let mapper = ScreenMapper(box: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), mirrored: false,
                              screen: CGRect(x: 0, y: 0, width: 1000, height: 1000))
    let dt = 1.0 / 30

    /// Moves the hand from x0 to x1 at y 0.5 over `duration`, returning the last cursor position.
    private func move(_ p: inout PrecisionPointer, from x0: CGFloat, to x1: CGFloat, duration: TimeInterval,
                      start: TimeInterval = 0) -> CGPoint {
        let steps = max(1, Int((duration / dt).rounded()))
        var cursor = CGPoint.zero
        for i in 0...steps {
            let x = x0 + (x1 - x0) * CGFloat(i) / CGFloat(steps)
            cursor = p.position(for: CGPoint(x: x, y: 0.5), at: start + Double(i) * dt, mapper: mapper)
        }
        return cursor
    }

    func testFirstSampleLandsWhereTheHandMaps() {
        var p = PrecisionPointer()
        XCTAssertEqual(p.position(for: CGPoint(x: 0.4, y: 0.5), at: 0, mapper: mapper), mapper.map(CGPoint(x: 0.4, y: 0.5)))
    }

    func testSlowMovesCoverAFractionOfTheDistance() {
        var p = PrecisionPointer()
        // 0.05 frame widths over 2 s is 0.025 /s, well under slowSpeed. Absolute would travel 100 px.
        let end = move(&p, from: 0.5, to: 0.55, duration: 2)
        XCTAssertEqual(end.x - 500, 100 * p.slowGain, accuracy: 1)
    }

    func testFastMovesCoverTheFullDistance() {
        var p = PrecisionPointer()
        // 0.2 frame widths in a quarter second is 0.8 /s, past fastSpeed.
        let end = move(&p, from: 0.4, to: 0.6, duration: 0.25)
        XCTAssertEqual(end.x, mapper.map(CGPoint(x: 0.6, y: 0.5)).x, accuracy: 10)
    }

    func testQuickMovesCatchUpWithTheHand() {
        var p = PrecisionPointer()
        _ = move(&p, from: 0.5, to: 0.6, duration: 4)
        let lag = mapper.map(CGPoint(x: 0.6, y: 0.5)).x - p.position(for: CGPoint(x: 0.6, y: 0.5), at: 4.1, mapper: mapper).x
        XCTAssertGreaterThan(lag, 100, "slow aiming leaves the cursor behind the hand")
        var t = 4.2
        for _ in 0..<3 {
            _ = move(&p, from: 0.6, to: 0.3, duration: 0.3, start: t)
            t += 0.4
            _ = move(&p, from: 0.3, to: 0.6, duration: 0.3, start: t)
            t += 0.4
        }
        let end = p.position(for: CGPoint(x: 0.6, y: 0.5), at: t, mapper: mapper)
        XCTAssertEqual(end.x, mapper.map(CGPoint(x: 0.6, y: 0.5)).x, accuracy: 20)
    }

    func testSlowMovesPastTheBoxEdgeStillReachTheScreenEdge() {
        var p = PrecisionPointer()
        let end = move(&p, from: 0.7, to: 0.95, duration: 8)
        XCTAssertEqual(end.x, 1000)
    }

    func testFullSlowGainIsPlainAbsoluteMapping() {
        var p = PrecisionPointer()
        p.slowGain = 1
        let end = move(&p, from: 0.5, to: 0.55, duration: 2)
        XCTAssertEqual(end, mapper.map(CGPoint(x: 0.55, y: 0.5)))
    }

    func testResetResyncsToTheHand() {
        var p = PrecisionPointer()
        _ = move(&p, from: 0.5, to: 0.6, duration: 4)
        p.reset()
        XCTAssertEqual(p.position(for: CGPoint(x: 0.6, y: 0.5), at: 5, mapper: mapper), mapper.map(CGPoint(x: 0.6, y: 0.5)))
    }
}

final class ScrollPolicyTests: XCTestCase {
    let dt = 1.0 / 30
    var p = ScrollPolicy()
    var t = 0.0

    /// Scroll gesture frames with this much hand travel each, then release frames until the coast
    /// ends. Returns the pixels posted after release.
    private func flick(travel: CGFloat, frames: Int = 4) -> [Int32] {
        for _ in 0..<frames {
            _ = p.pixels(travel: travel, scrolling: true, interrupted: false, at: t)
            t += dt
        }
        var steps: [Int32] = []
        for _ in 0..<120 {
            if let px = p.pixels(travel: nil, scrolling: false, interrupted: false, at: t) { steps.append(px) }
            t += dt
        }
        return steps
    }

    func testLiveScrollingFollowsTheHandWithNaturalDirection() {
        XCTAssertEqual(p.pixels(travel: 0.01, scrolling: true, interrupted: false, at: 0), -40)
        p.gain = 2
        XCTAssertEqual(p.pixels(travel: -0.01, scrolling: true, interrupted: false, at: dt), 80)
    }

    func testAFlickCoastsAndSlowsToAStop() {
        let steps = flick(travel: 0.01) // 40 px per frame
        XCTAssertEqual(steps.first, -40)
        XCTAssertTrue(zip(steps, steps.dropFirst()).allSatisfy { abs($1) <= abs($0) }, "always slowing")
        XCTAssertGreaterThan(steps.count, 10)
        XCTAssertLessThan(steps.count, 60)
    }

    func testAGentleScrollDoesNotCoast() {
        XCTAssertEqual(flick(travel: 0.001), [])
    }

    func testAnInterruptionEndsTheCoast() {
        for _ in 0..<4 { _ = p.pixels(travel: 0.01, scrolling: true, interrupted: false, at: t); t += dt }
        XCTAssertNotNil(p.pixels(travel: nil, scrolling: false, interrupted: false, at: t)); t += dt
        XCTAssertNil(p.pixels(travel: nil, scrolling: false, interrupted: true, at: t)); t += dt
        XCTAssertNil(p.pixels(travel: nil, scrolling: false, interrupted: false, at: t))
    }

    func testMomentumOffStopsWithTheHand() {
        p.momentum = false
        XCTAssertEqual(flick(travel: 0.01), [])
    }

    func testAStallDoesNotBecomeOneGiantStep() {
        for _ in 0..<4 { _ = p.pixels(travel: 0.01, scrolling: true, interrupted: false, at: t); t += dt }
        _ = p.pixels(travel: nil, scrolling: false, interrupted: false, at: t)
        let afterStall = p.pixels(travel: nil, scrolling: false, interrupted: false, at: t + 2)
        XCTAssertLessThanOrEqual(abs(afterStall ?? 0), 40 * 3)
    }
}
