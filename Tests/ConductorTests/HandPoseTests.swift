import XCTest
@testable import Conductor

/// Builds plausible hands without a camera. Coordinates are Vision-style (origin bottom-left).
enum PoseFixtures {
    /// Open hand, fingers pointing up, wrist at (0.5, 0.3). Scale (wrist to index MCP) is 0.1.
    static func openHand(at wrist: CGPoint = CGPoint(x: 0.5, y: 0.3)) -> HandPose {
        var j: [HandJoint: CGPoint] = [:]
        func put(_ joint: HandJoint, _ dx: CGFloat, _ dy: CGFloat) {
            j[joint] = CGPoint(x: wrist.x + dx, y: wrist.y + dy)
        }
        put(.wrist, 0, 0)
        put(.thumbCMC, -0.03, 0.02); put(.thumbMP, -0.06, 0.05); put(.thumbIP, -0.08, 0.08); put(.thumbTip, -0.10, 0.11)
        put(.indexMCP, -0.03, 0.095); put(.indexPIP, -0.035, 0.14); put(.indexDIP, -0.04, 0.17); put(.indexTip, -0.045, 0.20)
        put(.middleMCP, 0.0, 0.10); put(.middlePIP, 0.0, 0.15); put(.middleDIP, 0.0, 0.185); put(.middleTip, 0.0, 0.22)
        put(.ringMCP, 0.03, 0.095); put(.ringPIP, 0.035, 0.14); put(.ringDIP, 0.04, 0.17); put(.ringTip, 0.045, 0.20)
        put(.littleMCP, 0.055, 0.085); put(.littlePIP, 0.065, 0.12); put(.littleDIP, 0.07, 0.14); put(.littleTip, 0.075, 0.16)
        return HandPose(joints: j, confidence: j.mapValues { _ in 1 }, chirality: .right)
    }

    /// Same hand with the thumb tip touching the given finger tip.
    static func pinched(_ finger: HandJoint = .indexTip, at wrist: CGPoint = CGPoint(x: 0.5, y: 0.3)) -> HandPose {
        var hand = openHand(at: wrist)
        let target = hand[finger]!
        hand.joints[.thumbTip] = CGPoint(x: target.x - 0.005, y: target.y)
        if finger == .indexTip {
            hand.joints[.indexTip] = CGPoint(x: target.x + 0.005, y: target.y)
        }
        return hand
    }

    /// Index and middle up, ring and little curled down to their knuckles.
    static func twoFingers(at wrist: CGPoint = CGPoint(x: 0.5, y: 0.3)) -> HandPose {
        var hand = openHand(at: wrist)
        for (tip, mcp) in [(HandJoint.ringTip, HandJoint.ringMCP), (.littleTip, .littleMCP)] {
            let knuckle = hand[mcp]!
            hand.joints[tip] = CGPoint(x: knuckle.x, y: knuckle.y - 0.01)
        }
        return hand
    }

    /// Two fingers up with the index crossed over the middle: its tip lands on the little-finger
    /// side of the middle tip.
    static func crossed(at wrist: CGPoint = CGPoint(x: 0.5, y: 0.3)) -> HandPose {
        var hand = twoFingers(at: wrist)
        hand.joints[.indexTip] = CGPoint(x: wrist.x + 0.012, y: wrist.y + 0.20)
        hand.joints[.middleTip] = CGPoint(x: wrist.x - 0.01, y: wrist.y + 0.215)
        return hand
    }

    /// Index out, the others curled. `bend` 0 is the index straight up; 1 curls its tip down below
    /// the knuckle, which also makes the hand a fist. `tuckedThumb` rests the thumb where the
    /// curled index tip lands.
    static func pointing(bend: CGFloat = 0, tuckedThumb: Bool = false,
                         at wrist: CGPoint = CGPoint(x: 0.5, y: 0.3)) -> HandPose {
        var hand = twoFingers(at: wrist)
        let middle = hand[.middleMCP]!
        hand.joints[.middleTip] = CGPoint(x: middle.x, y: middle.y - 0.01)
        let knuckle = hand[.indexMCP]!
        let straight = hand[.indexTip]!
        hand.joints[.indexTip] = CGPoint(x: straight.x, y: straight.y + (knuckle.y - 0.01 - straight.y) * bend)
        if tuckedThumb {
            hand.joints[.thumbTip] = CGPoint(x: straight.x + 0.005, y: knuckle.y - 0.01)
        }
        return hand
    }

    /// Pointing straight at the lens: the index joints bunch up over the knuckle, and the tip
    /// lands on the thumb in the picture without touching it.
    static func aimedAtCamera(at wrist: CGPoint = CGPoint(x: 0.5, y: 0.3)) -> HandPose {
        var hand = pointing(at: wrist)
        let knuckle = hand[.indexMCP]!
        hand.joints[.indexPIP] = CGPoint(x: knuckle.x, y: knuckle.y + 0.01)
        hand.joints[.indexDIP] = CGPoint(x: knuckle.x, y: knuckle.y + 0.015)
        hand.joints[.indexTip] = CGPoint(x: knuckle.x, y: knuckle.y + 0.02)
        hand.joints[.thumbTip] = CGPoint(x: knuckle.x - 0.005, y: knuckle.y + 0.02)
        return hand
    }

    /// Fingers curled so every fingertip is nearer the wrist than its PIP joint.
    static func fist(at wrist: CGPoint = CGPoint(x: 0.5, y: 0.3)) -> HandPose {
        var hand = openHand(at: wrist)
        for (tip, mcp) in [(HandJoint.indexTip, HandJoint.indexMCP), (.middleTip, .middleMCP),
                           (.ringTip, .ringMCP), (.littleTip, .littleMCP)] {
            let knuckle = hand[mcp]!
            hand.joints[tip] = CGPoint(x: knuckle.x, y: knuckle.y - 0.01)
        }
        return hand
    }
}

extension GestureRecognizer.Config {
    /// Pinches engage on their first frame. For tests about everything else.
    static var instant: Self {
        var config = Self()
        config.pinchHold = 0
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
}
