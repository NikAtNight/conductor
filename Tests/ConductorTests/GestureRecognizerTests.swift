import XCTest
@testable import Conductor

final class GestureRecognizerTests: XCTestCase {
    typealias Action = GestureRecognizer.Action
    let dt = 1.0 / 30

    /// Feeds one frame per pose and returns every action in order.
    private func run(_ frames: [[HandPose]], recognizer: inout GestureRecognizer, startTime: TimeInterval = 0) -> [Action] {
        var t = startTime
        var actions: [Action] = []
        for hands in frames {
            t += dt
            actions += recognizer.update(hands: hands, at: t).actions
        }
        return actions
    }

    func testOpenHandMovesPointerWithoutActions() {
        var r = GestureRecognizer(config: .instant)
        let out = r.update(hands: [PoseFixtures.openHand()], at: 0)
        XCTAssertEqual(out.mode, .point)
        XCTAssertNotNil(out.pointer)
        XCTAssertTrue(out.actions.isEmpty)
    }

    func testPinchAndReleaseIsOneClick() {
        var r = GestureRecognizer(config: .instant)
        let actions = run([[PoseFixtures.openHand()], [PoseFixtures.pinched()], [PoseFixtures.pinched()], [PoseFixtures.openHand()]],
                          recognizer: &r)
        XCTAssertEqual(actions, [.leftDown(clickCount: 1), .leftUp(clickCount: 1)])
    }

    func testTwoQuickPinchesAreDoubleClick() {
        var r = GestureRecognizer(config: .instant)
        let frames: [[HandPose]] = [[PoseFixtures.pinched()], [PoseFixtures.openHand()],
                                    [PoseFixtures.pinched()], [PoseFixtures.openHand()]]
        let actions = run(frames, recognizer: &r)
        XCTAssertEqual(actions, [.leftDown(clickCount: 1), .leftUp(clickCount: 1),
                                 .leftDown(clickCount: 2), .leftUp(clickCount: 2)])
    }

    func testSlowSecondPinchIsSingleClick() {
        var r = GestureRecognizer(config: .instant)
        _ = r.update(hands: [PoseFixtures.pinched()], at: 0)
        _ = r.update(hands: [PoseFixtures.openHand()], at: 0.1)
        let out = r.update(hands: [PoseFixtures.pinched()], at: 1.0)
        XCTAssertEqual(out.actions, [.leftDown(clickCount: 1)])
    }

    func testHysteresisIgnoresSmallWobbleWhilePinched() {
        var r = GestureRecognizer(config: .instant)
        _ = r.update(hands: [PoseFixtures.pinched()], at: 0)
        // Tips drift to 0.45 hand scales apart: above engage (0.35), below release (0.55).
        var wobble = PoseFixtures.openHand()
        let index = wobble[.indexTip]!
        wobble.joints[.thumbTip] = CGPoint(x: index.x - 0.045, y: index.y)
        let out = r.update(hands: [wobble], at: dt)
        XCTAssertEqual(out.mode, .drag)
        XCTAssertTrue(out.actions.isEmpty)
    }

    func testPointerFreezesAtPinchThenDragsWithoutJump() {
        var r = GestureRecognizer(config: .instant)
        let start = r.update(hands: [PoseFixtures.pinched()], at: 0).pointer!
        // Tiny tremor stays frozen.
        let tremor = PoseFixtures.pinched(at: CGPoint(x: 0.503, y: 0.3))
        XCTAssertEqual(r.update(hands: [tremor], at: dt).pointer, start)
        // Real movement: first dragged frame lands exactly on the frozen point (offset absorbs the gap).
        let moved = PoseFixtures.pinched(at: CGPoint(x: 0.53, y: 0.3))
        let first = r.update(hands: [moved], at: 2 * dt).pointer!
        XCTAssertEqual(first.x, start.x, accuracy: 1e-9)
        // Then it follows the hand one-to-one.
        let further = PoseFixtures.pinched(at: CGPoint(x: 0.56, y: 0.3))
        let second = r.update(hands: [further], at: 3 * dt).pointer!
        XCTAssertEqual(second.x - first.x, 0.03, accuracy: 1e-9)
    }

    func testMiddlePinchIsRightClickOnce() {
        var r = GestureRecognizer(config: .instant)
        let frames: [[HandPose]] = [[PoseFixtures.openHand()], [PoseFixtures.pinched(.middleTip)],
                                    [PoseFixtures.pinched(.middleTip)], [PoseFixtures.openHand()]]
        XCTAssertEqual(run(frames, recognizer: &r), [.rightClick])
    }

    func testLosingHandReleasesHeldButton() {
        var r = GestureRecognizer(config: .instant)
        _ = r.update(hands: [PoseFixtures.pinched()], at: 0)
        var actions: [Action] = []
        for i in 1...6 { actions += r.update(hands: [], at: Double(i) * dt).actions }
        XCTAssertEqual(actions, [.leftUp(clickCount: 1)])
        XCTAssertEqual(r.mode, .idle)
    }

    func testBriefDropoutKeepsDrag() {
        var r = GestureRecognizer(config: .instant)
        _ = r.update(hands: [PoseFixtures.pinched()], at: 0)
        let dropped = r.update(hands: [], at: dt)
        XCTAssertEqual(dropped.mode, .drag)
        XCTAssertTrue(dropped.actions.isEmpty)
        let back = r.update(hands: [PoseFixtures.pinched()], at: 2 * dt)
        XCTAssertTrue(back.actions.isEmpty, "still pinched, no new down event")
    }

    func testFistScrollsByPalmTravel() {
        var r = GestureRecognizer(config: .instant)
        _ = r.update(hands: [PoseFixtures.fist(at: CGPoint(x: 0.5, y: 0.3))], at: 0)
        let out = r.update(hands: [PoseFixtures.fist(at: CGPoint(x: 0.5, y: 0.34))], at: dt)
        XCTAssertEqual(out.mode, .scroll)
        XCTAssertEqual(out.actions.count, 1)
        if case .scroll(let dy) = out.actions[0] {
            XCTAssertEqual(dy, 0.04, accuracy: 1e-9)
        } else {
            XCTFail("expected scroll, got \(out.actions)")
        }
    }

    func testFistDuringDragReleasesButton() {
        var r = GestureRecognizer(config: .instant)
        _ = r.update(hands: [PoseFixtures.pinched()], at: 0)
        let out = r.update(hands: [PoseFixtures.fist()], at: dt)
        XCTAssertEqual(out.actions, [.leftUp(clickCount: 1)])
    }

    func testTwoPinchedHandsZoomBySpread() {
        var r = GestureRecognizer(config: .instant)
        var left = PoseFixtures.pinched(at: CGPoint(x: 0.3, y: 0.3))
        left.chirality = .left
        let right = PoseFixtures.pinched(at: CGPoint(x: 0.6, y: 0.3))
        let first = r.update(hands: [left, right], at: 0)
        XCTAssertEqual(first.mode, .zoom)
        var leftFar = PoseFixtures.pinched(at: CGPoint(x: 0.2, y: 0.3))
        leftFar.chirality = .left
        let second = r.update(hands: [leftFar, right], at: dt)
        guard case .zoom(let delta) = second.actions.last else { return XCTFail("expected zoom, got \(second.actions)") }
        XCTAssertEqual(delta, 0.1, accuracy: 1e-9)
    }

    func testZoomDoesNotArmDoubleClick() {
        var r = GestureRecognizer(config: .instant)
        var left = PoseFixtures.pinched(at: CGPoint(x: 0.3, y: 0.3))
        left.chirality = .left
        _ = r.update(hands: [PoseFixtures.pinched()], at: 0)          // left down
        _ = r.update(hands: [left, PoseFixtures.pinched()], at: dt)   // zoom releases it, not a click
        _ = r.update(hands: [PoseFixtures.openHand()], at: 2 * dt)
        let out = r.update(hands: [PoseFixtures.pinched()], at: 3 * dt)
        XCTAssertEqual(out.actions, [.leftDown(clickCount: 1)])
    }
}

final class PinchDisambiguationTests: XCTestCase {
    /// Thumb lands between index and middle tips, nearer the middle one.
    func testCloserFingerWinsWhenBothAreNear() {
        var hand = PoseFixtures.openHand()
        let index = hand[.indexTip]!, middle = hand[.middleTip]!
        hand.joints[.thumbTip] = CGPoint(x: index.x * 0.4 + middle.x * 0.6, y: index.y * 0.4 + middle.y * 0.6)
        // Both within engage range (gap between tips is 0.45 hand scales).
        XCTAssertLessThan(hand.normalizedDistance(.thumbTip, .indexTip)!, 0.35)
        XCTAssertLessThan(hand.normalizedDistance(.thumbTip, .middleTip)!, 0.35)
        var r = GestureRecognizer(config: .instant)
        XCTAssertEqual(r.update(hands: [hand], at: 0).actions, [.rightClick])
    }

    func testIndexPinchDoesNotAlsoRightClick() {
        var r = GestureRecognizer(config: .instant)
        let actions = r.update(hands: [PoseFixtures.pinched()], at: 0).actions
        XCTAssertEqual(actions, [.leftDown(clickCount: 1)])
    }
}
