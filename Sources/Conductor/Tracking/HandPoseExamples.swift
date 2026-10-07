import CoreGraphics

/// Plausible hands built without a camera, in Vision space (origin bottom-left, un-mirrored). Each
/// one passes the detector for its shape, so they double as the pictures that show a user what to
/// do and as the fixtures the tests drive the recognizer with.
enum HandPoseExamples {
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
    /// side of the middle tip, about a third of a palm width past it like a real cross.
    static func crossed(at wrist: CGPoint = CGPoint(x: 0.5, y: 0.3)) -> HandPose {
        var hand = twoFingers(at: wrist)
        hand.joints[.indexTip] = CGPoint(x: wrist.x + 0.02, y: wrist.y + 0.20)
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

    /// The pointing sign aimed the user's way: `pointing()` with the whole hand turned about the
    /// wrist, the way a hand really points down or sideways. Vision x grows to the camera's right,
    /// so with mirroring the user's right is -x.
    static func pointingSign(_ direction: Direction, mirrored: Bool = true,
                             at wrist: CGPoint = CGPoint(x: 0.5, y: 0.3)) -> HandPose {
        var hand = pointing(at: wrist)
        let sideways: CGFloat = mirrored ? -1 : 1
        for (joint, p) in hand.joints {
            let dx = p.x - wrist.x, dy = p.y - wrist.y
            let turned: CGPoint
            switch direction {
            case .up: turned = CGPoint(x: dx, y: dy)
            case .down: turned = CGPoint(x: -dx, y: -dy)
            case .right: turned = CGPoint(x: sideways * dy, y: -sideways * dx)
            case .left: turned = CGPoint(x: -sideways * dy, y: sideways * dx)
            }
            hand.joints[joint] = CGPoint(x: wrist.x + turned.x, y: wrist.y + turned.y)
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
