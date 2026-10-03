import CoreGraphics

/// The 21 hand landmarks Vision reports, named so the gesture code reads like anatomy
/// instead of a lookup table.
enum HandJoint: CaseIterable, Hashable {
    case wrist
    case thumbCMC, thumbMP, thumbIP, thumbTip
    case indexMCP, indexPIP, indexDIP, indexTip
    case middleMCP, middlePIP, middleDIP, middleTip
    case ringMCP, ringPIP, ringDIP, ringTip
    case littleMCP, littlePIP, littleDIP, littleTip
}

enum Chirality {
    case left, right, unknown
}

/// One detected hand. Points are normalized to the camera frame with Vision's convention:
/// origin bottom-left, x right, y up. Nothing here is mirrored yet; that happens in ScreenMapper.
struct HandPose: Equatable {
    var joints: [HandJoint: CGPoint]
    var confidence: [HandJoint: Float]
    var chirality: Chirality

    subscript(_ joint: HandJoint) -> CGPoint? { joints[joint] }

    /// Distance from wrist to the index knuckle. Roughly constant for a given hand no matter
    /// how the fingers move, so it works as a scale reference that cancels out camera distance.
    var scale: CGFloat? {
        guard let wrist = self[.wrist], let mcp = self[.indexMCP] else { return nil }
        return wrist.distance(to: mcp)
    }

    /// Distance between two joints divided by hand scale. Returns nil when either joint is missing.
    func normalizedDistance(_ a: HandJoint, _ b: HandJoint) -> CGFloat? {
        guard let pa = self[a], let pb = self[b], let scale, scale > 0 else { return nil }
        return pa.distance(to: pb) / scale
    }

    /// The point the cursor follows: the index knuckle. Pinching, raising two fingers, and curling
    /// into a fist all move the fingertips, not the knuckle, so none of them drag the cursor.
    var pointer: CGPoint? { self[.indexMCP] }

    /// Index knuckle to little knuckle. Runs across the hand, so unlike `scale` it keeps its length
    /// when the fingers point at the camera.
    var palmWidth: CGFloat? {
        guard let index = self[.indexMCP], let little = self[.littleMCP] else { return nil }
        return index.distance(to: little)
    }

    /// How long a finger looks to the camera, knuckle to tip along its joints, in palm widths. A
    /// finger aimed straight at the lens looks short, and then its tip can sit on top of the thumb
    /// in the picture without touching it.
    func visibleLength(of tip: HandJoint) -> CGFloat? {
        guard let chain = Self.fingerChains[tip], let width = palmWidth, width > 0 else { return nil }
        let points = chain.compactMap { self[$0] }
        guard points.count == chain.count else { return nil }
        return zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) } / width
    }

    /// How far the index fingertip sits above its knuckle in the picture, in palm widths. Bending
    /// the finger changes it; moving the whole hand doesn't. Logged for tuning.
    var indexLift: CGFloat? {
        guard let tip = self[.indexTip], let knuckle = self[.indexMCP], let width = palmWidth, width > 0 else { return nil }
        return (tip.y - knuckle.y) / width
    }

    private static let fingerChains: [HandJoint: [HandJoint]] = [
        .indexTip: [.indexMCP, .indexPIP, .indexDIP, .indexTip],
        .middleTip: [.middleMCP, .middlePIP, .middleDIP, .middleTip],
        .ringTip: [.ringMCP, .ringPIP, .ringDIP, .ringTip],
        .littleTip: [.littleMCP, .littlePIP, .littleDIP, .littleTip],
    ]

    /// Palm center: average of wrist and the four finger knuckles. Used for scroll motion.
    var palmCenter: CGPoint? {
        let keys: [HandJoint] = [.wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP]
        let points = keys.compactMap { self[$0] }
        guard points.count == keys.count else { return nil }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    /// True when all four fingers are straight and the thumb is out and away from the index finger.
    /// This is the "ready" pose: a flat, open hand. A curled typing hand or a pinch never matches.
    var isOpenHand: Bool {
        guard let wrist = self[.wrist] else { return false }
        let fingers: [(tip: HandJoint, pip: HandJoint)] = [
            (.indexTip, .indexPIP), (.middleTip, .middlePIP), (.ringTip, .ringPIP), (.littleTip, .littlePIP),
        ]
        for finger in fingers {
            guard let tip = self[finger.tip], let pip = self[finger.pip] else { return false }
            // A straight finger reaches clearly past its middle knuckle.
            if tip.distance(to: wrist) < pip.distance(to: wrist) * 1.1 { return false }
        }
        guard let thumbOut = normalizedDistance(.thumbTip, .indexMCP),
              let thumbToIndex = normalizedDistance(.thumbTip, .indexTip) else { return false }
        return thumbOut > 0.5 && thumbToIndex > 0.6
    }

    /// Index and middle straight, ring and little curled: the "peace sign" used for swipes.
    var isTwoFingerPose: Bool {
        guard let wrist = self[.wrist] else { return false }
        func reach(_ tip: HandJoint, _ pip: HandJoint) -> CGFloat? {
            guard let t = self[tip], let p = self[pip] else { return nil }
            return t.distance(to: wrist) / max(p.distance(to: wrist), 0.0001)
        }
        guard let index = reach(.indexTip, .indexPIP), let middle = reach(.middleTip, .middlePIP),
              let ring = reach(.ringTip, .ringPIP), let little = reach(.littleTip, .littlePIP) else { return false }
        return index > 1.1 && middle > 1.1 && ring < 1.0 && little < 1.0
    }

    /// True when index, middle, ring and little fingertips are all closer to the wrist than
    /// their own knuckles are, which only happens with curled fingers.
    var isFist: Bool {
        isCurled(.indexTip, .indexPIP) && othersCurled
    }

    /// Middle, ring and little curled: a pointing hand, whatever the index finger is doing.
    var othersCurled: Bool {
        isCurled(.middleTip, .middlePIP) && isCurled(.ringTip, .ringPIP) && isCurled(.littleTip, .littlePIP)
    }

    private func isCurled(_ tip: HandJoint, _ pip: HandJoint) -> Bool {
        guard let wrist = self[.wrist], let t = self[tip], let p = self[pip] else { return false }
        return t.distance(to: wrist) < p.distance(to: wrist)
    }
}

extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        let dx = x - other.x
        let dy = y - other.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
