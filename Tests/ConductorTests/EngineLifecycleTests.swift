import XCTest
@testable import Conductor

@MainActor
final class EngineLifecycleTests: XCTestCase {
    private final class Sink: InputSink {
        var location = CGPoint.zero
        var commands: [InputCommand] = []
        func send(_ command: InputCommand) {
            commands.append(command)
            if case .move(let point) = command { location = point }
        }
    }
    private final class Clock { var now: TimeInterval = 0 }

    @MainActor
    private final class Runtime {
        let sink = Sink()
        let clock = Clock()
        let input: InputScheduler
        let engine: Engine
        let suite = "EngineLifecycleTests.\(UUID())"
        let defaults: UserDefaults
        var time: TimeInterval = 0

        init(binding: GestureAction) throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let prefs = Preferences(defaults: defaults)
            prefs.settings.requireReadyPose = false
            prefs.settings.gestureMap[.indexPinch] = binding
            prefs.settings.gestureMap[.fist] = .rightClick
            var pipeline = FramePipeline(prefs.settings)
            _ = pipeline.apply(prefs.settings, map: prefs.settings.gestureMap,
                               displays: [CGRect(x: 0, y: 0, width: 1000, height: 1000)], cameraMount: nil)
            _ = pipeline.setInputAllowed(true)
            let sink = self.sink, clock = self.clock
            input = InputScheduler(sink: sink, clock: { clock.now }, cursor: { nil }, automaticTimers: false)
            let state = TrackingState()
            state.isRunning = true
            engine = Engine(state: state, preferences: prefs, input: input, pipeline: pipeline)
            engine.beginProcessing()
            engine.camera.queue.sync {}
            frame(PoseFixtures.openHand())
            frame(PoseFixtures.pinched())
        }

        @discardableResult
        func frame(_ hand: HandPose, count: Int = 12) -> [FramePipeline.Output] {
            let start = time
            time += Double(count) / 30
            let outputs: [FramePipeline.Output] = engine.camera.queue.sync {
                (0..<count).compactMap { index in
                    guard let token = input.beginFrame() else { return nil }
                    return engine.processTrackedFrame(hands: [hand], at: start + Double(index) / 30,
                                                      generation: token)
                }
            }
            input.flush()
            return outputs
        }

        func finish() {
            engine.endProcessing()
            engine.camera.queue.sync {}
            input.flush()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private func blockCamera(_ engine: Engine) async -> DispatchSemaphore {
        let entered = expectation(description: "camera queue blocked")
        let unblock = DispatchSemaphore(value: 0)
        engine.camera.queue.async {
            entered.fulfill()
            _ = unblock.wait(timeout: .now() + 3)
        }
        await fulfillment(of: [entered], timeout: 1)
        return unblock
    }

    func testCancelBeforeSamplingSetupRestoresHeldKeyAndDrag() async throws {
        let key = Shortcut(keyCode: 49, modifiers: 0)
        for (binding, down) in [(GestureAction.holdKey(key), InputCommand.keyDown(key)),
                                (.leftButton, .leftDown(clickCount: 1))] {
            let runtime = try Runtime(binding: binding)
            defer { runtime.finish() }
            XCTAssertEqual(runtime.sink.commands.filter { $0 == down }.count, 1)
            let unblock = await blockCamera(runtime.engine)
            let started = await runtime.engine.startHandSampling(onCancelled: {}) { _ in }
            let token = try XCTUnwrap(started)
            XCTAssertEqual(runtime.sink.commands.last, .releaseAll)
            runtime.engine.stopSampling(token)
            unblock.signal()
            runtime.engine.camera.queue.sync {}
            runtime.frame(PoseFixtures.pinched())
            XCTAssertEqual(runtime.sink.commands.filter { $0 == down }.count, 2,
                           "cancelled setup must clear logical holds after physically releasing them")
        }
    }

    func testCancelledPendingSetupCannotStopNewerSamplingOwner() async throws {
        let key = Shortcut(keyCode: 49, modifiers: 0)
        let runtime = try Runtime(binding: .holdKey(key))
        defer { runtime.finish() }
        let unblock = await blockCamera(runtime.engine)
        let firstStart = await runtime.engine.startHandSampling(onCancelled: {}) { _ in }
        let first = try XCTUnwrap(firstStart)
        runtime.engine.stopSampling(first)
        let secondStart = await runtime.engine.startLookSampling(onCancelled: {}) { _ in }
        let second = try XCTUnwrap(secondStart)
        unblock.signal()
        runtime.engine.camera.queue.sync {}
        runtime.engine.stopSampling(first)
        XCTAssertTrue(runtime.frame(PoseFixtures.pinched()).isEmpty, "new owner must still suppress recognition")
        XCTAssertEqual(runtime.sink.commands.filter { $0 == .keyDown(key) }.count, 1)
        runtime.engine.stopSampling(second)
        runtime.engine.camera.queue.sync {}
        runtime.frame(PoseFixtures.pinched())
        XCTAssertEqual(runtime.sink.commands.filter { $0 == .keyDown(key) }.count, 2)
    }

    func testRestartRejectsOldQueuedCallbacksUntilPipelineReset() async throws {
        let key = Shortcut(keyCode: 49, modifiers: 0)
        let runtime = try Runtime(binding: .holdKey(key))
        defer { runtime.finish() }
        let unblock = await blockCamera(runtime.engine)
        let engine = runtime.engine, input = runtime.input
        engine.camera.queue.async {
            guard let token = input.beginFrame() else { return }
            engine.processTrackedFrame(hands: [PoseFixtures.fist()], at: 2, generation: token)
        }
        runtime.engine.endProcessing()
        runtime.engine.beginProcessing()
        runtime.engine.state.isRunning = true
        unblock.signal()
        engine.camera.queue.sync {}
        input.flush()
        XCTAssertFalse(runtime.sink.commands.contains(.rightClick), "old callback cannot run against the previous recognizer")
        XCTAssertNotNil(input.beginFrame(), "reset must admit the new session")
        runtime.frame(PoseFixtures.pinched())
        XCTAssertEqual(runtime.sink.commands.filter { $0 == .keyDown(key) }.count, 2)
    }

    func testSamplingClaimDuringRestartDoesNotPreventFrameAdmission() async throws {
        let runtime = try Runtime(binding: .leftButton)
        defer { runtime.finish() }
        let unblock = await blockCamera(runtime.engine)
        runtime.engine.endProcessing()
        runtime.engine.beginProcessing()
        runtime.engine.state.isRunning = true
        let started = await runtime.engine.startHandSampling(onCancelled: {}) { _ in }
        let token = try XCTUnwrap(started)
        runtime.clock.now = 10
        runtime.input.checkStall()
        unblock.signal()
        runtime.engine.camera.queue.sync {}
        XCTAssertNotNil(runtime.input.beginFrame(), "sampling generation changes must not invalidate the startup session")
        XCTAssertTrue(runtime.frame(PoseFixtures.pinched()).isEmpty)
        runtime.engine.stopSampling(token)
        runtime.engine.camera.queue.sync {}
        XCTAssertFalse(runtime.frame(PoseFixtures.pinched()).isEmpty)
    }
}
