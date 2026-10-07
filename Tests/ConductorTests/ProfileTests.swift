import XCTest
@testable import Conductor

final class PresetTests: XCTestCase {
    func testSteadierTurnsOnDwellAndLoosensEverything() {
        var s = Settings()
        Preset.steady.apply(to: &s)
        XCTAssertTrue(s.dwellClick)
        XCTAssertLessThan(s.smoothing, 0.6)
        XCTAssertGreaterThan(s.pinchDeadZone, Settings().pinchDeadZone)
        XCTAssertGreaterThan(s.pinchRelease - s.pinchEngage, 0.2)
    }

    func testStandardUndoesAPreset() {
        var s = Settings()
        Preset.large.apply(to: &s)
        Preset.standard.apply(to: &s)
        XCTAssertEqual(s, Settings())
    }

    func testEveryPresetKeepsReleaseAboveEngage() {
        var s = Settings()
        for preset in Preset.allCases {
            preset.apply(to: &s)
            XCTAssertGreaterThan(s.pinchRelease, s.pinchEngage, preset.title)
        }
    }

    @MainActor
    func testProfilesSurviveARelaunch() {
        let suite = UserDefaults(suiteName: "PresetTests.\(UUID())")!
        let p = Preferences(defaults: suite)
        var map = GestureMap.standard
        map[.fist] = .zoom
        p.settings.appProfiles["com.apple.Preview"] = AppProfile(bundleID: "com.apple.Preview", name: "Preview", map: map)
        let reloaded = Preferences(defaults: suite)
        XCTAssertEqual(reloaded.settings.appProfiles["com.apple.Preview"]?.map[.fist], .zoom)
    }
}

final class ProfileSelectionTests: XCTestCase {
    func testFrontmostAppWithAProfileGetsItsMap() {
        var keynote = GestureMap.standard
        keynote[.swipeLeft] = .shortcut(Shortcut(keyCode: 124, modifiers: 0)) // → next slide
        let profiles = ["com.apple.iWork.Keynote": AppProfile(bundleID: "com.apple.iWork.Keynote", name: "Keynote", map: keynote)]
        XCTAssertEqual(Preferences.effectiveMap(base: .standard, profiles: profiles, frontmost: "com.apple.iWork.Keynote"), keynote)
        XCTAssertEqual(Preferences.effectiveMap(base: .standard, profiles: profiles, frontmost: "com.apple.Safari"), .standard)
        XCTAssertEqual(Preferences.effectiveMap(base: .standard, profiles: profiles, frontmost: nil), .standard)
    }

    func testPauseComesFromEverywhereInEveryProfile() {
        var base = GestureMap.standard
        base[.littlePinch] = .pauseTracking
        var profileMap = GestureMap.standard
        profileMap[.ringPinch] = .pauseTracking // a stale pause binding in the profile
        let profiles = ["app": AppProfile(bundleID: "app", name: "App", map: profileMap)]
        let effective = Preferences.effectiveMap(base: base, profiles: profiles, frontmost: "app")
        XCTAssertEqual(effective[.littlePinch], .pauseTracking)
        XCTAssertEqual(effective[.ringPinch], GestureAction.none)
    }

    func testSwitchingProfilesWhilePausedStaysPaused() {
        var base = GestureMap.standard
        base[.littlePinch] = .pauseTracking
        var r = GestureRecognizer(config: .instant, map: base)
        _ = r.update(hands: [PoseFixtures.pinched(.littleTip)], at: 0)
        let other = Preferences.effectiveMap(base: base, profiles: ["app": AppProfile(bundleID: "app", name: "App", map: .standard)], frontmost: "app")
        _ = r.replaceMap(other)
        // Pause pinch still held across the switch: must not resume.
        XCTAssertTrue(r.update(hands: [PoseFixtures.pinched(.littleTip)], at: 0.1).events.isEmpty)
        XCTAssertTrue(r.isPaused)
    }

    func testTurningOnTheReadyPoseMidHoldKeepsControl() {
        var r = GestureRecognizer(config: .instant)
        XCTAssertEqual(r.update(hands: [PoseFixtures.pinched()], at: 0).actions, [.leftDown(clickCount: 1)])
        r.config.requireReadyPose = true
        let out = r.update(hands: [PoseFixtures.pinched()], at: 0.05)
        XCTAssertEqual(out.mode, .drag, "already in control; the toggle doesn't kick you out")
        XCTAssertEqual(r.update(hands: [PoseFixtures.openHand()], at: 0.1).actions, [.leftUp(clickCount: 1)])
    }

    func testAKeyActionWithNothingRecordedDoesNothing() {
        var map = GestureMap.standard
        map[.ringPinch] = .holdKey(GestureAction.unsetKey)
        map[.middlePinch] = .shortcut(GestureAction.unsetKey)
        var r = GestureRecognizer(config: .instant, map: map)
        XCTAssertEqual(r.update(hands: [PoseFixtures.pinched(.ringTip)], at: 0).actions, [])
        XCTAssertEqual(r.update(hands: [PoseFixtures.openHand()], at: 0.1).actions, [])
        XCTAssertEqual(r.update(hands: [PoseFixtures.pinched(.middleTip)], at: 0.2).actions, [])
    }

    func testSwitchingMapsReleasesAHeldButtonButKeepsControl() {
        var config = GestureRecognizer.Config.instant
        config.requireReadyPose = true
        var r = GestureRecognizer(config: config)
        var t = 0.0
        while t < 0.7 { _ = r.update(hands: [PoseFixtures.openHand()], at: t); t += 1.0 / 30 }
        XCTAssertEqual(r.update(hands: [PoseFixtures.pinched()], at: t).actions, [.leftDown(clickCount: 1)])
        var other = GestureMap.standard
        other[.middlePinch] = .middleClick
        XCTAssertEqual(r.replaceMap(other), [.leftUp(clickCount: 1)])
        XCTAssertEqual(r.update(hands: [PoseFixtures.openHand()], at: t + 0.1).mode, .point, "still in control")
    }

    func testPausedWithNoWayToResumeResumesItself() {
        var map = GestureMap.standard
        map[.littlePinch] = .pauseTracking
        var r = GestureRecognizer(config: .instant, map: map)
        _ = r.update(hands: [PoseFixtures.pinched(.littleTip)], at: 0)
        XCTAssertTrue(r.isPaused)
        _ = r.replaceMap(.standard) // no pause binding anywhere
        XCTAssertEqual(r.update(hands: [PoseFixtures.openHand()], at: 0.1).events, [.resumed])
        XCTAssertFalse(r.isPaused)
    }
}
