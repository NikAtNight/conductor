import Foundation
import QuartzCore

/// Owns posting, glide ticks and the watchdog independently of camera/Vision work.
/// A generation rejects commands from frames that completed after stop, restart or a stall.
final class InputScheduler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "conductor.input", qos: .userInteractive)
    private let sink: InputSink
    private let clock: () -> TimeInterval
    private let cursor: () -> CGPoint?
    private let automaticTimers: Bool
    private let stallAfter: TimeInterval
    private var generation: UInt64 = 0
    private var running = false
    private var session = UUID()
    private var acceptingFrames = false
    private var stalled = false
    private var sampling = false
    private var heartbeat: TimeInterval = 0
    private var glide = CursorGlide()
    private var glideTimer: DispatchSourceTimer?
    private var watchdog: DispatchSourceTimer?
    private var onStall: ((UInt64) -> Void)?
    private var lastTick: TimeInterval?
    private var tickTotal: TimeInterval = 0
    private var tickMax: TimeInterval = 0
    private var tickCount = 0
    private var latencyTotal: TimeInterval = 0
    private var latencyMax: TimeInterval = 0
    private var latencyCount = 0

    init(sink: InputSink = InputController(), clock: @escaping () -> TimeInterval = CACurrentMediaTime,
         cursor: @escaping () -> CGPoint? = { CGEvent(source: nil)?.location },
         automaticTimers: Bool = true, stallAfter: TimeInterval = 1) {
        self.sink = sink
        self.clock = clock
        self.cursor = cursor
        self.automaticTimers = automaticTimers
        self.stallAfter = stallAfter
    }

    @discardableResult
    func start(acceptingFrames: Bool = true, onStall: @escaping (UInt64) -> Void) -> UUID {
        queue.sync {
            stopOwned()
            generation &+= 1
            session = UUID()
            running = true
            stalled = false
            sampling = false
            self.acceptingFrames = false
            self.onStall = onStall
            if acceptingFrames { armOwned() }
            return session
        }
    }

    /// The camera queue calls this only after resetting the pipeline for this start.
    /// Sampling changes command generations, but cannot invalidate startup's session token.
    func arm(_ token: UUID) {
        queue.sync {
            guard running, session == token, !acceptingFrames else { return }
            armOwned()
        }
    }

    func ownsSession(_ token: UUID) -> Bool {
        queue.sync { running && session == token }
    }

    private func armOwned() {
        acceptingFrames = true
        heartbeat = clock()
        guard automaticTimers else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.checkStallOwned() }
        watchdog = timer
        timer.resume()
    }

    func stop() {
        queue.sync {
            generation &+= 1
            running = false
            acceptingFrames = false
            stopOwned()
        }
    }

    /// Called before detection. A stalled generation cannot recover until its pipeline is reset.
    func beginFrame() -> UInt64? {
        queue.sync {
            guard running, acceptingFrames, !stalled else { return nil }
            heartbeat = clock()
            return generation
        }
    }

    func ownsGeneration(_ token: UInt64) -> Bool {
        queue.sync { running && generation == token }
    }

    func isCurrent(_ token: UInt64) -> Bool {
        queue.sync { running && acceptingFrames && !stalled && generation == token }
    }

    func resumeAfterStall(_ token: UInt64) {
        queue.sync {
            guard running, stalled, generation == token else { return }
            stalled = false
            sampling = false
            heartbeat = clock()
        }
    }

    @discardableResult
    func setSampling(_ active: Bool) -> Bool {
        queue.sync {
            guard running, !stalled else { return false }
            guard sampling != active else { return true }
            generation &+= 1
            sampling = active
            stopGlide()
            sink.send(.releaseAll)
            return true
        }
    }

    func submit(_ commands: [InputCommand], generation token: UInt64? = nil, frameTime: TimeInterval? = nil,
                completion: (() -> Void)? = nil) {
        queue.async { [self] in
            guard running, acceptingFrames, !stalled, !sampling, token == nil || token == generation else { return }
            if let frameTime, !commands.isEmpty {
                let latency = max(0, clock() - frameTime)
                latencyTotal += latency
                latencyMax = max(latencyMax, latency)
                latencyCount += 1
            }
            for command in commands {
                switch command {
                case .move(let point):
                    glide.aim(at: point, from: cursor() ?? sink.location, at: clock())
                    startGlideTimer()
                case .leftDown, .releaseAll:
                    stopGlide()
                    sink.send(command)
                default: sink.send(command)
                }
            }
            completion?()
        }
    }

    /// Aggregates actual scheduling intervals and command latency without logging every tick.
    func timingNote() -> String? {
        queue.sync {
            guard tickCount > 0 || latencyCount > 0 else { return nil }
            let note = String(format: "input timing: ticks %d mean %.2f ms max %.2f ms; frame-to-input %d mean %.2f ms max %.2f ms",
                              tickCount, tickTotal * 1000 / Double(max(1, tickCount)), tickMax * 1000,
                              latencyCount, latencyTotal * 1000 / Double(max(1, latencyCount)), latencyMax * 1000)
            tickCount = 0; tickTotal = 0; tickMax = 0
            latencyCount = 0; latencyTotal = 0; latencyMax = 0
            return note
        }
    }

    /// Manual clock entry points also make the watchdog and glide deterministic in tests.
    func tick() { queue.sync { tickOwned() } }
    func checkStall() { queue.sync { checkStallOwned() } }
    func flush() { queue.sync {} }
    func location() -> CGPoint { queue.sync { cursor() ?? sink.location } }

    private func checkStallOwned() {
        guard running, acceptingFrames, !stalled, clock() - heartbeat > stallAfter else { return }
        stalled = true
        generation &+= 1
        stopGlide()
        sink.send(.releaseAll)
        onStall?(generation)
    }

    private func startGlideTimer() {
        guard lastTick == nil else { return }
        lastTick = clock()
        guard automaticTimers else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1 / CursorGlide.rate, repeating: 1 / CursorGlide.rate,
                       leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tickOwned() }
        glideTimer = timer
        timer.resume()
    }

    private func tickOwned() {
        guard running, !stalled, glide.isGliding else { return }
        let now = clock()
        if let lastTick {
            let interval = now - lastTick
            tickTotal += interval
            tickMax = max(tickMax, interval)
            tickCount += 1
        }
        lastTick = now
        if let point = glide.position(at: now) { sink.send(.move(point)) }
        if !glide.isGliding { stopGlide() }
    }

    private func stopGlide() {
        glide.stop()
        glideTimer?.cancel()
        glideTimer = nil
        lastTick = nil
    }

    private func stopOwned() {
        stopGlide()
        watchdog?.cancel()
        watchdog = nil
        onStall = nil
        sink.send(.releaseAll)
    }
}
