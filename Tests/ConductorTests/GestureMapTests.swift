import XCTest
@testable import Conductor

final class GestureMapTests: XCTestCase {
    typealias Action = GestureRecognizer.Action
    let dt = 1.0 / 30

    func testRingPinchSwitchesDisplayOnceByDefault() {
        XCTAssertEqual(GestureMap.standard[.ringPinch], .switchDisplay)
        var r = GestureRecognizer(config: .instant)
        let out = r.update(hands: [PoseFixtures.pinched(.ringTip)], at: 0)
        XCTAssertEqual(out.actions, [.switchDisplay])
        XCTAssertEqual(out.mode, .point)
        XCTAssertEqual(r.update(hands: [PoseFixtures.pinched(.ringTip)], at: dt).actions, [], "held, it doesn't repeat")
    }

    func testRingPinchMappedToScrollUsesPalmTravel() {
        var map = GestureMap.standard
        map[.ringPinch] = .scroll
        var r = GestureRecognizer(config: .instant, map: map)
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

    func testMapRoundTripsThroughDefaults() {
        let suite = UserDefaults(suiteName: "ConductorTests.\(UUID())")!
        var map = GestureMap.standard
        map[.ringPinch] = .shortcut(Shortcut(keyCode: 12, modifiers: CGEventFlags.maskCommand.rawValue))
        map[.littlePinch] = .switchDisplay
        map.save(to: suite)
        XCTAssertEqual(GestureMap.load(from: suite), map)
    }

    func testLabelNamesTriggerAndAction() {
        var r = GestureRecognizer(config: .instant)
        XCTAssertEqual(r.update(hands: [PoseFixtures.pinched()], at: 0).label, "Thumb + index pinch: Click / drag")
        XCTAssertEqual(r.update(hands: [PoseFixtures.openHand()], at: 1).label, "Move")
    }
}

/// Maps saved before Switch display existed have the ring pinch unbound.
@MainActor
final class SwitchDisplayDefaultTests: XCTestCase {
    func testAnUnboundRingPinchGetsSwitchDisplayOnce() {
        let suite = UserDefaults(suiteName: "SwitchDisplayDefaultTests.\(UUID())")!
        var old = GestureMap.standard
        old[.ringPinch] = .none
        old.save(to: suite)
        XCTAssertEqual(Preferences(defaults: suite).gestureMap[.ringPinch], .switchDisplay)
        XCTAssertEqual(GestureMap.load(from: suite)[.ringPinch], .switchDisplay, "saved, not just loaded")
        Preferences(defaults: suite).gestureMap[.ringPinch] = .none
        XCTAssertEqual(Preferences(defaults: suite).gestureMap[.ringPinch], .none, "unbinding it again sticks")
    }

    func testABoundRingPinchIsLeftAlone() {
        let suite = UserDefaults(suiteName: "SwitchDisplayDefaultTests.\(UUID())")!
        var old = GestureMap.standard
        old[.ringPinch] = .middleClick
        old.save(to: suite)
        XCTAssertEqual(Preferences(defaults: suite).gestureMap[.ringPinch], .middleClick)
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
