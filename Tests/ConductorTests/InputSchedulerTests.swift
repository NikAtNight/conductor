import XCTest
@testable import Conductor

final class InputSchedulerTests: XCTestCase {
    private final class Sink: InputSink {
        var location = CGPoint.zero
        var commands: [InputCommand] = []
        var onSend: ((InputCommand) -> Void)?
        func send(_ command: InputCommand) {
            commands.append(command)
            onSend?(command)
            if case .move(let point) = command { location = point }
        }
    }
    private final class Clock { var now: TimeInterval = 0 }

    private func scheduler(_ sink: Sink, _ clock: Clock) -> InputScheduler {
        InputScheduler(sink: sink, clock: { clock.now }, cursor: { nil }, automaticTimers: false)
    }

    func testOrderedCommandsStopGlideBeforeMouseDownAndRelease() throws {
        let sink = Sink(), clock = Clock()
        let input = scheduler(sink, clock)
        input.start { _ in XCTFail("unexpected stall") }
        let token = try XCTUnwrap(input.beginFrame())
        sink.commands = []
        let key = Shortcut(keyCode: 54, modifiers: 0)
        input.submit([.move(CGPoint(x: 100, y: 0))], generation: token)
        input.flush()
        clock.now = 1.0 / 120
        input.tick()
        XCTAssertEqual(sink.location.x, 25, accuracy: 0.01)
        input.submit([.leftDown(clickCount: 1), .keyDown(key), .keyUp(key), .leftUp(clickCount: 1)], generation: token)
        input.flush()
        let atClick = sink.commands
        clock.now = 0.03
        input.tick()
        XCTAssertEqual(sink.commands, atClick, "click dead zone cannot keep drifting")
        XCTAssertEqual(Array(sink.commands.suffix(4)), [.leftDown(clickCount: 1), .keyDown(key), .keyUp(key), .leftUp(clickCount: 1)])
        input.submit([.move(CGPoint(x: 300, y: 0)), .releaseAll], generation: token)
        input.flush()
        let released = sink.commands
        clock.now = 0.06
        input.tick()
        XCTAssertEqual(sink.commands, released, "releaseAll cancels the pending target")
        input.stop()
    }

    func testBlockedCameraCannotBlockTicksOrWatchdogAndStaleResultIsRejected() throws {
        let sink = Sink(), clock = Clock()
        let input = scheduler(sink, clock)
        var stalledToken: UInt64?
        input.start { stalledToken = $0 }
        let frame = try XCTUnwrap(input.beginFrame())
        input.submit([.leftDown(clickCount: 1), .move(CGPoint(x: 120, y: 0))], generation: frame)
        input.flush()
        let camera = DispatchQueue(label: "test.blocked-camera")
        let blocked = expectation(description: "camera entered detection")
        let unblock = DispatchSemaphore(value: 0)
        camera.async {
            blocked.fulfill()
            _ = unblock.wait(timeout: .now() + 2)
            input.submit([.leftDown(clickCount: 1)], generation: frame)
        }
        wait(for: [blocked], timeout: 1)
        clock.now = 1.0 / 120
        input.tick()
        XCTAssertEqual(sink.location.x, 30, accuracy: 0.01)
        clock.now = 1.1
        input.checkStall()
        XCTAssertEqual(sink.commands.last, .releaseAll)
        let stalled = try XCTUnwrap(stalledToken)
        XCTAssertNil(input.beginFrame(), "pipeline must reset before recovery")
        XCTAssertFalse(input.setSampling(true), "sampling cannot replace a pending watchdog recovery")
        let afterRelease = sink.commands
        input.tick()
        unblock.signal()
        camera.sync {}
        input.flush()
        XCTAssertEqual(sink.commands, afterRelease, "the blocked frame cannot press again after watchdog release")
        input.resumeAfterStall(stalled)
        let recovered = try XCTUnwrap(input.beginFrame())
        XCTAssertNotEqual(recovered, frame)
        input.submit([.rightClick], generation: recovered)
        input.flush()
        XCTAssertEqual(sink.commands.last, .rightClick)
        input.stop()
    }

    func testStopRestartAndSamplingRejectOldFrames() throws {
        let sink = Sink(), clock = Clock()
        let input = scheduler(sink, clock)
        input.start { _ in }
        let old = try XCTUnwrap(input.beginFrame())
        input.submit([.move(CGPoint(x: 50, y: 0)), .keyDown(Shortcut(keyCode: 49, modifiers: 0))], generation: old)
        input.flush()
        input.stop()
        let stopped = sink.commands
        clock.now = 0.05
        input.tick()
        input.submit([.rightClick], generation: old)
        input.flush()
        XCTAssertEqual(sink.commands, stopped)
        input.start { _ in }
        input.submit([.rightClick], generation: old)
        input.flush()
        XCTAssertEqual(sink.commands.last, .releaseAll)
        let current = try XCTUnwrap(input.beginFrame())
        input.setSampling(true)
        input.submit([.rightClick], generation: current)
        input.submit([.middleClick])
        input.flush()
        XCTAssertEqual(sink.commands.last, .releaseAll)
        input.setSampling(false)
        input.submit([.rightClick], generation: try XCTUnwrap(input.beginFrame()))
        input.flush()
        XCTAssertEqual(sink.commands.last, .rightClick)
        input.stop()
    }

    func testAutomaticTimersRunWhileCameraQueueIsBlocked() throws {
        let moved = expectation(description: "automatic glide tick")
        let released = expectation(description: "automatic watchdog release")
        let sink = Sink()
        var armed = false
        var sawMove = false
        sink.onSend = { command in
            switch command {
            case .keyDown: armed = true
            case .move where !sawMove:
                sawMove = true
                moved.fulfill()
            case .releaseAll where armed:
                armed = false
                released.fulfill()
            default: break
            }
        }
        let input = InputScheduler(sink: sink, cursor: { nil }, stallAfter: 0.03)
        input.start { _ in }
        let token = try XCTUnwrap(input.beginFrame())
        input.submit([.keyDown(Shortcut(keyCode: 49, modifiers: 0)), .move(CGPoint(x: 100, y: 0))], generation: token)
        let camera = DispatchQueue(label: "test.camera.automatic")
        let entered = expectation(description: "camera blocked")
        let unblock = DispatchSemaphore(value: 0)
        camera.async {
            entered.fulfill()
            _ = unblock.wait(timeout: .now() + 2)
        }
        wait(for: [entered, moved, released], timeout: 1)
        unblock.signal()
        camera.sync {}
        input.stop()
    }

    func testPreviewCoalescingDoesNotDropCommandCompletions() throws {
        let sink = Sink(), clock = Clock()
        let input = scheduler(sink, clock)
        input.start { _ in }
        let token = try XCTUnwrap(input.beginFrame())
        let preview = LatestSnapshot<Int>()
        let uiToken = preview.start()
        var delivered: [Int] = []
        for frame in 0..<100 {
            preview.offer(frame, token: uiToken)
            input.submit([.rightClick], generation: token) { delivered.append(frame) }
        }
        input.flush()
        XCTAssertEqual(preview.take(), 99)
        XCTAssertEqual(delivered, Array(0..<100))
        XCTAssertEqual(sink.commands.filter { $0 == .rightClick }.count, 100)
        input.stop()
    }

    func testTimingReportsMeasuredIntervalsAndFrameLatency() throws {
        let sink = Sink(), clock = Clock()
        let input = scheduler(sink, clock)
        input.start { _ in }
        let token = try XCTUnwrap(input.beginFrame())
        clock.now = 0.012
        input.submit([.move(CGPoint(x: 100, y: 0))], generation: token, frameTime: 0)
        input.flush()
        clock.now = 0.022
        input.tick()
        let note = try XCTUnwrap(input.timingNote())
        XCTAssertTrue(note.contains("mean 10.00 ms"))
        XCTAssertTrue(note.contains("mean 12.00 ms"))
        XCTAssertNil(input.timingNote())
        input.stop()
    }
}
