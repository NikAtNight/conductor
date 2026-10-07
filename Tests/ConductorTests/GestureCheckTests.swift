import XCTest
@testable import Conductor

final class GestureCheckTests: XCTestCase {
    let dt = 1.0 / 30
    let config = GestureRecognizer.Config()

    private func step(_ id: String) throws -> GestureCheck.Step {
        try XCTUnwrap(GestureCheck.allSteps(config: config).first { $0.id == id }, id)
    }

    /// Feeds `frames` copies of `hands`, one frame apart, and returns the phase.
    private func phase(_ step: GestureCheck.Step, _ hands: [HandPose], frames: Int = 30) -> GestureCheck.Phase {
        var sampler = GestureCheck.Sampler(step: step)
        for i in 0..<frames { sampler.add(hands, at: Double(i) * dt) }
        return sampler.phase
    }

    /// A right open hand with the thumb tip `scales` hand scales from the index knuckle.
    private func openHand(thumbOut scales: CGFloat) -> HandPose {
        var hand = PoseFixtures.openHand()
        let knuckle = hand[.indexMCP]!, scale = hand.scale!
        hand.joints[.thumbTip] = CGPoint(x: knuckle.x - scales * scale, y: knuckle.y)
        return hand
    }

    private func left(_ hand: HandPose) -> HandPose {
        var flipped = HandSignView.flipped(hand)
        flipped.chirality = .left
        return flipped
    }

    func testEveryTriggerIsCheckedOnBothHandsAndBothHandsOnce() {
        let steps = GestureCheck.allSteps(config: config)
        for hand in GestureCheck.Hand.allCases {
            let triggers = Set(steps.filter { $0.hand == hand }.compactMap(\.trigger))
            // Both swipes are one flick step; the two-hand pinch has its own step.
            XCTAssertEqual(triggers, Set(Trigger.allCases).subtracting([.swipeRight, .twoHandPinch]), "\(hand)")
            XCTAssertTrue(steps.contains { $0.hand == hand && $0.trigger == nil }, "the ready pose, \(hand)")
        }
        XCTAssertEqual(steps.filter { $0.hand == nil }.map(\.trigger), [.twoHandPinch])
        XCTAssertEqual(Set(steps.map(\.id)).count, steps.count, "ids are unique")
    }

    func testAnIndexPinchAgainstAnOpenHandIsClear() throws {
        let pinch = try step("right-indexPinch")
        let made = phase(pinch, [PoseFixtures.pinched()])
        let rest = phase(pinch, [PoseFixtures.openHand()])
        let result = GestureCheck.score(pinch, made: made, rest: rest)
        XCTAssertEqual(result.verdict, .clear)
        XCTAssertEqual(result.made.hitRate, 1)
        XCTAssertEqual(result.rest.hitRate, 0)
        XCTAssertEqual(result.threshold, config.pinchEngage)
        let midpoint = try XCTUnwrap(result.suggestedThreshold)
        XCTAssertGreaterThan(midpoint, made.high!)
        XCTAssertLessThan(midpoint, rest.low!)
    }

    func testNikhilsFlatHandCountsAsOpenAtTheNewThreshold() throws {
        let ready = try step("right-readyPose")
        // His median flat hand (0.43) reads as open; a thumb tucked in (0.3) does not.
        XCTAssertEqual(phase(ready, [openHand(thumbOut: 0.43)]).hitRate, 1)
        XCTAssertEqual(phase(ready, [openHand(thumbOut: 0.3)]).hitRate, 0)
        let result = GestureCheck.score(ready, made: phase(ready, [openHand(thumbOut: 0.43)]),
                                        rest: phase(ready, [openHand(thumbOut: 0.3)]))
        XCTAssertEqual(result.verdict, .clear)
        XCTAssertEqual(result.suggestedThreshold!, 0.365, accuracy: 0.001)
    }

    func testVerdictsFollowTheHitRates() {
        XCTAssertEqual(GestureCheck.verdict(madeRate: 0.95, restRate: 0), .clear)
        XCTAssertEqual(GestureCheck.verdict(madeRate: 0.8, restRate: 0.05), .clear)
        XCTAssertEqual(GestureCheck.verdict(madeRate: 0.6, restRate: 0.1), .weak)
        XCTAssertEqual(GestureCheck.verdict(madeRate: 0.95, restRate: 0.15), .weak)
        XCTAssertEqual(GestureCheck.verdict(madeRate: 0.4, restRate: 0), .refused)
        XCTAssertEqual(GestureCheck.verdict(madeRate: 0.95, restRate: 0.3), .refused)
    }

    func testTooFewFramesWithTheHandIsUnseen() throws {
        let fist = try step("right-fist")
        let made = phase(fist, [PoseFixtures.fist()], frames: GestureCheck.minimumFrames - 1)
        let rest = phase(fist, [PoseFixtures.openHand()])
        XCTAssertEqual(GestureCheck.score(fist, made: made, rest: rest).verdict, .unseen)
        XCTAssertEqual(phase(fist, [], frames: 30).seen, 0)
    }

    func testAPredicateStepCountsTheShape() throws {
        let fist = try step("right-fist")
        let result = GestureCheck.score(fist, made: phase(fist, [PoseFixtures.fist()]), rest: phase(fist, [PoseFixtures.openHand()]))
        XCTAssertEqual(result.kind, "predicate")
        XCTAssertNil(result.threshold)
        XCTAssertEqual(result.verdict, .clear)
    }

    func testTheLeftHandStepWatchesTheHandTheRecognizerWould() throws {
        let fist = try step("left-fist")
        // Right fist and left open hand both in view: the left step sees the open hand.
        XCTAssertEqual(phase(fist, [PoseFixtures.fist(), left(PoseFixtures.openHand())]).hitRate, 0)
        XCTAssertEqual(phase(fist, [left(PoseFixtures.fist()), PoseFixtures.openHand()]).hitRate, 1)
        // One hand Vision can't tell: taken as the hand being checked.
        var unknown = PoseFixtures.fist()
        unknown.chirality = .unknown
        XCTAssertEqual(phase(fist, [unknown]).hitRate, 1)
        // Two hands, neither left: the first, as the recognizer picks its main hand.
        XCTAssertEqual(phase(fist, [PoseFixtures.fist(), unknown]).hitRate, 1)
        XCTAssertEqual(phase(fist, [unknown, PoseFixtures.openHand()]).hitRate, 1)
    }

    func testAFlickReachesTheSwipeDistanceAndScrollingDoesNot() throws {
        let swipe = try step("right-swipe")
        var made = GestureCheck.Sampler(step: swipe)
        // 0.06 sideways over six frames, held still before and after.
        var t = 0.0
        for _ in 0..<15 { made.add([PoseFixtures.twoFingers(at: CGPoint(x: 0.5, y: 0.3))], at: t); t += dt }
        for i in 1...6 { made.add([PoseFixtures.twoFingers(at: CGPoint(x: 0.5 - 0.01 * CGFloat(i), y: 0.3))], at: t); t += dt }
        for _ in 0..<15 { made.add([PoseFixtures.twoFingers(at: CGPoint(x: 0.44, y: 0.3))], at: t); t += dt }
        var rest = GestureCheck.Sampler(step: swipe)
        t = 0
        for i in 0..<40 { rest.add([PoseFixtures.twoFingers(at: CGPoint(x: 0.5, y: 0.3 + 0.002 * CGFloat(i)))], at: t); t += dt }
        let result = GestureCheck.score(swipe, made: made.phase, rest: rest.phase)
        XCTAssertEqual(result.kind, "peak")
        XCTAssertEqual(made.phase.peak!, 0.06, accuracy: 0.001)
        XCTAssertEqual(rest.phase.peak!, 0, accuracy: 0.001)
        XCTAssertEqual(result.verdict, .clear)
        XCTAssertEqual(result.suggestedThreshold!, 0.03, accuracy: 0.001)
    }

    func testTheFlickIsMeasuredOverTheRecognizersSwipeWindow() throws {
        var short = config
        short.swipeWindow = 0.05
        let swipe = try XCTUnwrap(GestureCheck.allSteps(config: short).first { $0.id == "right-swipe" })
        var sampler = GestureCheck.Sampler(step: swipe)
        // 0.01 sideways a frame. A 0.05 s window spans one frame's travel; the default 0.25 would see 0.07.
        for i in 0..<10 { sampler.add([PoseFixtures.twoFingers(at: CGPoint(x: 0.5 - 0.01 * CGFloat(i), y: 0.3))], at: Double(i) * dt) }
        XCTAssertEqual(sampler.phase.peak!, 0.01, accuracy: 0.001)
    }

    func testTheFlickOnlyCountsInTheTwoFingerPose() throws {
        let swipe = try step("right-swipe")
        var sampler = GestureCheck.Sampler(step: swipe)
        for i in 0..<10 { sampler.add([PoseFixtures.openHand(at: CGPoint(x: 0.5 - 0.02 * CGFloat(i), y: 0.3))], at: Double(i) * dt) }
        XCTAssertEqual(sampler.phase.readable, 0)
        XCTAssertEqual(sampler.phase.seen, 10)
    }

    func testBothHandsNeedsTwoHandsAndReadsTheWiderPinch() throws {
        let both = try step("both-twoHandPinch")
        let pinched = [PoseFixtures.pinched(at: CGPoint(x: 0.3, y: 0.3)), left(PoseFixtures.pinched(at: CGPoint(x: 0.3, y: 0.3)))]
        XCTAssertEqual(phase(both, pinched).hitRate, 1)
        XCTAssertEqual(phase(both, [PoseFixtures.pinched()]).seen, 0, "one hand is not both hands")
        let oneOpen = [PoseFixtures.pinched(at: CGPoint(x: 0.3, y: 0.3)), left(PoseFixtures.openHand(at: CGPoint(x: 0.3, y: 0.3)))]
        let phase = phase(both, oneOpen)
        XCTAssertEqual(phase.hitRate, 0)
        XCTAssertEqual(phase.median!, Double(PoseFixtures.openHand().normalizedDistance(.thumbTip, .indexTip)!), accuracy: 1e-6)
    }

    func testTheSummaryNamesTheVerdictAndTheNumbers() throws {
        let pinch = try step("right-indexPinch")
        let result = GestureCheck.score(pinch, made: phase(pinch, [PoseFixtures.pinched()]), rest: phase(pinch, [PoseFixtures.openHand()]))
        let line = GestureCheck.summary(result)
        XCTAssertTrue(line.hasPrefix("Right hand, Thumb + index pinch: clear, read 100% made, 0% at rest; made "), line)
        XCTAssertTrue(line.contains("threshold 0.35"), line)
        XCTAssertTrue(line.contains("midpoint"), line)
    }

    func testAReportSavesAsJSONBesideTheLogs() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "GestureCheckTests.\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pinch = try step("right-indexPinch")
        let result = GestureCheck.score(pinch, made: phase(pinch, [PoseFixtures.pinched()]), rest: phase(pinch, [PoseFixtures.openHand()]))
        let report = GestureCheck.Report(date: Date(timeIntervalSince1970: 1_791_325_123), results: [result])
        let url = try GestureCheck.save(report, to: dir)
        XCTAssertTrue(url.lastPathComponent.hasPrefix("gesture-check-"), url.lastPathComponent)
        XCTAssertEqual(url.pathExtension, "json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(GestureCheck.Report.self, from: Data(contentsOf: url)), report)
    }
}
