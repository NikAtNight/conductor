import XCTest
@testable import Conductor

/// A gesture log of a look calibration refits to the pass the app saved, with the same score.
final class LookReplayTests: XCTestCase {
    let top = "TOP-UUID", bottom = "BOTTOM-UUID"

    /// A log as the app writes it: frames before and between dots, a note per dot, and the result.
    /// `pitches` is the head pitch while each display's dots were up, in degrees, one list per dot.
    private func log(pitches: [String: [[Double]]], result: String?, faceHeight: Double = 0.35) -> String {
        var lines: [[String: Any]] = []
        var time = 1_700_000_000.0
        func frame(pitch: Double?, label: String = "Calibrating look") {
            var face: [String: Any] = ["box": [0.3, 0.4, 0.3, faceHeight], "roll": 0.0, "yaw": 1.5]
            if let pitch { face["pitch"] = pitch }
            lines.append(["time": time, "fps": 30, "mode": "No hand", "label": label, "actions": [], "hands": [],
                          "face": face, "detectMs": 5.0, "processMs": 6.0])
            time += 1.0 / 30
        }
        func note(_ event: String) { lines.append(["time": time, "event": event]) }
        frame(pitch: 3, label: "Move") // before calibration: must be ignored
        for (display, name) in [(top, "Ultrawide"), (bottom, "InnoView")] {
            for (dot, run) in (pitches[display] ?? []).enumerated() {
                frame(pitch: 99) // the settle period, before the dot counts
                note("look calibration: sampling \(name) (\(display)) dot \(dot + 1) at 0.1,0.1")
                for pitch in run { frame(pitch: pitch) }
                frame(pitch: nil) // a frame without angles: no sample
                note("look calibration: dot \(dot + 1) done")
                frame(pitch: 99) // between dots: ignored
            }
        }
        if let result { note("look calibration result: \(result)") }
        return lines.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            .joined(separator: "\n") + "\n"
    }

    private func pitches(_ base: Double) -> [[Double]] {
        (0..<5).map { dot in (0..<6).map { base + Double(dot) * 0.5 + Double($0) * 0.2 } }
    }

    func testAReplayRefitsThePassAndMatchesTheLoggedScore() throws {
        let all = [top: pitches(3), bottom: pitches(10)]
        let expected = try LookCalibration.pass(
            from: all.flatMap { display, dots in dots.flatMap { $0 }.map {
                LookCalibration.Sample(displayUUID: display, pitch: $0, yaw: 1.5, faceHeight: 0.35) } },
            displays: [top, bottom]).get()
        let score = LookModel.weakestSeparation(expected)
        let json = String(decoding: try JSONEncoder().encode(expected), as: UTF8.self)
        let run = try XCTUnwrap(LookLogReplay.lastRun(in: log(pitches: all, result: "\(json) separation \(String(format: "%.2f", score))")))
        XCTAssertEqual(run.displays, [top, bottom])
        XCTAssertEqual(run.samples.count, 60)
        XCTAssertEqual(run.loggedSeparation!, score, accuracy: 0.005)
        let pass = try run.result.get()
        XCTAssertEqual(pass, expected)
        XCTAssertEqual(LookModel.weakestSeparation(pass), run.loggedSeparation!, accuracy: 0.005)
    }

    func testAFailedRunReplaysAsTheSameFailure() throws {
        let all = [top: pitches(3), bottom: pitches(3.2)]
        let run = try XCTUnwrap(LookLogReplay.lastRun(in: log(pitches: all, result: "failed: indistinct(\"\(top)\", \"\(bottom)\")")))
        XCTAssertEqual(run.loggedResult, "failed: indistinct(\"\(top)\", \"\(bottom)\")")
        XCTAssertNil(run.loggedSeparation)
        XCTAssertEqual(run.result, .failure(.indistinct(top, bottom)))
    }

    func testTheLastRunWinsAndAnUnfinishedRunStillReplays() throws {
        let first = log(pitches: [top: pitches(3), bottom: pitches(10)], result: "cancelled")
        let second = log(pitches: [top: pitches(4)], result: nil)
        let run = try XCTUnwrap(LookLogReplay.lastRun(in: first + second))
        XCTAssertNil(run.loggedResult)
        XCTAssertEqual(run.displays, [top])
        XCTAssertEqual(run.samples.count, 30)
    }

    func testALogWithoutACalibrationHasNoRun() {
        XCTAssertNil(LookLogReplay.lastRun(in: log(pitches: [:], result: nil)))
    }

    /// Replays a real log: CONDUCTOR_LOOK_LOG=~/Library/Logs/Conductor/gestures-....jsonl swift test
    /// --filter LookReplayTests/testARealLogReplaysToTheScoreTheAppShowed
    func testARealLogReplaysToTheScoreTheAppShowed() throws {
        guard let path = ProcessInfo.processInfo.environment["CONDUCTOR_LOOK_LOG"] else {
            throw XCTSkip("set CONDUCTOR_LOOK_LOG to a gesture log with a look calibration in it")
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let run = try XCTUnwrap(try LookLogReplay.lastRun(in: url), "no look calibration in \(path)")
        print("displays: \(run.displays)")
        print("samples: \(run.samples.count)")
        print("logged: \(run.loggedResult ?? "unfinished")")
        switch run.result {
        case .success(let pass):
            let score = LookModel.weakestSeparation(pass)
            print("replayed separation: \(String(format: "%.2f", score)) (\(LookCalibration.quality(of: pass)))")
            for target in pass.targets {
                print("  \(target.displayUUID): pitch \(target.pitch.mean) ± \(target.pitch.sd), yaw \(target.yaw.mean) ± \(target.yaw.sd)")
            }
            if let logged = run.loggedSeparation {
                // Angles are logged to 0.1 degree, so the refit can differ in the second decimal.
                XCTAssertEqual(score, logged, accuracy: 0.05)
            }
        case .failure(let failure):
            print("replayed: failed: \(failure)")
            XCTAssertNil(run.loggedSeparation, "the app saved a pass the replay refuses")
        }
    }
}
