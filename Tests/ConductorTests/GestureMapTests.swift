import XCTest
@testable import Conductor

final class GestureMapTests: XCTestCase {
    typealias Action = GestureRecognizer.Action
    let dt = 1.0 / 30

    func testThePointingSignSwitchesDisplayOnceByDefault() {
        XCTAssertEqual(GestureMap.standard[.indexPoint], .switchDisplay)
        XCTAssertEqual(GestureMap.standard[.ringPinch], GestureAction.none)
        var r = GestureRecognizer(config: .instant)
        var actions: [Action] = []
        var last: GestureRecognizer.Output!
        for i in 0..<20 {
            last = r.update(hands: [PoseFixtures.pointingSign(.up)], at: Double(i) * dt)
            actions += last.actions
            if i < 8 { XCTAssertEqual(actions, [], "not before the hold") }
            XCTAssertNotNil(last.pointer, "the cursor keeps moving")
        }
        XCTAssertEqual(actions, [.switchDisplay(toward: .up)], "once, however long it's held")
        XCTAssertEqual(last.mode, .point)
        XCTAssertEqual(last.label, "Point with index, thumb out: Switch display")
    }

    func testThePointingHoldShowsOnTheRingAndInTheLabel() {
        var r = GestureRecognizer(config: .instant)
        var progress: [CGFloat] = []
        var labels: Set<String> = []
        for i in 0..<12 {
            let out = r.update(hands: [PoseFixtures.pointingSign(.up)], at: Double(i) * dt)
            progress.append(out.feedback.point)
            labels.insert(out.label)
        }
        XCTAssertEqual(progress.first, 0)
        XCTAssertTrue(zip(progress, progress.dropFirst()).allSatisfy { $1 >= $0 }, "fills, never drops: \(progress)")
        XCTAssertEqual(progress.last, 1, "held after firing")
        XCTAssertTrue(labels.contains("Point with index, thumb out: hold…"))
        XCTAssertEqual(r.update(hands: [PoseFixtures.openHand()], at: 12 * dt).feedback.point, 0)
    }

    func testABriefPointDoesNothing() {
        var r = GestureRecognizer(config: .instant)
        var actions: [Action] = []
        for i in 0..<5 { actions += r.update(hands: [PoseFixtures.pointingSign(.down)], at: Double(i) * dt).actions }
        for i in 5..<10 { actions += r.update(hands: [PoseFixtures.openHand()], at: Double(i) * dt).actions }
        XCTAssertEqual(actions, [])
    }

    func testTheFingerPicksTheDirectionAsTheUserSeesIt() {
        for direction in [Direction.down, .left, .right] {
            var r = GestureRecognizer(config: .instant)
            var actions: [Action] = []
            for i in 0..<12 { actions += r.update(hands: [PoseFixtures.pointingSign(direction)], at: Double(i) * dt).actions }
            XCTAssertEqual(actions, [.switchDisplay(toward: direction)])
        }
        var unmirrored = GestureRecognizer.Config.instant
        unmirrored.mirrored = false
        var r = GestureRecognizer(config: unmirrored)
        var actions: [Action] = []
        for i in 0..<12 {
            actions += r.update(hands: [PoseFixtures.pointingSign(.right, mirrored: false)], at: Double(i) * dt).actions
        }
        XCTAssertEqual(actions, [.switchDisplay(toward: .right)])
    }

    func testARelaxedPointOrAFingerAimedAtTheCameraDoesNotSwitch() {
        for hand in [PoseFixtures.pointing(tuckedThumb: true), PoseFixtures.aimedAtCamera()] {
            var r = GestureRecognizer(config: .instant)
            var actions: [Action] = []
            for i in 0..<20 { actions += r.update(hands: [hand], at: Double(i) * dt).actions }
            XCTAssertEqual(actions, [])
        }
    }

    func testAnyOtherTriggerBoundToSwitchDisplayGoesToTheNextDisplay() {
        var map = GestureMap.standard
        map[.ringPinch] = .switchDisplay
        var r = GestureRecognizer(config: .instant, map: map)
        XCTAssertEqual(r.update(hands: [PoseFixtures.pinched(.ringTip)], at: 0).actions, [.switchDisplay(toward: nil)])
        XCTAssertEqual(r.update(hands: [PoseFixtures.pinched(.ringTip)], at: dt).actions, [], "held, it doesn't repeat")
    }

    func testRingPinchMappedToScrollUsesPalmTravel() {
        var map = GestureMap.standard
        map[.ringPinch] = .scroll
        var r = GestureRecognizer(config: .travelScroll, map: map)
        _ = r.update(hands: [PoseFixtures.pinched(.ringTip, at: CGPoint(x: 0.5, y: 0.3))], at: 0)
        let out = r.update(hands: [PoseFixtures.pinched(.ringTip, at: CGPoint(x: 0.5, y: 0.35))], at: dt)
        XCTAssertEqual(out.mode, .scroll)
        XCTAssertNil(out.pointer, "cursor holds still while scrolling")
        guard case .scroll(let dy) = out.actions.first else { return XCTFail("\(out.actions)") }
        XCTAssertEqual(dy, 0.05, accuracy: 1e-9)
    }

    func testMiddlePinchMappedToShortcutFiresOnce() {
        var map = GestureMap.standard
        let combo = Shortcut(keyCode: 48, modifiers: CGEventFlags.maskCommand.rawValue) // cmd+tab
        map[.middlePinch] = .shortcut(combo)
        var r = GestureRecognizer(config: .instant, map: map)
        var actions: [Action] = []
        for (i, hand) in [PoseFixtures.pinched(.middleTip), PoseFixtures.pinched(.middleTip), PoseFixtures.openHand()].enumerated() {
            actions += r.update(hands: [hand], at: Double(i) * dt).actions
        }
        XCTAssertEqual(actions, [.shortcut(combo)])
        XCTAssertEqual(combo.display, "⌘⇥")
    }

    func testFistMappedToButtonDragsAndReleases() {
        var map = GestureMap.standard
        map[.fist] = .leftButton
        var r = GestureRecognizer(config: .instant, map: map)
        let down = r.update(hands: [PoseFixtures.fist()], at: 0)
        XCTAssertEqual(down.actions, [.leftDown(clickCount: 1)])
        XCTAssertEqual(down.mode, .drag)
        let up = r.update(hands: [PoseFixtures.openHand()], at: dt)
        XCTAssertEqual(up.actions, [.leftUp(clickCount: 1)])
    }

    func testUnboundIndexPinchLeavesMiddlePinchFree() {
        var map = GestureMap.standard
        map[.indexPinch] = .none
        var r = GestureRecognizer(config: .instant, map: map)
        // A plain index pinch now does nothing at all.
        XCTAssertTrue(r.update(hands: [PoseFixtures.pinched()], at: 0).actions.isEmpty)
        XCTAssertEqual(r.update(hands: [PoseFixtures.openHand()], at: dt).actions, [])
        XCTAssertEqual(r.update(hands: [PoseFixtures.pinched(.middleTip)], at: 2 * dt).actions, [.rightClick])
    }

    func testPauseGestureSoftPausesAndTheSameGestureResumes() {
        var map = GestureMap.standard
        map[.littlePinch] = .pauseTracking
        var r = GestureRecognizer(config: .instant, map: map)
        let paused = r.update(hands: [PoseFixtures.pinched(.littleTip)], at: 0)
        XCTAssertEqual(paused.events, [.paused])
        XCTAssertTrue(paused.actions.isEmpty)
        XCTAssertTrue(r.isPaused)
        // Still holding the pause pinch, then an index pinch: nothing happens while paused.
        XCTAssertTrue(r.update(hands: [PoseFixtures.pinched(.littleTip)], at: dt).events.isEmpty)
        XCTAssertTrue(r.update(hands: [PoseFixtures.pinched()], at: 2 * dt).actions.isEmpty)
        XCTAssertEqual(r.update(hands: [PoseFixtures.openHand()], at: 3 * dt).mode, .paused)
        // Pinching the little finger again resumes, once.
        XCTAssertEqual(r.update(hands: [PoseFixtures.pinched(.littleTip)], at: 4 * dt).events, [.resumed])
        XCTAssertFalse(r.isPaused)
        XCTAssertTrue(r.update(hands: [PoseFixtures.pinched(.littleTip)], at: 5 * dt).events.isEmpty, "held pinch doesn't re-pause")
        XCTAssertEqual(r.update(hands: [PoseFixtures.openHand()], at: 6 * dt).mode, .point)
    }

    func testOneHandedZoomUsesVerticalTravel() {
        var map = GestureMap.standard
        map[.fist] = .zoom
        var r = GestureRecognizer(config: .instant, map: map)
        _ = r.update(hands: [PoseFixtures.fist(at: CGPoint(x: 0.5, y: 0.3))], at: 0)
        let out = r.update(hands: [PoseFixtures.fist(at: CGPoint(x: 0.5, y: 0.32))], at: dt)
        guard case .zoom(let delta) = out.actions.first else { return XCTFail("\(out.actions)") }
        XCTAssertEqual(delta, 0.02, accuracy: 1e-9)
    }

    @MainActor
    func testMapRoundTripsThroughDefaults() {
        let suite = UserDefaults(suiteName: "ConductorTests.\(UUID())")!
        var map = GestureMap.standard
        map[.ringPinch] = .shortcut(Shortcut(keyCode: 12, modifiers: CGEventFlags.maskCommand.rawValue))
        map[.littlePinch] = .switchDisplay
        Preferences(defaults: suite).settings.gestureMap = map
        XCTAssertEqual(Preferences(defaults: suite).settings.gestureMap, map)
    }

    func testLabelNamesTriggerAndAction() {
        var r = GestureRecognizer(config: .instant)
        XCTAssertEqual(r.update(hands: [PoseFixtures.pinched()], at: 0).label, "Thumb + index pinch: Click / drag")
        XCTAssertEqual(r.update(hands: [PoseFixtures.openHand()], at: 1).label, "Move")
    }
}

/// Switch display shipped on the ring pinch before the pointing sign existed.
@MainActor
final class SwitchDisplayDefaultTests: XCTestCase {
    /// A map saved before the sign existed.
    private func oldMap(ringPinch: GestureAction) -> GestureMap {
        var old = GestureMap.standard
        old.bindings[.indexPoint] = nil
        old[.ringPinch] = ringPinch
        return old
    }

    /// Writes the map where builds before the settings blob kept it.
    private func storeLegacy(_ map: GestureMap, in suite: UserDefaults) throws {
        suite.set(try JSONEncoder().encode(map), forKey: "gestureMap")
    }

    func testTheRingPinchBindingMovesToTheSignOnce() throws {
        let suite = UserDefaults(suiteName: "SwitchDisplayDefaultTests.\(UUID())")!
        try storeLegacy(oldMap(ringPinch: .switchDisplay), in: suite)
        let map = Preferences(defaults: suite).settings.gestureMap
        XCTAssertEqual(map[.indexPoint], .switchDisplay)
        XCTAssertEqual(map[.ringPinch], GestureAction.none)
        let blob = try XCTUnwrap(suite.data(forKey: Preferences.key))
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: blob).gestureMap[.ringPinch], GestureAction.none,
                       "saved, not just loaded")
        Preferences(defaults: suite).settings.gestureMap[.ringPinch] = .switchDisplay
        XCTAssertEqual(Preferences(defaults: suite).settings.gestureMap[.ringPinch], .switchDisplay, "binding it again sticks")
    }

    func testARingPinchBoundToSomethingElseIsLeftAlone() throws {
        let suite = UserDefaults(suiteName: "SwitchDisplayDefaultTests.\(UUID())")!
        try storeLegacy(oldMap(ringPinch: .middleClick), in: suite)
        let map = Preferences(defaults: suite).settings.gestureMap
        XCTAssertEqual(map[.ringPinch], .middleClick)
        XCTAssertEqual(map[.indexPoint], .switchDisplay)
    }

    func testAppProfilesMoveTheBindingToo() throws {
        let suite = UserDefaults(suiteName: "SwitchDisplayDefaultTests.\(UUID())")!
        let profile = AppProfile(bundleID: "com.example.app", name: "Example", map: oldMap(ringPinch: .switchDisplay))
        suite.set(try JSONEncoder().encode([profile.bundleID: profile]), forKey: "appProfiles")
        let loaded = try XCTUnwrap(Preferences(defaults: suite).settings.appProfiles[profile.bundleID])
        XCTAssertEqual(loaded.map[.ringPinch], GestureAction.none)
        XCTAssertEqual(loaded.map[.indexPoint], .switchDisplay)
    }
}

final class DisplayTargetTests: XCTestCase {
    let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let right = CGRect(x: 1920, y: -200, width: 2560, height: 1440)

    func testAllDisplaysIsTheUnion() {
        let r = FramePipeline.targetScreen(mode: .all, displays: [main, right], current: .zero)
        XCTAssertEqual(r, CGRect(x: 0, y: -200, width: 4480, height: 1440))
    }

    func testMainIsTheDisplayAtOrigin() {
        XCTAssertEqual(FramePipeline.targetScreen(mode: .main, displays: [right, main], current: .zero), main)
    }

    func testFollowCursorPicksTheDisplayUnderTheCursor() {
        let r = FramePipeline.targetScreen(mode: .followCursor, displays: [main, right], current: main,
                                    cursor: CGPoint(x: 3000, y: 100))
        XCTAssertEqual(r, right)
    }

    func testFollowCursorKeepsCurrentWithoutACursorSample() {
        XCTAssertEqual(FramePipeline.targetScreen(mode: .followCursor, displays: [main, right], current: right), right)
        XCTAssertEqual(FramePipeline.targetScreen(mode: .followCursor, displays: [main, right], current: .zero), main)
    }
}
