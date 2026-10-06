import XCTest
@testable import Conductor

/// Pointing-hand guards with the real hold delay: what keeps pinches from firing by accident.
final class PointingTests: XCTestCase {
    typealias Action = GestureRecognizer.Action
    let dt = 1.0 / 30
    var r = GestureRecognizer()
    var t = 0.0
    var actions: [Action] = []
    var last: GestureRecognizer.Output?

    private func frame(_ hand: HandPose, count: Int = 1) {
        for _ in 0..<count {
            let out = r.update(hands: [hand], at: t)
            actions += out.actions
            last = out
            t += dt
        }
    }

    func testAPinchHasToHoldBeforeItClicks() {
        frame(PoseFixtures.openHand())
        frame(PoseFixtures.pinched(), count: 2)
        XCTAssertEqual(actions, [])
        frame(PoseFixtures.pinched())
        XCTAssertEqual(actions, [.leftDown(clickCount: 1)])
    }

    func testAFingertipBrushingPastTheThumbDoesNotClick() {
        frame(PoseFixtures.openHand())
        frame(PoseFixtures.pinched(), count: 2)
        frame(PoseFixtures.openHand(), count: 3)
        XCTAssertEqual(actions, [])
    }

    func testAFingerAimedAtTheCameraCannotPinch() {
        frame(PoseFixtures.aimedAtCamera(), count: 15)
        XCTAssertEqual(actions, [])
        XCTAssertEqual(last?.feedback.pinch, 0, "the ring doesn't fill for a pinch that can't click")
    }

    func testResumingWithAPinchWaitsForTheHoldToo() {
        var map = GestureMap.standard
        map[.littlePinch] = .pauseTracking
        r = GestureRecognizer(map: map)
        frame(PoseFixtures.pinched(.littleTip), count: 3)
        XCTAssertTrue(r.isPaused)
        frame(PoseFixtures.openHand(), count: 3)
        frame(PoseFixtures.pinched(.littleTip))
        XCTAssertTrue(r.isPaused, "a fingertip brushing past doesn't resume")
        frame(PoseFixtures.pinched(.littleTip), count: 2)
        XCTAssertFalse(r.isPaused)
    }

    func testTheThumbRestingOnCurledFingersIsNotARightClick() {
        var hand = PoseFixtures.pointing()
        let middle = hand[.middleTip]!
        hand.joints[.thumbTip] = CGPoint(x: middle.x - 0.005, y: middle.y)
        frame(hand, count: 10)
        XCTAssertEqual(actions, [])
    }

}

/// Two fingers up and the hand moving: scroll (or whatever the pose is bound to), cursor still.
final class TwoFingerScrollTests: XCTestCase {
    typealias Action = GestureRecognizer.Action
    let dt = 1.0 / 30
    let back = Shortcut(keyCode: 33, modifiers: CGEventFlags.maskCommand.rawValue)
    var r = GestureRecognizer()
    var t = 0.0
    var outputs: [GestureRecognizer.Output] = []

    override func setUp() {
        super.setUp()
        // These are about the travel style; the lever has its own tests (HeldLeverScrollTests).
        r.config.scrollLever = false
    }

    private func frame(_ hand: HandPose, count: Int = 1) {
        for _ in 0..<count {
            outputs.append(r.update(hands: [hand], at: t))
            t += dt
        }
    }

    private var actions: [Action] { outputs.flatMap(\.actions) }
    private var scrolls: [CGFloat] {
        actions.compactMap { if case .scroll(let dy) = $0 { return dy } else { return nil } }
    }

    /// Two fingers up, hand moving from y0 to y1 over `frames`.
    private func move(from y0: CGFloat, to y1: CGFloat, frames: Int) {
        for i in 0...frames {
            frame(PoseFixtures.twoFingers(at: CGPoint(x: 0.5, y: y0 + (y1 - y0) * CGFloat(i) / CGFloat(frames))))
        }
    }

    /// A quick sideways move in the pose, toward the user's right when mirrored.
    private func flickSideways() {
        for i in 0...6 { frame(PoseFixtures.twoFingers(at: CGPoint(x: 0.6 - 0.25 * CGFloat(i) / 6, y: 0.3))) }
    }

    func testMovingTheHandUpScrollsUpWithTheCursorStill() {
        frame(PoseFixtures.openHand())
        move(from: 0.3, to: 0.4, frames: 10)
        XCTAssertEqual(outputs.last?.mode, .scroll)
        XCTAssertNil(outputs.last?.pointer)
        XCTAssertEqual(scrolls.reduce(0, +), 0.08, accuracy: 0.001, "travel after the pose settles, 1:1")
        XCTAssertTrue(scrolls.allSatisfy { $0 > 0 })
        XCTAssertEqual(actions.count, scrolls.count, "nothing but scroll")
    }

    func testMovingTheHandDownScrollsDown() {
        move(from: 0.4, to: 0.3, frames: 10)
        XCTAssertEqual(scrolls.reduce(0, +), -0.08, accuracy: 0.001)
    }

    func testLoweringTheFingersEndsTheScrollAndFreesTheCursor() {
        move(from: 0.3, to: 0.4, frames: 10)
        frame(PoseFixtures.openHand(at: CGPoint(x: 0.5, y: 0.4)), count: 4)
        XCTAssertEqual(outputs.last?.mode, .point)
        XCTAssertNotNil(outputs.last?.pointer)
    }

    func testABriefPassThroughThePoseDoesNotScroll() {
        frame(PoseFixtures.openHand())
        frame(PoseFixtures.twoFingers(at: CGPoint(x: 0.5, y: 0.35)), count: 2)
        frame(PoseFixtures.openHand(at: CGPoint(x: 0.5, y: 0.4)), count: 3)
        XCTAssertEqual(actions, [])
    }

    func testASidewaysFlickStillSwipes() {
        flickSideways()
        XCTAssertTrue(actions.contains(.shortcut(back)))
    }

    func testThePoseFreezesTheCursorEvenWithOnlySwipesBound() {
        var map = GestureMap.standard
        map[.twoFingers] = .none
        r = GestureRecognizer(map: map)
        frame(PoseFixtures.twoFingers(), count: 4)
        XCTAssertNil(outputs.last?.pointer)
        XCTAssertEqual(actions, [])
    }

    func testTwoFingersBoundToPausePauseAndResume() {
        var map = GestureMap.standard
        map[.twoFingers] = .pauseTracking
        r = GestureRecognizer(map: map)
        frame(PoseFixtures.twoFingers(), count: 4)
        XCTAssertTrue(r.isPaused)
        frame(PoseFixtures.twoFingers(), count: 10)
        XCTAssertTrue(r.isPaused, "still holding the pose that paused")
        frame(PoseFixtures.openHand(), count: 4)
        frame(PoseFixtures.twoFingers(), count: 4)
        XCTAssertFalse(r.isPaused)
    }

    func testAPausingSwipeReleasesWhatThePoseHeld() {
        var map = GestureMap.standard
        map[.twoFingers] = .leftButton
        map[.swipeRight] = .pauseTracking
        r = GestureRecognizer(map: map)
        flickSideways()
        XCTAssertTrue(r.isPaused)
        XCTAssertEqual(actions.filter { $0 == .leftDown(clickCount: 1) }.count, 1)
        XCTAssertEqual(actions.filter { $0 == .leftUp(clickCount: 1) }.count, 1)
    }

    func testAStallReleaseKeepsControl() {
        var config = GestureRecognizer.Config.instant
        config.requireReadyPose = true
        r = GestureRecognizer(config: config)
        frame(PoseFixtures.openHand(), count: 20) // take control
        frame(PoseFixtures.pinched(), count: 2)
        XCTAssertEqual(r.releaseHeld(), [.leftUp(clickCount: 1)])
        frame(PoseFixtures.openHand())
        XCTAssertEqual(outputs.last?.mode, .point, "no ready pose needed again")
        XCTAssertNotNil(outputs.last?.pointer)
    }
}

@MainActor
final class CalibrationPointTests: XCTestCase {
    func testABoxCalibratedFromTheFingertipsIsDroppedOnce() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "CalibrationPointTests.\(UUID())"))
        suite.set([0.1, 0.3, 0.6, 0.25], forKey: "calibratedBox")
        XCTAssertNil(Preferences(defaults: suite).calibratedBox)

        let fresh = Preferences(defaults: suite)
        fresh.calibratedBox = CGRect(x: 0.1, y: 0.3, width: 0.6, height: 0.25)
        XCTAssertNotNil(Preferences(defaults: suite).calibratedBox, "a box calibrated from the knuckle stays")
    }
}
