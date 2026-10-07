import CoreGraphics

/// One trigger read from one frame of hands: the number the recognizer decides with, and whether
/// the trigger could start on this frame with the current thresholds. Stateless. The recognizer
/// starts triggers from it and adds everything that takes time (holds, hysteresis, debouncing,
/// which trigger wins). The gesture check reads the same thing, so what it scores is what the
/// recognizer would start on.
struct TriggerReading: Equatable {
    /// The number the recognizer decides with, or nil when it can't be read this frame. Always nil
    /// for plain shapes (fist, two fingers) and for swipes, which happen over time.
    var value: CGFloat?
    /// Whether the trigger's own test passes this frame with the current thresholds. This is the
    /// recognizer's start condition, not the hold: a pinch still has to hold `pinchHold`, a cross
    /// `crossHold`, and so on.
    var canStart: Bool
    /// For the pointing sign: which way the index points, as the user sees it. Nil when it can't start.
    var direction: Direction? = nil

    static func of(_ trigger: Trigger, primary hand: HandPose, other: HandPose?,
                   config: GestureRecognizer.Config) -> TriggerReading {
        switch trigger {
        case .indexPinch, .middlePinch, .ringPinch, .littlePinch:
            let tip = trigger.fingertip!
            let distance = hand.normalizedDistance(.thumbTip, tip)
            return TriggerReading(value: distance,
                                  canStart: (distance ?? .infinity) < config.pinchEngage
                                      && pinchFingerClear(hand, tip, config: config))
        case .fist:
            return TriggerReading(value: nil, canStart: hand.isFist)
        case .twoFingers:
            return TriggerReading(value: nil, canStart: hand.isTwoFingerPose)
        case .crossedFingers:
            // Only a held cross may lean on the last joints (see HandPose.fingerCross).
            let cross = hand.fingerCross(holding: false)
            return TriggerReading(value: cross, canStart: (cross ?? -.infinity) > config.crossEngage)
        case .indexPoint:
            let direction = pointDirection(hand, config: config)
            return TriggerReading(value: hand.normalizedDistance(.thumbTip, .indexMCP),
                                  canStart: direction != nil, direction: direction)
        case .twoHandPinch:
            // Both hands must be under the threshold, so the wider pinch decides.
            guard let mine = hand.normalizedDistance(.thumbTip, .indexTip),
                  let theirs = other?.normalizedDistance(.thumbTip, .indexTip) else {
                return TriggerReading(value: nil, canStart: false)
            }
            let wider = max(mine, theirs)
            return TriggerReading(value: wider, canStart: wider < config.twoHandPinchEngage)
        case .swipeLeft, .swipeRight:
            return TriggerReading(value: nil, canStart: false)
        }
    }

    /// The ready pose isn't a trigger, but it's read the same way: the thumb out, and the open hand.
    static func readyPose(_ hand: HandPose) -> TriggerReading {
        TriggerReading(value: hand.normalizedDistance(.thumbTip, .indexMCP), canStart: hand.isOpenHand)
    }

    /// Whether a pinch on this finger can be told from the picture, however close the tips are.
    /// False when the finger points at the camera, where its tip can cover the thumb without
    /// touching it. Also false for a middle, ring or little pinch while those three are curled into
    /// the palm: pointing rests the thumb on them anyway.
    static func pinchFingerClear(_ hand: HandPose, _ fingertip: HandJoint, config: GestureRecognizer.Config) -> Bool {
        (fingertip == .indexTip || !hand.othersCurled)
            && (hand.visibleLength(of: fingertip) ?? 0) >= config.minimumFingerLength
    }

    /// Which way the index finger points in the pointing sign, as the user sees it. Nil outside
    /// the sign, and nil when the finger looks too short to read, which is a finger aimed at the
    /// lens. The larger axis wins, so a slightly tilted finger still reads as up or down.
    private static func pointDirection(_ hand: HandPose, config: GestureRecognizer.Config) -> Direction? {
        guard hand.isPointingSign, let v = hand.indexVector,
              (hand.visibleLength(of: .indexTip) ?? 0) >= config.minimumFingerLength else { return nil }
        // Vision x grows to the camera's right. With mirroring that is the user's left.
        let dx = v.dx * (config.mirrored ? -1 : 1)
        if abs(v.dy) >= abs(dx) { return v.dy > 0 ? .up : .down }
        return dx > 0 ? .right : .left
    }
}
