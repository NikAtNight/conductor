import XCTest
@testable import Conductor

final class GestureLogTests: XCTestCase {
    func testEachFrameIsOneJSONLineWithTheMeasurements() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "GestureLogTests.\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = try GestureLog(directory: dir)
        var r = GestureRecognizer(config: .instant)
        for (i, hand) in [PoseFixtures.openHand(), PoseFixtures.pinched()].enumerated() {
            let output = r.update(hands: [hand], at: Double(i) / 30)
            log.write(time: Date(), fps: 30, hands: [hand], primary: hand, output: output, cursor: CGPoint(x: 100, y: 200),
                      sinceLastMs: 33, detectMs: 5, processMs: 7)
        }
        let lines = try String(contentsOf: log.url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        XCTAssertEqual(second["actions"] as? [String], ["leftDown(clickCount: 1)"])
        XCTAssertEqual(second["sinceLastMs"] as? Double, 33)
        let primary = try XCTUnwrap(second["primary"] as? [String: Any])
        let pinch = try XCTUnwrap(primary["pinch"] as? [String: Double])
        XCTAssertLessThan(try XCTUnwrap(pinch["indexTip"]), 0.35)
        let hands = try XCTUnwrap(second["hands"] as? [[String: Any]])
        XCTAssertEqual((hands.first?["joints"] as? [String: [Double]])?.count, HandJoint.allCases.count)
        XCTAssertNil(second["face"])
    }

    func testTheSetupLineCarriesTheMacDisplaysAndSettingsButNotTheApps() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "GestureLogTests.\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = try GestureLog(directory: dir)
        var settings = Settings()
        settings.setPinchEngage(0.3)
        settings.appProfiles = ["com.apple.Safari": AppProfile(bundleID: "com.apple.Safari", name: "Safari", map: .standard)]
        settings.cameraDeviceID = "0x1234000005ac8514"
        settings.cameraPlacement = CameraPlacement(displayUUID: "A", x: 0.5)
        let spread = LookModel.Spread(mean: 0, sd: 1)
        settings.lookModel = LookModel(passes: [LookModel.Pass(faceHeight: 0.2, targets: [
            LookModel.Target(displayUUID: "A", pitch: spread, yaw: spread),
            LookModel.Target(displayUUID: "gone", pitch: spread, yaw: spread)])])
        let wide = DisplayInfo(uuid: "A", name: "LG ULTRAWIDE", bounds: CGRect(x: 0, y: 0, width: 3440, height: 1440),
                               isBuiltin: false, isMain: true, pixelSize: CGSize(width: 3440, height: 1440))
        let laptop = DisplayInfo(uuid: "B", name: "Built-in Retina Display", bounds: CGRect(x: 500, y: 1440, width: 1512, height: 982),
                                 isBuiltin: true, isMain: false, pixelSize: CGSize(width: 3024, height: 1964))
        let setup = GestureLog.Setup(install: "0f3a6c5e-1b2d-4e7f-8a9b-0c1d2e3f4a5b", displays: [wide, laptop], camera: nil,
                                     placement: (x: 1720, display: wide), accessibility: true, settings: settings,
                                     bundle: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "7"])
        log.setup(setup)
        var r = GestureRecognizer(config: .instant)
        let output = r.update(hands: [], at: 0)
        log.write(time: Date(), fps: 5, hands: [], primary: nil, output: output, cursor: nil, sinceLastMs: 200,
                  detectMs: 5, processMs: 7, warning: "Too dark to track well. Add light in front of you.", idle: true)

        let lines = try String(contentsOf: log.url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertNotNil(first["time"] as? Double)
        let logged = try XCTUnwrap(first["setup"] as? [String: Any])
        XCTAssertEqual(logged["install"] as? String, "0f3a6c5e-1b2d-4e7f-8a9b-0c1d2e3f4a5b")
        XCTAssertEqual(logged["version"] as? String, "0.1.0")
        XCTAssertEqual(logged["build"] as? String, "7")
        XCTAssertEqual(logged["arch"] as? String, "arm64")
        XCTAssertFalse(try XCTUnwrap(logged["model"] as? String).isEmpty, "hw.model")
        XCTAssertTrue(try XCTUnwrap(logged["macOS"] as? String).hasPrefix("Version"))
        let displays = try XCTUnwrap(logged["displays"] as? [[String: Any]])
        XCTAssertEqual(displays.count, 2)
        XCTAssertEqual(displays[0]["name"] as? String, "LG ULTRAWIDE")
        XCTAssertEqual(displays[0]["scale"] as? Double, 1)
        XCTAssertEqual(displays[1]["scale"] as? Double, 2)
        XCTAssertEqual(displays[1]["y"] as? Double, 1440)
        XCTAssertEqual(displays[1]["builtin"] as? Bool, true)
        let placement = try XCTUnwrap(logged["placement"] as? [String: Any])
        XCTAssertEqual(placement["display"] as? String, "LG ULTRAWIDE")
        XCTAssertEqual(placement["x"] as? Double, 0.5)
        XCTAssertNil(logged["camera"])
        XCTAssertEqual(logged["accessibility"] as? Bool, true)
        XCTAssertEqual(logged["appProfiles"] as? Int, 1)
        let stored = try XCTUnwrap(logged["settings"] as? [String: Any])
        XCTAssertEqual(stored["pinchEngage"] as? Double, 0.3)
        XCTAssertEqual((stored["appProfiles"] as? [String: Any])?.count, 0, "which apps someone uses stays private")
        XCTAssertNil(stored["cameraDeviceID"], "a hardware identifier")
        XCTAssertNil(stored["cameraPlacement"], "keyed by display UUID; the placement above has the name")
        let passes = try XCTUnwrap((stored["lookModel"] as? [String: Any])?["passes"] as? [[String: Any]])
        let targets = try XCTUnwrap(passes[0]["targets"] as? [[String: Any]])
        XCTAssertEqual(targets.map { $0["displayUUID"] as? String }, ["LG ULTRAWIDE", "a display since unplugged"])

        let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        XCTAssertEqual(frame["warning"] as? String, "Too dark to track well. Add light in front of you.")
        XCTAssertEqual(frame["idle"] as? Bool, true)
        XCTAssertNil(frame["setup"])
    }

    func testTheFaceIsLoggedInDegreesWithEachEyesGaze() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "GestureLogTests.\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = try GestureLog(directory: dir)
        var r = GestureRecognizer(config: .instant)
        let output = r.update(hands: [], at: 0)
        log.write(time: Date(), fps: 30, hands: [], primary: nil, face: FaceFixtures.face(pitchDegrees: 22.5),
                  output: output, cursor: nil, sinceLastMs: 33, detectMs: 5, faceMs: 4, processMs: 11)
        let line = try XCTUnwrap(String(contentsOf: log.url, encoding: .utf8).split(separator: "\n").first)
        let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(frame["faceMs"] as? Double, 4)
        let face = try XCTUnwrap(frame["face"] as? [String: Any])
        XCTAssertEqual(face["pitch"] as? Double, 22.5)
        XCTAssertEqual(face["box"] as? [Double], [0.3, 0.4, 0.3, 0.4])
        let left = try XCTUnwrap(face["leftEye"] as? [String: Any])
        XCTAssertEqual(left["gaze"] as? [Double], [0, 0.5])
        XCTAssertEqual(left["openness"] as? Double, 0.4)
        // The right eye fixture has no pupil, so it has an opening but no gaze.
        let right = try XCTUnwrap(face["rightEye"] as? [String: Any])
        XCTAssertNil(right["gaze"])
        XCTAssertEqual(right["openness"] as? Double, 0.4)
    }
}
