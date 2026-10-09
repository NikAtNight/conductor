import XCTest
@testable import Conductor

@MainActor
final class EngineLogLifecycleTests: XCTestCase {
    private final class Sink: InputSink {
        var released: DispatchSemaphore?
        var location = CGPoint.zero
        func send(_ command: InputCommand) {
            if command == .releaseAll { released?.signal() }
        }
    }

    func testShutdownDrainsLogAlreadyClosingAfterStop() throws {
        try assertShutdownDrainsLog(stopFirst: true)
    }

    func testShutdownReleasesInputBeforeDrainingActiveLog() throws {
        try assertShutdownDrainsLog(stopFirst: false)
    }

    private func assertShutdownDrainsLog(stopFirst: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "EngineLogLifecycleTests.\(UUID())")
        let suite = "EngineLogLifecycleTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let entered = DispatchSemaphore(value: 0)
        let unblock = DispatchSemaphore(value: 0)
        let log = try GestureLog(directory: directory, beforeWrite: {
            entered.signal()
            XCTAssertEqual(unblock.wait(timeout: .now() + 3), .success)
        })
        defer {
            for _ in 0..<3 { unblock.signal() }
            log.finishAndWait()
        }
        log.note("first accepted record")
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        log.note("second accepted record")
        let preferences = Preferences(defaults: defaults)
        let sink = Sink()
        let input = InputScheduler(sink: sink, automaticTimers: false)
        let engine = Engine(state: TrackingState(), preferences: preferences, input: input,
                            pipeline: FramePipeline(preferences.settings), gestureLog: log)
        engine.beginProcessing()
        engine.camera.queue.sync {}
        if stopFirst {
            engine.stop()
            engine.camera.queue.sync {}
        }

        let released = DispatchSemaphore(value: 0)
        let shutdownReturned = DispatchSemaphore(value: 0)
        let observed = expectation(description: "shutdown waits after releasing input")
        sink.released = released
        DispatchQueue.global(qos: .userInitiated).async {
            XCTAssertEqual(released.wait(timeout: .now() + 2), .success,
                           "shutdown must release input while the writer is blocked")
            XCTAssertEqual(shutdownReturned.wait(timeout: .now() + 0.1), .timedOut,
                           "shutdown must not return with accepted records still queued")
            for _ in 0..<3 { unblock.signal() }
            observed.fulfill()
        }
        engine.shutdown()
        shutdownReturned.signal()
        wait(for: [observed], timeout: 3)

        XCTAssertFalse(FileManager.default.fileExists(atPath: log.inProgressURL.path))
        let contents = try String(contentsOf: log.url, encoding: .utf8)
        let events = try contents.split(separator: "\n").compactMap { line in
            let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return record["event"] as? String
        }
        XCTAssertEqual(Array(events.prefix(2)), ["first accepted record", "second accepted record"])
        if stopFirst { XCTAssertTrue(events.last?.hasPrefix("log writer:") == true) }
        XCTAssertEqual(log.diagnostics.writtenLines, events.count)
        XCTAssertEqual(log.diagnostics.droppedLines, 0)
        XCTAssertEqual(log.diagnostics.failedLines, 0)
        XCTAssertNil(log.diagnostics.finalizationError)
    }
}
