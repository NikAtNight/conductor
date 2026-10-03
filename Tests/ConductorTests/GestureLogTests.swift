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
