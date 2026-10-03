import XCTest
@testable import Conductor

/// Crossed fingers switch scroll mode on and off; in it, the relaxed hand scrolls from neutral.
final class ScrollModeTests: XCTestCase {
    typealias Action = GestureRecognizer.Action
    let dt = 1.0 / 30
    var r = GestureRecognizer()
    var t = 0.0
    var actions: [Action] = []
    var events: [GestureRecognizer.Event] = []
    var last: GestureRecognizer.Output!

    override func setUp() {
        super.setUp()
        var map = GestureMap.standard
        map[.crossedFingers] = .scrollMode
        r = GestureRecognizer(config: .instant, map: map)
    }

    private func frame(_ hands: [HandPose], count: Int = 1) {
        for _ in 0..<count {
            last = r.update(hands: hands, at: t)
            actions += last.actions
            events += last.events
            t += dt
        }
    }

    private func frames(_ hand: HandPose, for seconds: TimeInterval) {
        frame([hand], count: Int((seconds / dt).rounded(.up)))
    }

    private var travel: [CGFloat] {
        actions.compactMap { if case .scroll(let dy) = $0 { return dy } else { return nil } }
    }

    /// Cross long enough to switch, uncross, and settle at `wrist`.
    private func enterScrollMode(restingAt wrist: CGPoint = CGPoint(x: 0.5, y: 0.3)) {
        frame([PoseFixtures.openHand(at: wrist)])
        frames(PoseFixtures.crossed(at: wrist), for: 0.4)
        frames(PoseFixtures.openHand(at: wrist), for: 0.4)
        actions.removeAll()
    }

    func testFingerCrossIsPositiveOnlyWhenCrossed() {
        XCTAssertLessThan(PoseFixtures.openHand().fingerCross!, 0)
        XCTAssertLessThan(PoseFixtures.twoFingers().fingerCross!, 0)
        XCTAssertGreaterThan(PoseFixtures.crossed().fingerCross!, 0.2)
        XCTAssertNil(PoseFixtures.fist().fingerCross, "curled tips don't count")
        var edgeOn = PoseFixtures.crossed()
        // Little knuckle swung in behind the index knuckle: the palm is turned side-on.
        edgeOn.joints[.littleMCP] = CGPoint(x: 0.5, y: 0.39)
        XCTAssertNil(edgeOn.fingerCross, "edge-on fingers line up and can't be read")
    }

    func testCrossingBrieflyDoesNothing() {
        frame([PoseFixtures.openHand()])
        frame([PoseFixtures.crossed()], count: 3)
        frame([PoseFixtures.openHand()])
        XCTAssertFalse(r.inScrollMode)
        XCTAssertTrue(events.isEmpty)
    }

    func testHoldingTheCrossSwitchesInWithoutScrollingOrSwiping() {
        frame([PoseFixtures.openHand()])
        frames(PoseFixtures.crossed(), for: 0.4)
        XCTAssertTrue(r.inScrollMode)
        XCTAssertEqual(events, [.scrollModeOn])
        XCTAssertEqual(last.mode, .scrollMode)
        XCTAssertNil(last.pointer, "the cursor holds still")
        XCTAssertTrue(travel.allSatisfy { $0 == 0 }, "the crossed pose is not the two-finger scroll")
    }

    func testRaisingTheHandScrollsDownAndLoweringScrollsUp() {
        enterScrollMode()
        frames(PoseFixtures.openHand(at: CGPoint(x: 0.5, y: 0.35)), for: 0.5)
        XCTAssertGreaterThan(travel.reduce(0, +), 0)
        XCTAssertEqual(last.feedback.scrollDirection, 1)
        actions.removeAll()
        frames(PoseFixtures.openHand(at: CGPoint(x: 0.5, y: 0.25)), for: 0.5)
        XCTAssertLessThan(travel.reduce(0, +), 0)
        XCTAssertEqual(last.feedback.scrollDirection, -1)
    }

    func testFartherFromNeutralScrollsFaster() {
        enterScrollMode()
        frames(PoseFixtures.openHand(at: CGPoint(x: 0.5, y: 0.33)), for: 0.5)
        let slow = travel.reduce(0, +)
        actions.removeAll()
        frames(PoseFixtures.openHand(at: CGPoint(x: 0.5, y: 0.38)), for: 0.5)
        XCTAssertGreaterThan(travel.reduce(0, +), slow * 2)
    }

    func testSmallWobbleAroundNeutralDoesNotScroll() {
        enterScrollMode()
        for dy in [0.01, -0.01, 0.015, -0.005] as [CGFloat] {
            frame([PoseFixtures.openHand(at: CGPoint(x: 0.5, y: 0.3 + dy))])
        }
        XCTAssertTrue(travel.allSatisfy { $0 == 0 })
        XCTAssertEqual(last.feedback.scrollDirection, 0)
    }

    func testNeutralIsWhereTheHandSettlesAfterUncrossing() {
        frame([PoseFixtures.openHand()])
        frames(PoseFixtures.crossed(), for: 0.4)
        // Uncrossing lands the hand higher. That becomes neutral instead of a scroll.
        frames(PoseFixtures.openHand(at: CGPoint(x: 0.5, y: 0.4)), for: 1)
        XCTAssertTrue(travel.allSatisfy { $0 == 0 })
    }

    func testFingerShapesDoNothingInScrollMode() {
        enterScrollMode()
        frames(PoseFixtures.pinched(), for: 0.3)
        frames(PoseFixtures.fist(), for: 0.3)
        frames(PoseFixtures.pinched(.middleTip), for: 0.3)
        frames(PoseFixtures.twoFingers(at: CGPoint(x: 0.7, y: 0.3)), for: 0.3)
        XCTAssertTrue(actions.allSatisfy { if case .scroll = $0 { return true } else { return false } })
        XCTAssertTrue(r.inScrollMode)
    }

    func testCrossingAgainSwitchesBackOnceAndStopsScrolling() {
        enterScrollMode()
        events.removeAll()
        frames(PoseFixtures.crossed(at: CGPoint(x: 0.5, y: 0.36)), for: 0.5)
        XCTAssertFalse(r.inScrollMode)
        XCTAssertEqual(events, [.scrollModeOff])
        XCTAssertTrue(travel.allSatisfy { $0 == 0 }, "forming the cross doesn't scroll")
        // Still crossed: no flipping straight back in. Uncross and the pointer is back.
        frame([PoseFixtures.openHand()])
        XCTAssertEqual(last.mode, .point)
        XCTAssertNotNil(last.pointer)
        XCTAssertEqual(events, [.scrollModeOff])
    }

    func testUnbindingTheSwitchLeavesScrollMode() {
        enterScrollMode()
        var map = GestureMap.standard
        map[.crossedFingers] = .none
        _ = r.replaceMap(map)
        frame([PoseFixtures.openHand()])
        XCTAssertFalse(r.inScrollMode)
        XCTAssertEqual(last.mode, .point)
    }

    func testLosingTheHandBrieflyKeepsScrollModeButResetsNeutral() {
        enterScrollMode()
        frame([], count: 10)
        XCTAssertTrue(r.inScrollMode)
        // Back somewhere else: that settles as the new neutral rather than scrolling.
        frames(PoseFixtures.openHand(at: CGPoint(x: 0.5, y: 0.45)), for: 1)
        XCTAssertTrue(travel.allSatisfy { $0 == 0 })
    }

    func testLosingTheHandForAWhileGoesBackToPointing() {
        enterScrollMode()
        events.removeAll()
        frames(PoseFixtures.openHand(at: CGPoint(x: 0.5, y: 0.3)), for: 0.1)
        frame([], count: Int(2 / dt))
        XCTAssertFalse(r.inScrollMode)
        XCTAssertEqual(events, [.scrollModeOff])
    }

    func testUnboundCrossIsJustTheTwoFingerPose() {
        r = GestureRecognizer(config: .instant)
        frame([PoseFixtures.openHand()])
        frames(PoseFixtures.crossed(), for: 0.5)
        XCTAssertFalse(r.inScrollMode)
        XCTAssertEqual(last.mode, .scroll)
    }
}

/// Scroll mode through the whole frame pipeline, with the shipped settings.
@MainActor
final class ScrollModePipelineTests: XCTestCase {
    let dt = 1.0 / 30
    var pipeline: FramePipeline!
    var t = 0.0
    var commands: [InputCommand] = []

    override func setUp() {
        super.setUp()
        var snapshot = Preferences(defaults: UserDefaults(suiteName: "ScrollModePipelineTests.\(UUID())")!).snapshot
        snapshot.requireReadyPose = false
        var map = GestureMap.standard
        map[.crossedFingers] = .scrollMode
        pipeline = FramePipeline(snapshot)
        _ = pipeline.apply(snapshot, map: map, displays: [CGRect(x: 0, y: 0, width: 1000, height: 1000)], cameraMount: nil)
        _ = pipeline.setInputAllowed(true)
    }

    private func frames(_ hands: [HandPose], for seconds: TimeInterval) {
        for _ in 0..<Int((seconds / dt).rounded(.up)) {
            commands += pipeline.step(hands: hands, at: t) { CGPoint(x: 500, y: 500) }.commands
            t += dt
        }
    }

    private var scrolls: [Int32] {
        commands.compactMap { if case .scroll(let dy, let flags) = $0, flags.isEmpty { return dy } else { return nil } }
    }

    func testRaisedHandScrollsDownThePageUntilItLeavesView() {
        frames([PoseFixtures.openHand()], for: 0.1)
        frames([PoseFixtures.crossed()], for: 0.4)
        frames([PoseFixtures.openHand()], for: 0.5)
        XCTAssertTrue(scrolls.isEmpty)
        frames([PoseFixtures.openHand(at: CGPoint(x: 0.5, y: 0.36))], for: 0.5)
        XCTAssertFalse(scrolls.isEmpty)
        XCTAssertTrue(scrolls.allSatisfy { $0 < 0 }, "hand up moves content up: negative wheel delta, down the page")
        XCTAssertFalse(commands.contains { $0.isClick })
        commands.removeAll()
        // Hand gone: no coasting once scroll mode stops reporting.
        frames([], for: 1)
        XCTAssertTrue(scrolls.isEmpty)
    }
}

/// Things that must not flip scroll mode or click by accident.
final class ScrollModeEdgeTests: XCTestCase {
    let dt = 1.0 / 30
    var t = 0.0

    private func recognizer(bind trigger: Trigger = .crossedFingers,
                            _ configure: (inout GestureRecognizer.Config) -> Void = { _ in }) -> GestureRecognizer {
        var config = GestureRecognizer.Config.instant
        configure(&config)
        var map = GestureMap.standard
        map[trigger] = .scrollMode
        return GestureRecognizer(config: config, map: map)
    }

    @discardableResult
    private func run(_ r: inout GestureRecognizer, _ hands: [HandPose], for seconds: TimeInterval) -> [GestureRecognizer.Output] {
        var outputs: [GestureRecognizer.Output] = []
        for _ in 0..<Int((seconds / dt).rounded(.up)) {
            outputs.append(r.update(hands: hands, at: t))
            t += dt
        }
        return outputs
    }

    func testAStallRightAfterSwitchingOutDoesNotSwitchBackIn() {
        var r = recognizer()
        run(&r, [PoseFixtures.openHand()], for: 0.1)
        run(&r, [PoseFixtures.crossed()], for: 0.4)
        run(&r, [PoseFixtures.openHand()], for: 0.5)
        run(&r, [PoseFixtures.crossed()], for: 0.4)
        XCTAssertFalse(r.inScrollMode)
        _ = r.releaseHeld()
        let events = run(&r, [PoseFixtures.crossed()], for: 0.5).flatMap(\.events)
        XCTAssertFalse(r.inScrollMode)
        XCTAssertTrue(events.isEmpty)
    }

    func testLosingTheHandWhileStillCrossedDoesNotSwitchBackOut() {
        var r = recognizer()
        run(&r, [PoseFixtures.openHand()], for: 0.1)
        run(&r, [PoseFixtures.crossed()], for: 0.4)
        run(&r, [], for: 0.3)
        run(&r, [PoseFixtures.crossed()], for: 0.5)
        XCTAssertTrue(r.inScrollMode)
    }

    func testDwellDoesNotClickWhileTheCrossForms() {
        var r = recognizer { $0.dwellClick = true; $0.dwellTime = 0.5 }
        run(&r, [PoseFixtures.openHand()], for: 0.4)
        let actions = run(&r, [PoseFixtures.crossed()], for: 0.25).flatMap(\.actions)
        XCTAssertFalse(actions.contains(.leftDown(clickCount: 1)))
    }

    func testAPinchBoundToScrollModeSwitchesInAndOut() {
        var r = recognizer(bind: .ringPinch)
        run(&r, [PoseFixtures.openHand()], for: 0.1)
        run(&r, [PoseFixtures.pinched(.ringTip)], for: 0.2)
        XCTAssertTrue(r.inScrollMode)
        run(&r, [PoseFixtures.openHand()], for: 0.5)
        XCTAssertTrue(r.inScrollMode)
        let out = run(&r, [PoseFixtures.pinched(.ringTip)], for: 0.2)
        XCTAssertFalse(r.inScrollMode)
        XCTAssertEqual(out.flatMap(\.events), [.scrollModeOff])
        XCTAssertFalse(out.flatMap(\.actions).contains { if case .scroll = $0 { return false } else { return true } })
    }

    func testScrollModeIsSharedByEveryProfile() {
        var base = GestureMap.standard
        base[.crossedFingers] = .scrollMode
        var stale = GestureMap.standard
        stale[.middlePinch] = .scrollMode
        let effective = Preferences.effectiveMap(base: base, profiles: ["app": AppProfile(bundleID: "app", name: "App", map: stale)],
                                                 frontmost: "app")
        XCTAssertEqual(effective[.crossedFingers], .scrollMode)
        XCTAssertEqual(effective[.middlePinch], .none)
    }
}
