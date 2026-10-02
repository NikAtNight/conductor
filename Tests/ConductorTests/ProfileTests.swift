import XCTest
@testable import Conductor

@MainActor
final class PresetTests: XCTestCase {
    private func freshPreferences() -> Preferences {
        Preferences(defaults: UserDefaults(suiteName: "PresetTests.\(UUID())")!)
    }

    func testSteadierTurnsOnDwellAndLoosensEverything() {
        let p = freshPreferences()
        Preset.steady.apply(to: p)
        XCTAssertTrue(p.dwellClick)
        XCTAssertLessThan(p.smoothing, 0.6)
        XCTAssertGreaterThan(p.pinchDeadZone, 0.012)
        XCTAssertGreaterThan(p.pinchRelease - p.pinchEngage, 0.2)
    }

    func testStandardUndoesAPreset() {
        let p = freshPreferences()
        let before = (p.smoothing, p.dwellClick, p.pinchEngage, p.pinchRelease, p.pinchDeadZone, p.boxWidth)
        Preset.large.apply(to: p)
        Preset.standard.apply(to: p)
        XCTAssertEqual(p.smoothing, before.0)
        XCTAssertEqual(p.dwellClick, before.1)
        XCTAssertEqual(p.pinchEngage, before.2)
        XCTAssertEqual(p.pinchRelease, before.3)
        XCTAssertEqual(p.pinchDeadZone, before.4)
        XCTAssertEqual(p.boxWidth, before.5)
    }

    func testEveryPresetKeepsReleaseAboveEngage() {
        let p = freshPreferences()
        for preset in Preset.allCases {
            preset.apply(to: p)
            XCTAssertGreaterThan(p.pinchRelease, p.pinchEngage, preset.title)
        }
    }

    func testProfilesSurviveARelaunch() {
        let suite = UserDefaults(suiteName: "PresetTests.\(UUID())")!
        let p = Preferences(defaults: suite)
        var map = GestureMap.standard
        map[.fist] = .zoom
        p.appProfiles["com.apple.Preview"] = AppProfile(bundleID: "com.apple.Preview", name: "Preview", map: map)
        let reloaded = Preferences(defaults: suite)
        XCTAssertEqual(reloaded.appProfiles["com.apple.Preview"]?.map[.fist], .zoom)
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

    func testSwitchingMapsReleasesAHeldButtonButKeepsControl() {
        var config = GestureRecognizer.Config()
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
        var r = GestureRecognizer(map: map)
        _ = r.update(hands: [PoseFixtures.pinched(.littleTip)], at: 0)
        XCTAssertTrue(r.isPaused)
        _ = r.replaceMap(.standard) // no pause binding anywhere
        XCTAssertEqual(r.update(hands: [PoseFixtures.openHand()], at: 0.1).events, [.resumed])
        XCTAssertFalse(r.isPaused)
    }
}
