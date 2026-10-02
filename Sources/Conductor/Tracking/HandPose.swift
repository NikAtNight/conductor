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

    /// The point the cursor follows. Midway between thumb and index tips so a pinch, which
    /// moves both tips toward each other, leaves the cursor almost still.
    var pointer: CGPoint? {
        guard let thumb = self[.thumbTip], let index = self[.indexTip] else { return nil }
        return CGPoint(x: (thumb.x + index.x) / 2, y: (thumb.y + index.y) / 2)
    }

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

    /// True when index, middle, ring and little fingertips are all closer to the wrist than
    /// their own knuckles are, which only happens with curled fingers.
    var isFist: Bool {
        guard let wrist = self[.wrist] else { return false }
        let fingers: [(tip: HandJoint, pip: HandJoint)] = [
            (.indexTip, .indexPIP), (.middleTip, .middlePIP), (.ringTip, .ringPIP), (.littleTip, .littlePIP),
        ]
        for finger in fingers {
            guard let tip = self[finger.tip], let pip = self[finger.pip] else { return false }
            if tip.distance(to: wrist) >= pip.distance(to: wrist) { return false }
        }
        return true
    }
}

extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        let dx = x - other.x
        let dy = y - other.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
