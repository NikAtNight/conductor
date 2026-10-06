import XCTest
@testable import Conductor

/// The app's example hands (HandPoseExamples), under the name the tests have always used.
typealias PoseFixtures = HandPoseExamples

extension GestureRecognizer.Config {
    /// Pinches engage on their first frame. For tests about everything else.
    static var instant: Self {
        var config = Self()
        config.pinchHold = 0
        return config
    }

    /// `instant`, with held scroll triggers following hand travel instead of working as a lever.
    static var travelScroll: Self {
        var config = instant
        config.scrollLever = false
        return config
    }
}

final class HandPoseTests: XCTestCase {
    func testScaleIsWristToIndexKnuckle() {
        let hand = PoseFixtures.openHand()
        XCTAssertEqual(hand.scale!, 0.0996, accuracy: 0.001)
    }

    func testOpenHandIsNotPinchedOrFist() {
        let hand = PoseFixtures.openHand()
        XCTAssertGreaterThan(hand.normalizedDistance(.thumbTip, .indexTip)!, 0.8)
        XCTAssertFalse(hand.isFist)
    }

    func testPinchBringsTipsTogether() {
        let hand = PoseFixtures.pinched()
        XCTAssertLessThan(hand.normalizedDistance(.thumbTip, .indexTip)!, 0.15)
    }

    func testFistDetection() {
        XCTAssertTrue(PoseFixtures.fist().isFist)
    }

    func testPointerIsTheIndexKnuckle() {
        let hand = PoseFixtures.openHand()
        XCTAssertEqual(hand.pointer, hand[.indexMCP])
    }

    func testPinchingPointingAndFistsLeaveThePointerAlone() {
        let still = PoseFixtures.openHand().pointer
        XCTAssertEqual(PoseFixtures.pinched().pointer, still)
        XCTAssertEqual(PoseFixtures.pointing(bend: 1).pointer, still)
        XCTAssertEqual(PoseFixtures.fist().pointer, still)
    }

    func testAFingerAimedAtTheCameraLooksShort() {
        XCTAssertGreaterThan(PoseFixtures.openHand().visibleLength(of: .indexTip)!, 1)
        XCTAssertLessThan(PoseFixtures.aimedAtCamera().visibleLength(of: .indexTip)!, 0.5)
    }

    func testPointingPoseHasTheOtherFingersCurled() {
        XCTAssertTrue(PoseFixtures.pointing().othersCurled)
        XCTAssertFalse(PoseFixtures.pointing().isFist)
        XCTAssertFalse(PoseFixtures.openHand().othersCurled)
        XCTAssertFalse(PoseFixtures.twoFingers().othersCurled)
    }

    func testThePointingSignNeedsTheThumbOut() {
        XCTAssertTrue(PoseFixtures.pointing().isPointingSign)
        XCTAssertFalse(PoseFixtures.pointing(tuckedThumb: true).isPointingSign, "a relaxed pointing hand")
        XCTAssertFalse(PoseFixtures.pointing(bend: 1).isPointingSign)
        XCTAssertFalse(PoseFixtures.openHand().isPointingSign)
        XCTAssertFalse(PoseFixtures.twoFingers().isPointingSign)
        XCTAssertFalse(PoseFixtures.fist().isPointingSign)
        XCTAssertFalse(PoseFixtures.pinched().isPointingSign)
        for direction in [Direction.up, .down, .left, .right] {
            XCTAssertTrue(PoseFixtures.pointingSign(direction).isPointingSign, "\(direction)")
        }
    }

    func testTheIndexVectorFollowsTheFinger() throws {
        let up = try XCTUnwrap(PoseFixtures.pointingSign(.up).indexVector)
        XCTAssertGreaterThan(up.dy, abs(up.dx))
        let down = try XCTUnwrap(PoseFixtures.pointingSign(.down).indexVector)
        XCTAssertLessThan(down.dy, -abs(down.dx))
        // Mirrored: the user's right is Vision's left.
        let right = try XCTUnwrap(PoseFixtures.pointingSign(.right).indexVector)
        XCTAssertLessThan(right.dx, -abs(right.dy))
        let left = try XCTUnwrap(PoseFixtures.pointingSign(.left).indexVector)
        XCTAssertGreaterThan(left.dx, abs(left.dy))
    }
}

final class PointingThumbTests: XCTestCase {
    /// `pointing()` with the thumb tip placed `scales` hand scales from the index knuckle.
    private func sign(thumbOut scales: CGFloat) -> HandPose {
        var hand = PoseFixtures.pointing()
        let knuckle = hand[.indexMCP]!, scale = hand.scale!
        hand.joints[.thumbTip] = CGPoint(x: knuckle.x - scales * scale, y: knuckle.y)
        return hand
    }

    func testTheThumbThresholdSitsBetweenNikhilsRelaxedAndDeliberateHands() {
        XCTAssertFalse(sign(thumbOut: 0.29).isPointingSign, "relaxed pointing measured 0.24 to 0.29")
        XCTAssertTrue(sign(thumbOut: 0.50).isPointingSign, "a deliberate sign measured 0.50 to 0.56")
        XCTAssertTrue(sign(thumbOut: 0.45).isPointingSign)
    }
}
