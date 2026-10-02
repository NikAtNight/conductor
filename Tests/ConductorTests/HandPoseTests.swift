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

    func testPointerIsMidpointOfThumbAndIndex() {
        let hand = PoseFixtures.openHand()
        let p = hand.pointer!
        XCTAssertEqual(p.x, (hand[.thumbTip]!.x + hand[.indexTip]!.x) / 2, accuracy: 1e-9)
        XCTAssertEqual(p.y, (hand[.thumbTip]!.y + hand[.indexTip]!.y) / 2, accuracy: 1e-9)
    }
}
