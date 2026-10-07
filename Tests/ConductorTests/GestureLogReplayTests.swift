import XCTest
@testable import Conductor

final class GestureLogReplayTests: XCTestCase {
    func testHandsWrittenToALogReadBackTheSame() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "GestureLogReplayTests.\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = try GestureLog(directory: dir)
        var left = HandSignView.flipped(PoseFixtures.twoFingers())
        left.chirality = .left
        let hands = [PoseFixtures.pinched(), left]
        log.note("a note between frames is skipped")
        log.write(time: Date(timeIntervalSince1970: 100), fps: 30, hands: hands, primary: hands[0],
                  output: GestureRecognizer.Output(mode: .drag, pointer: nil, actions: [], label: "Pinch"),
                  cursor: nil, sinceLastMs: 33, detectMs: 4, processMs: 10)
        log.write(time: Date(timeIntervalSince1970: 100.033), fps: 30, hands: [], primary: nil,
                  output: GestureRecognizer.Output(mode: .idle, pointer: nil, actions: [], label: "No hand"),
                  cursor: nil, sinceLastMs: 33, detectMs: 4, processMs: 10)
        let frames = try GestureLogReplay.frames(in: log.url)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].time, 100)
        XCTAssertEqual(frames[0].label, "Pinch")
        XCTAssertEqual(frames[0].hands.map(\.chirality), [.right, .left])
        XCTAssertEqual(frames[1].hands, [])
        // Joints are logged to four decimals.
        for (read, written) in zip(frames[0].hands, hands) {
            for (joint, point) in written.joints {
                let back = try XCTUnwrap(read[joint], "\(joint)")
                XCTAssertEqual(back.x, point.x, accuracy: 0.0001)
                XCTAssertEqual(back.y, point.y, accuracy: 0.0001)
            }
            XCTAssertEqual(read.confidence[.indexTip], 1)
        }
    }

    /// Runs a real log through the recognizer with the standard bindings plus crossed fingers on
    /// scroll mode and the ready pose off, and prints every swipe, scroll-mode switch and display
    /// switch with the time and the label the app showed. For checking a threshold change against
    /// recordings: CONDUCTOR_GESTURE_LOG=~/Library/Logs/Conductor/gestures-....jsonl swift test
    /// --filter GestureLogReplayTests/testARealLogReplaysThroughTheRecognizer
    func testARealLogReplaysThroughTheRecognizer() throws {
        guard let path = ProcessInfo.processInfo.environment["CONDUCTOR_GESTURE_LOG"] else {
            throw XCTSkip("set CONDUCTOR_GESTURE_LOG to a gesture log")
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let frames = try GestureLogReplay.frames(in: url)
        var map = GestureMap.standard
        map[.crossedFingers] = .scrollMode
        if let path = ProcessInfo.processInfo.environment["CONDUCTOR_GESTURE_MAP"] {
            map = try JSONDecoder().decode(GestureMap.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        }
        XCTAssertFalse(frames.isEmpty, "the log must contain frames")
        var config = GestureRecognizer.Config()
        config.requireReadyPose = false
        var recognizer = GestureRecognizer(config: config, map: map)
        var counts: [String: Int] = [:]
        let start = frames.first?.time ?? 0
        for frame in frames {
            let out = recognizer.update(hands: frame.hands, at: frame.time)
            var happened: [String] = []
            for action in out.actions {
                switch action {
                case .shortcut: happened.append("swipe")
                case .switchDisplay: happened.append("switch display")
                case .leftDown: happened.append("click")
                case .rightClick: happened.append("right click")
                case .keyDown: happened.append("key down")
                case .keyUp: happened.append("key up")
                default: break
                }
            }
            for event in out.events where event == .scrollModeOn || event == .scrollModeOff {
                happened.append("\(event)")
            }
            for what in happened {
                counts[what, default: 0] += 1
                print(String(format: "%7.1fs %@ (app showed: %@)", frame.time - start, what, frame.label))
            }
        }
        print("replayed \(frames.count) frames: \(counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
    }
}
