import XCTest
@testable import Conductor

final class ControlStateTests: XCTestCase {
    let dt = 1.0 / 30

    private func readyRecognizer() -> GestureRecognizer {
        var config = GestureRecognizer.Config.instant
        config.requireReadyPose = true
        return GestureRecognizer(config: config)
    }

    func testOpenHandFixtureCountsAsReadyAndPinchOrFistDoesNot() {
        XCTAssertTrue(PoseFixtures.openHand().isOpenHand)
        XCTAssertFalse(PoseFixtures.pinched().isOpenHand)
        XCTAssertFalse(PoseFixtures.fist().isOpenHand)
    }

    func testNothingMovesUntilTheReadyPoseIsHeld() {
        var r = readyRecognizer()
        let first = r.update(hands: [PoseFixtures.openHand()], at: 0)
        XCTAssertEqual(first.mode, .waiting)
        XCTAssertNil(first.pointer)
        XCTAssertTrue(r.update(hands: [PoseFixtures.pinched()], at: dt).actions.isEmpty, "pinch while waiting does nothing")
        var t = 2 * dt
        var events: [GestureRecognizer.Event] = []
        var last: GestureRecognizer.Output?
        while t < 1.0 {
            last = r.update(hands: [PoseFixtures.openHand()], at: t)
            events += last!.events
            t += dt
        }
        XCTAssertEqual(events, [.tookControl])
        XCTAssertEqual(last?.mode, .point)
        XCTAssertNotNil(last?.pointer)
    }

    func testMovingHandDoesNotTakeControl() {
        var r = readyRecognizer()
        var t = 0.0
        for i in 0..<30 {
            let out = r.update(hands: [PoseFixtures.openHand(at: CGPoint(x: 0.3 + Double(i) * 0.02, y: 0.3))], at: t)
            XCTAssertEqual(out.mode, .waiting)
            t += dt
        }
    }

    func testControlIsReleasedAfterTheHandIsGoneLongEnough() {
        var r = readyRecognizer()
        var t = 0.0
        while t < 0.7 { _ = r.update(hands: [PoseFixtures.openHand()], at: t); t += dt }
        XCTAssertEqual(r.update(hands: [PoseFixtures.openHand()], at: t).mode, .point)
        // Short gap keeps control.
        _ = r.update(hands: [], at: t + 0.5)
        XCTAssertEqual(r.update(hands: [PoseFixtures.openHand()], at: t + 0.6).mode, .point)
        // Long gap hands it back.
        XCTAssertEqual(r.update(hands: [], at: t + 2.5).events, [.releasedControl])
        XCTAssertEqual(r.update(hands: [PoseFixtures.openHand()], at: t + 2.6).mode, .waiting)
    }

    func testLeftHandedPreferencePicksTheLeftHand() {
        var left = PoseFixtures.openHand(at: CGPoint(x: 0.2, y: 0.3))
        left.chirality = .left
        let right = PoseFixtures.openHand(at: CGPoint(x: 0.7, y: 0.3))
        XCTAssertEqual(GestureRecognizer.primaryHand([right, left], prefer: .left), left)
        XCTAssertEqual(GestureRecognizer.primaryHand([left, right], prefer: .right), right)
        XCTAssertEqual(GestureRecognizer.primaryHand([left, right], prefer: .either), left)
        XCTAssertEqual(GestureRecognizer.primaryHand([right], prefer: .left), right, "a lone hand still drives")
    }

    private func dwellRecognizer() -> GestureRecognizer {
        var config = GestureRecognizer.Config.instant
        config.dwellClick = true
        return GestureRecognizer(config: config)
    }

    func testHoldingStillClicksOnceThenNeedsAMoveToArmAgain() {
        var r = dwellRecognizer()
        var t = 0.0
        var actions: [GestureRecognizer.Action] = []
        while t < 2.5 {
            actions += r.update(hands: [PoseFixtures.openHand()], at: t).actions
            t += dt
        }
        XCTAssertEqual(actions, [.leftDown(clickCount: 1), .leftUp(clickCount: 1)])
        // Move away, then hold still again: a second click.
        actions = []
        let moved = CGPoint(x: 0.6, y: 0.3)
        let end = t + 1.2
        while t < end {
            actions += r.update(hands: [PoseFixtures.openHand(at: moved)], at: t).actions
            t += dt
        }
        XCTAssertEqual(actions, [.leftDown(clickCount: 1), .leftUp(clickCount: 1)])
    }

    func testDwellProgressRisesAndDoesNotFireRightAfterAPinch() {
        var r = dwellRecognizer()
        _ = r.update(hands: [PoseFixtures.pinched()], at: 0)
        var t = dt
        var actions: [GestureRecognizer.Action] = []
        while t < 2 {
            actions += r.update(hands: [PoseFixtures.openHand()], at: t).actions
            t += dt
        }
        XCTAssertEqual(actions, [.leftUp(clickCount: 1)], "only the pinch's own release, no dwell click")

        var fresh = dwellRecognizer()
        _ = fresh.update(hands: [PoseFixtures.openHand()], at: 0)
        let halfway = fresh.update(hands: [PoseFixtures.openHand()], at: 0.4)
        XCTAssertEqual(halfway.feedback.dwell, 0.5, accuracy: 0.01)
    }

    func testPinchFeedbackGrowsAsFingersClose() {
        var r = GestureRecognizer(config: .instant)
        XCTAssertEqual(r.update(hands: [PoseFixtures.openHand()], at: 0).feedback.pinch, 0)
        var halfway = PoseFixtures.openHand()
        let index = halfway[.indexTip]!
        // 0.45 hand widths apart: halfway between engage (0.35) and release (0.55).
        halfway.joints[.thumbTip] = CGPoint(x: index.x - 0.45 * halfway.scale!, y: index.y)
        XCTAssertEqual(r.update(hands: [halfway], at: dt).feedback.pinch, 0.5, accuracy: 0.01)
        XCTAssertEqual(r.update(hands: [PoseFixtures.pinched()], at: 2 * dt).feedback.pinch, 1)
    }
}
