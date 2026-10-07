import XCTest
@testable import Conductor

/// Settings' own rules, and how Preferences stores them.
@MainActor
final class SettingsTests: XCTestCase {
    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "SettingsTests.\(UUID())")!
    }

    private func assertPinchGap(_ s: Settings, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(s.pinchRelease - s.pinchEngage, Settings.minimumPinchGap - 1e-9, message, file: file, line: line)
    }

    func testMovingEngagePushesReleaseAndMovingReleasePushesEngage() {
        var s = Settings()
        s.setPinchEngage(0.6)
        XCTAssertEqual(s.pinchEngage, 0.6)
        XCTAssertEqual(s.pinchRelease, 0.7, accuracy: 1e-9)
        s.setPinchRelease(0.3)
        XCTAssertEqual(s.pinchRelease, 0.3)
        XCTAssertEqual(s.pinchEngage, 0.2, accuracy: 1e-9)
    }

    func testThePinchGapHoldsThroughLoadPresetAndReset() throws {
        // A blob with the gap broken, as an older build or a hand edit could leave it.
        let store = suite()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(Settings())) as? [String: Any])
        json["pinchEngage"] = 0.5
        json["pinchRelease"] = 0.4
        store.set(try JSONSerialization.data(withJSONObject: json), forKey: Preferences.key)
        let p = Preferences(defaults: store)
        assertPinchGap(p.settings, "load from the blob")
        XCTAssertEqual(p.settings.pinchEngage, 0.5)

        let legacy = suite()
        legacy.set(0.5, forKey: "pinchEngage")
        legacy.set(0.4, forKey: "pinchRelease")
        assertPinchGap(Preferences(defaults: legacy).settings, "load from the old keys")

        for preset in Preset.allCases {
            p.settings.setPinchEngage(0.6)
            preset.apply(to: &p.settings)
            assertPinchGap(p.settings, preset.title)
            p.settings.setPinchRelease(0.3)
            preset.apply(to: &p.settings)
            assertPinchGap(p.settings, preset.title)
        }

        p.settings.setPinchEngage(0.6)
        p.resetToDefaults()
        assertPinchGap(p.settings, "reset")
        XCTAssertEqual(p.settings.pinchEngage, Settings().pinchEngage)
    }

    func testOldPerKeySettingsMoveIntoTheBlobIntact() throws {
        let store = suite()
        store.set(0.42, forKey: "boxWidth")
        store.set(false, forKey: "mirrored")
        store.set(0.3, forKey: "pinchEngage")
        store.set(0.65, forKey: "pinchRelease")
        store.set("lookedAt", forKey: "displayMode")
        store.set("left", forKey: "mainHand")
        store.set(false, forKey: "requireReadyPose")
        store.set("relative", forKey: "pointerMode")
        store.set("travel", forKey: "scrollStyle")
        store.set("cam-1", forKey: "cameraDeviceID")
        store.set(true, forKey: "showHandMap")
        store.set("indexKnuckle", forKey: "calibrationPoint")
        store.set([0.1, 0.2, 0.5, 0.4], forKey: "calibratedBox")
        var map = GestureMap.standard
        map[.fist] = .zoom
        store.set(try JSONEncoder().encode(map), forKey: "gestureMap")
        let placement = CameraPlacement(displayUUID: "display-a", x: 0.25)
        store.set(try JSONEncoder().encode(placement), forKey: "cameraPlacement")

        var expected = Settings()
        expected.boxWidth = 0.42
        expected.mirrored = false
        expected.setPinchEngage(0.3)
        expected.setPinchRelease(0.65)
        expected.displayMode = .lookedAt
        expected.mainHand = .left
        expected.requireReadyPose = false
        expected.pointerMode = .relative
        expected.scrollStyle = .travel
        expected.cameraDeviceID = "cam-1"
        expected.showHandMap = true
        expected.calibratedBox = CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.4)
        expected.gestureMap = map
        expected.cameraPlacement = placement

        XCTAssertEqual(Preferences(defaults: store).settings, expected)
        let blob = try XCTUnwrap(store.data(forKey: Preferences.key), "migrated on first load")
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: blob), expected)

        // From now on the blob wins over the old keys.
        store.set(0.9, forKey: "boxWidth")
        XCTAssertEqual(Preferences(defaults: store).settings.boxWidth, 0.42)
    }

    func testABlobMissingAKeyOrHoldingAStaleValueKeepsEverythingElse() throws {
        let store = suite()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(Settings())) as? [String: Any])
        json["boxWidth"] = 0.42
        json["smoothing"] = nil // a setting this blob predates
        json["lookModel"] = ["targets": [], "faceHeight": 0.3] // a look model format that no longer decodes
        json["displayMode"] = "somewhereElse"
        store.set(try JSONSerialization.data(withJSONObject: json), forKey: Preferences.key)
        let s = Preferences(defaults: store).settings
        XCTAssertEqual(s.boxWidth, 0.42)
        XCTAssertEqual(s.smoothing, Settings().smoothing)
        XCTAssertNil(s.lookModel)
        XCTAssertEqual(s.displayMode, Settings().displayMode)
    }
}
