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

    /// The pinch with the thumb and index this far apart in hand scales, at `x`.
    private func pinched(apart distance: CGFloat, x: CGFloat = 0.5) -> HandPose {
        var hand = PoseFixtures.openHand(at: CGPoint(x: x, y: 0.3))
        let index = hand[.indexTip]!
        hand.joints[.thumbTip] = CGPoint(x: index.x - distance * hand.scale!, y: index.y)
        return hand
    }

    /// Nikhil's fingers often came to rest about 0.4 apart after a click, short of the 0.55
    /// release, and the button stayed down for a second while the hand drifted.
    func testAClickLeftHalfOpenLetsGoWithoutDragging() {
        var r = GestureRecognizer(config: .instant)
        var t = 0.0
        var actions: [Action] = []
        func frame(_ hand: HandPose, count: Int = 1) {
            for _ in 0..<count { actions += r.update(hands: [hand], at: t).actions; t += dt }
        }
        frame(PoseFixtures.pinched(), count: 3)
        frame(pinched(apart: 0.4), count: 3)
        XCTAssertEqual(actions, [.leftDown(clickCount: 1)], "a brief loosening is still held")
        frame(pinched(apart: 0.4), count: 3)
        XCTAssertEqual(actions, [.leftDown(clickCount: 1), .leftUp(clickCount: 1)])
        // Closing again from half open doesn't click again: the fingers have to open first.
        frame(PoseFixtures.pinched(), count: 5)
        XCTAssertEqual(actions.count, 2)
    }

    func testADragKeepsTheFullReleaseWhenThePinchLoosens() {
        var r = GestureRecognizer(config: .instant)
        var t = 0.0
        var actions: [Action] = []
        func frame(_ hand: HandPose) { actions += r.update(hands: [hand], at: t).actions; t += dt }
        frame(PoseFixtures.pinched())
        for i in 1...6 { frame(pinched(apart: 0.1, x: 0.5 + 0.01 * CGFloat(i))) } // dragging
        for i in 1...10 { frame(pinched(apart: 0.45, x: 0.56 + 0.005 * CGFloat(i))) }
        XCTAssertEqual(actions, [.leftDown(clickCount: 1)], "a loose pinch mid-drag doesn't drop what it carries")
        frame(PoseFixtures.openHand(at: CGPoint(x: 0.61, y: 0.3)))
        XCTAssertEqual(actions, [.leftDown(clickCount: 1), .leftUp(clickCount: 1)])
    }

    func testPointerFreezesAtPinchThenDragsWithoutJump() {
        var r = GestureRecognizer(config: .instant)
        let start = r.update(hands: [PoseFixtures.pinched()], at: 0).pointer!
        // Tiny tremor stays frozen.
        let tremor = PoseFixtures.pinched(at: CGPoint(x: 0.503, y: 0.3))
        XCTAssertEqual(r.update(hands: [tremor], at: dt).pointer, start)
        // Real movement: first dragged frame lands exactly on the frozen point (offset absorbs the gap).
        let moved = PoseFixtures.pinched(at: CGPoint(x: 0.54, y: 0.3))
        let first = r.update(hands: [moved], at: 2 * dt).pointer!
        XCTAssertEqual(first.x, start.x, accuracy: 1e-9)
        // Then it follows the hand one-to-one.
        let further = PoseFixtures.pinched(at: CGPoint(x: 0.57, y: 0.3))
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
        for i in 1...14 { actions += r.update(hands: [], at: Double(i) * dt).actions }
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
        var r = GestureRecognizer(config: .travelScroll)
        _ = r.update(hands: [PoseFixtures.fist(at: CGPoint(x: 0.5, y: 0.3))], at: 0)
        let out = r.update(hands: [PoseFixtures.fist(at: CGPoint(x: 0.5, y: 0.34))], at: dt)
        XCTAssertEqual(out.mode, .scroll)
        XCTAssertEqual(out.actions.count, 1)
        if case .scrollTravel(let dy) = out.actions[0] {
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

    func testTwoFistsWithTheThumbOnTheIndexStillZoom() {
        // Pinching both hands curls the other fingers in and the thumb sits beside the curled index:
        // 0.4 to 0.5 scales from its tip in recorded logs, which a one-hand pinch wouldn't take.
        func pinchedFist(at wrist: CGPoint, chirality: Chirality) -> HandPose {
            var hand = PoseFixtures.fist(at: wrist)
            let index = hand[.indexTip]!
            hand.joints[.thumbTip] = CGPoint(x: index.x - 0.45 * hand.scale!, y: index.y)
            hand.chirality = chirality
            return hand
        }
        var r = GestureRecognizer(config: .instant)
        let right = pinchedFist(at: CGPoint(x: 0.3, y: 0.3), chirality: .right)
        let left = pinchedFist(at: CGPoint(x: 0.7, y: 0.3), chirality: .left)
        XCTAssertEqual(right.normalizedDistance(.thumbTip, .indexTip)!, 0.45, accuracy: 0.001)
        XCTAssertTrue(right.isFist)
        _ = run([[right, left]], recognizer: &r)
        XCTAssertEqual(r.mode, .zoom, "both hands beat the fist")
        // One hand alone with that thumb is a fist, not a pinch.
        var alone = GestureRecognizer(config: .instant)
        _ = run([[right]], recognizer: &alone)
        XCTAssertEqual(alone.mode, .scroll)
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

/// Pinch handling tuned from Nikhil's push-to-talk logs: fingers passing the thumb while a hand
/// opens, neighbouring fingertips swapped by Vision, two fingers at the thumb at once, and the hand
/// dropping out of view for a few frames.
final class PinchRobustnessTests: XCTestCase {
    typealias Action = GestureRecognizer.Action
    let dt = 1.0 / 30
    let rightCommand = Shortcut(keyCode: 54, modifiers: 0)

    private func pushToTalk() -> GestureRecognizer {
        var map = GestureMap.standard
        map[.ringPinch] = .holdKey(rightCommand)
        return GestureRecognizer(config: .instant, map: map)
    }

    private func run(_ r: inout GestureRecognizer, _ hands: [HandPose], from frame: Int, count: Int) -> [Action] {
        (frame..<(frame + count)).flatMap { r.update(hands: hands, at: Double($0) * dt).actions }
    }

    func testFoldedThumbCannotStartAPinchWhileTwoFingersAreBeingConfirmed() {
        var map = GestureMap.standard
        map[.ringPinch] = .holdKey(rightCommand)
        var r = GestureRecognizer(config: .withoutReadyPose, map: map)
        var hand = PoseFixtures.twoFingers()
        hand.joints[.thumbTip] = hand[.ringTip]
        // The thumb arrives first, one frame before the little finger finishes curling.
        var forming = hand
        forming.joints[.littleTip] = PoseFixtures.openHand()[.littleTip]
        _ = r.update(hands: [PoseFixtures.openHand()], at: 0)
        _ = r.update(hands: [forming], at: dt)
        let outputs = (2...15).map { frame in
            r.update(hands: [hand], at: Double(frame) * dt)
        }
        XCTAssertFalse(outputs.flatMap(\.actions).contains(.keyDown(rightCommand)))
        XCTAssertEqual(outputs.last?.trigger, .twoFingers)
    }

    func testAnUnboundTwoFingerPoseDoesNotBlockRingPinch() {
        var map = GestureMap.standard
        map[.ringPinch] = .holdKey(rightCommand)
        for trigger in [Trigger.twoFingers, .swipeLeft, .swipeRight] { map[trigger] = .none }
        var r = GestureRecognizer(config: .withoutReadyPose, map: map)
        var hand = PoseFixtures.twoFingers()
        hand.joints[.thumbTip] = hand[.ringTip]
        XCTAssertEqual(run(&r, [hand], from: 0, count: 10), [.keyDown(rightCommand)])
    }

    func testOpeningAFistPastTheThumbDoesNotClick() {
        var r = GestureRecognizer(config: .instant)
        _ = run(&r, [PoseFixtures.openHand()], from: 0, count: 2)
        _ = run(&r, [PoseFixtures.fist()], from: 2, count: 5)
        // The index tip meets the thumb on the way open: this clicked in the logs.
        let opening = run(&r, [PoseFixtures.pinched()], from: 7, count: 3)
        XCTAssertFalse(opening.contains(.leftDown(clickCount: 1)))
        // Once the hand has opened, a pinch is a pinch again.
        _ = run(&r, [PoseFixtures.openHand()], from: 10, count: 2)
        XCTAssertTrue(run(&r, [PoseFixtures.pinched()], from: 12, count: 2).contains(.leftDown(clickCount: 1)))
    }

    func testLettingGoOfOnePinchIntoAnotherDoesNotFireTheSecond() {
        var r = pushToTalk()
        _ = run(&r, [PoseFixtures.openHand()], from: 0, count: 2)
        XCTAssertEqual(run(&r, [PoseFixtures.pinched(.ringTip)], from: 2, count: 3), [.keyDown(rightCommand)])
        // Straight from the ring pinch into an index pinch without opening: key up, no click.
        let swapped = run(&r, [PoseFixtures.pinched(.indexTip)], from: 5, count: 4)
        XCTAssertEqual(swapped, [.keyUp(rightCommand)])
    }

    func testAHandThatArrivesPinchedStillClicks() {
        var r = GestureRecognizer(config: .instant)
        XCTAssertTrue(run(&r, [PoseFixtures.pinched()], from: 0, count: 2).contains(.leftDown(clickCount: 1)))
    }

    func testAHeldRingPinchSurvivesTheTipSwappingWithTheLittleFinger() {
        var r = pushToTalk()
        _ = run(&r, [PoseFixtures.openHand()], from: 0, count: 2)
        XCTAssertEqual(run(&r, [PoseFixtures.pinched(.ringTip)], from: 2, count: 3), [.keyDown(rightCommand)])
        // One frame where Vision puts the little tip at the thumb and the ring tip far away.
        var swapped = PoseFixtures.pinched(.littleTip)
        swapped.joints[.ringTip] = PoseFixtures.openHand()[.ringTip]
        XCTAssertEqual(run(&r, [swapped], from: 5, count: 2), [], "still held")
        XCTAssertEqual(run(&r, [PoseFixtures.pinched(.ringTip)], from: 7, count: 2), [])
        XCTAssertEqual(run(&r, [PoseFixtures.openHand()], from: 9, count: 1), [.keyUp(rightCommand)])
    }

    func testAnIndexPinchReleasesEvenWithTheMiddleFingerAtTheThumb() {
        var r = GestureRecognizer(config: .instant)
        _ = run(&r, [PoseFixtures.openHand()], from: 0, count: 1)
        _ = run(&r, [PoseFixtures.pinched()], from: 1, count: 2)
        var middleClose = PoseFixtures.openHand()
        middleClose.joints[.middleTip] = CGPoint(x: middleClose[.thumbTip]!.x + 0.01, y: middleClose[.thumbTip]!.y)
        XCTAssertEqual(run(&r, [middleClose], from: 3, count: 1), [.leftUp(clickCount: 1)])
    }

    func testRingBeatsMiddleWhenBothTouchTheThumb() {
        var r = pushToTalk()
        _ = run(&r, [PoseFixtures.openHand()], from: 0, count: 2)
        var both = PoseFixtures.pinched(.ringTip)
        let thumb = both[.thumbTip]!
        both.joints[.middleTip] = CGPoint(x: thumb.x - 0.004, y: thumb.y)  // a hair closer than the ring
        XCTAssertEqual(run(&r, [both], from: 2, count: 3), [.keyDown(rightCommand)], "not a right click")
    }

    func testTheIndexNeverLosesATie() {
        var r = GestureRecognizer(config: .instant)
        _ = run(&r, [PoseFixtures.openHand()], from: 0, count: 2)
        var both = PoseFixtures.pinched(.indexTip)
        let thumb = both[.thumbTip]!
        both.joints[.middleTip] = CGPoint(x: thumb.x, y: thumb.y + 0.011)
        XCTAssertEqual(run(&r, [both], from: 2, count: 2).first, .leftDown(clickCount: 1))
    }

    func testTheHandCanDropOutForTenFramesWithoutLettingGo() {
        var r = pushToTalk()
        _ = run(&r, [PoseFixtures.openHand()], from: 0, count: 2)
        XCTAssertEqual(run(&r, [PoseFixtures.pinched(.ringTip)], from: 2, count: 3), [.keyDown(rightCommand)])
        XCTAssertEqual(run(&r, [], from: 5, count: 10), [], "a six-frame dropout happened in the logs")
        XCTAssertEqual(run(&r, [PoseFixtures.pinched(.ringTip)], from: 15, count: 2), [])
        XCTAssertEqual(run(&r, [], from: 17, count: 12).last, .keyUp(rightCommand), "gone for good")
    }
}
