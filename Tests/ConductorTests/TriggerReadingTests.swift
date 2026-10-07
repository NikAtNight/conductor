import XCTest
@testable import Conductor

final class TriggerReadingTests: XCTestCase {
    let config = GestureRecognizer.Config()

    private func read(_ trigger: Trigger, _ hand: HandPose, other: HandPose? = nil,
                      config: GestureRecognizer.Config? = nil) -> TriggerReading {
        TriggerReading.of(trigger, primary: hand, other: other, config: config ?? self.config)
    }

    private func left(_ hand: HandPose) -> HandPose {
        var flipped = HandSignView.flipped(hand)
        flipped.chirality = .left
        return flipped
    }

    // MARK: Readings

    func testEachPinchReadsItsOwnFinger() {
        for pinch in Trigger.pinches {
            let made = read(pinch, PoseFixtures.pinched(pinch.fingertip!))
            XCTAssertTrue(made.canStart, "\(pinch)")
            XCTAssertLessThan(made.value!, config.pinchEngage, "\(pinch)")
            let open = read(pinch, PoseFixtures.openHand())
            XCTAssertFalse(open.canStart, "\(pinch)")
            XCTAssertGreaterThan(open.value!, config.pinchEngage, "\(pinch)")
        }
    }

    func testAPinchUsesTheThresholdItIsGiven() {
        var tight = config
        tight.pinchEngage = 0.01
        XCTAssertFalse(read(.indexPinch, PoseFixtures.pinched(), config: tight).canStart)
    }

    func testAFingerAimedAtTheCameraHasADistanceButCannotPinch() {
        let reading = read(.indexPinch, PoseFixtures.aimedAtCamera())
        XCTAssertLessThan(reading.value!, config.pinchEngage, "the tip covers the thumb in the picture")
        XCTAssertFalse(reading.canStart)
    }

    func testTheThumbOnCurledFingersCannotPinchThem() {
        var hand = PoseFixtures.pointing()
        let middle = hand[.middleTip]!
        hand.joints[.thumbTip] = CGPoint(x: middle.x - 0.005, y: middle.y)
        let reading = read(.middlePinch, hand)
        XCTAssertLessThan(reading.value!, config.pinchEngage)
        XCTAssertFalse(reading.canStart)
    }

    func testShapesHaveNoNumber() {
        XCTAssertEqual(read(.fist, PoseFixtures.fist()), TriggerReading(value: nil, canStart: true))
        XCTAssertEqual(read(.fist, PoseFixtures.openHand()), TriggerReading(value: nil, canStart: false))
        XCTAssertEqual(read(.twoFingers, PoseFixtures.twoFingers()), TriggerReading(value: nil, canStart: true))
        XCTAssertEqual(read(.twoFingers, PoseFixtures.openHand()), TriggerReading(value: nil, canStart: false))
    }

    func testSwipesCannotBeReadFromOneFrame() {
        for swipe in Trigger.swipes {
            XCTAssertEqual(read(swipe, PoseFixtures.twoFingers()), TriggerReading(value: nil, canStart: false))
        }
    }

    func testCrossedFingersReadPastTheEngageThreshold() {
        let crossed = read(.crossedFingers, PoseFixtures.crossed())
        XCTAssertTrue(crossed.canStart)
        XCTAssertGreaterThan(crossed.value!, config.crossEngage)
        let apart = read(.crossedFingers, PoseFixtures.twoFingers())
        XCTAssertFalse(apart.canStart)
        XCTAssertLessThan(apart.value!, 0)
        var strict = config
        strict.crossEngage = 5
        XCTAssertFalse(read(.crossedFingers, PoseFixtures.crossed(), config: strict).canStart)
    }

    func testThePointingSignReadsTheThumbAndTheDirection() {
        for direction in [Direction.up, .down, .left, .right] {
            let reading = read(.indexPoint, PoseFixtures.pointingSign(direction))
            XCTAssertTrue(reading.canStart, "\(direction)")
            XCTAssertEqual(reading.direction, direction)
            XCTAssertGreaterThan(reading.value!, HandPose.pointingThumbOut)
        }
        var unmirrored = config
        unmirrored.mirrored = false
        XCTAssertEqual(read(.indexPoint, PoseFixtures.pointingSign(.right, mirrored: false), config: unmirrored).direction, .right)

        let relaxed = read(.indexPoint, PoseFixtures.pointing(tuckedThumb: true))
        XCTAssertFalse(relaxed.canStart)
        XCTAssertNil(relaxed.direction)
        XCTAssertLessThan(relaxed.value!, HandPose.pointingThumbOut)
        XCTAssertFalse(read(.indexPoint, PoseFixtures.aimedAtCamera()).canStart, "too short to read a direction")
    }

    func testBothHandsReadTheWiderPinch() {
        let pinched = PoseFixtures.pinched(at: CGPoint(x: 0.3, y: 0.3))
        let both = read(.twoHandPinch, pinched, other: left(PoseFixtures.pinched(at: CGPoint(x: 0.7, y: 0.3))))
        XCTAssertTrue(both.canStart)
        let open = left(PoseFixtures.openHand(at: CGPoint(x: 0.7, y: 0.3)))
        let oneOpen = read(.twoHandPinch, pinched, other: open)
        XCTAssertFalse(oneOpen.canStart)
        XCTAssertEqual(oneOpen.value!, open.normalizedDistance(.thumbTip, .indexTip)!, accuracy: 1e-9)
        XCTAssertEqual(read(.twoHandPinch, pinched), TriggerReading(value: nil, canStart: false), "one hand")
    }

    func testTheReadyPoseReadsTheThumbAndTheOpenHand() {
        let open = TriggerReading.readyPose(PoseFixtures.openHand())
        XCTAssertTrue(open.canStart)
        XCTAssertGreaterThan(open.value!, HandPose.openHandThumbOut)
        XCTAssertFalse(TriggerReading.readyPose(PoseFixtures.fist()).canStart)
    }

    // MARK: Agreement with the recognizer

    /// Every fixture hand, so each trigger is tried on its own shape and on everyone else's.
    private let hands: [(name: String, pose: HandPose)] = [
        ("open", PoseFixtures.openHand()),
        ("index pinch", PoseFixtures.pinched(.indexTip)),
        ("middle pinch", PoseFixtures.pinched(.middleTip)),
        ("ring pinch", PoseFixtures.pinched(.ringTip)),
        ("little pinch", PoseFixtures.pinched(.littleTip)),
        ("fist", PoseFixtures.fist()),
        ("two fingers", PoseFixtures.twoFingers()),
        ("crossed", PoseFixtures.crossed()),
        ("pointing", PoseFixtures.pointing()),
        ("relaxed pointing", PoseFixtures.pointing(tuckedThumb: true)),
        ("curled pointing", PoseFixtures.pointing(bend: 1)),
        ("pointing down", PoseFixtures.pointingSign(.down)),
        ("pointing left", PoseFixtures.pointingSign(.left)),
        ("pointing right", PoseFixtures.pointingSign(.right)),
        ("aimed at camera", PoseFixtures.aimedAtCamera()),
    ]

    /// With only `trigger` bound, holding `hand` long enough for any hold fires it exactly when the
    /// reading says it can start. Holds are the recognizer's; the shape test must be the reading's.
    func testTheRecognizerStartsAOneHandedTriggerExactlyWhenItsReadingCan() {
        let oneHanded: [Trigger] = Trigger.pinches + [.fist, .twoFingers, .crossedFingers, .indexPoint]
        for trigger in oneHanded {
            let readings = hands.map { TriggerReading.of(trigger, primary: $0.pose, other: nil, config: .instant) }
            XCTAssertTrue(readings.contains { $0.canStart } && readings.contains { !$0.canStart },
                          "\(trigger) is tried both made and not made")
            for (name, hand) in hands {
                var map = GestureMap(bindings: [:])
                map[trigger] = .rightClick
                var recognizer = GestureRecognizer(config: .instant, map: map)
                var fired = false
                for frame in 0..<20 {
                    fired = fired || recognizer.update(hands: [hand], at: Double(frame) / 30).actions.contains(.rightClick)
                }
                let reading = TriggerReading.of(trigger, primary: hand, other: nil, config: .instant)
                XCTAssertEqual(fired, reading.canStart, "\(trigger) on \(name)")
            }
        }
    }

    func testTheRecognizerStartsTheTwoHandPinchExactlyWhenItsReadingCan() {
        let pinched = PoseFixtures.pinched(at: CGPoint(x: 0.3, y: 0.3))
        let others = [left(PoseFixtures.pinched(at: CGPoint(x: 0.7, y: 0.3))),
                      left(PoseFixtures.openHand(at: CGPoint(x: 0.7, y: 0.3)))]
        for other in others {
            var map = GestureMap(bindings: [:])
            map[.twoHandPinch] = .rightClick
            var recognizer = GestureRecognizer(config: .instant, map: map)
            let fired = recognizer.update(hands: [pinched, other], at: 0).actions.contains(.rightClick)
            let reading = TriggerReading.of(.twoHandPinch, primary: pinched, other: other, config: .instant)
            XCTAssertEqual(fired, reading.canStart)
        }
    }
}
