import AppKit
import SwiftUI

/// The gesture check window: walks every trigger for each hand, asks for the sign and then for
/// rest, shows what the camera reads live, and ends with one line per gesture. See GestureCheck
/// for what is measured and how it's scored. One run at a time; a second `start` while one is up
/// is reported as cancelled.
@MainActor
final class GestureCheckController {
    private let model = CheckModel()
    private var window: NSWindow?
    private var engine: Engine?
    private var run: Task<Void, Never>?
    private var runID: UUID?
    private var samplingToken: UUID?
    private var sampler: GestureCheck.Sampler?
    private var completion: ((GestureCheck.Report?) -> Void)?
    /// How often the countdown and live reading refresh.
    private static let tick: Duration = .milliseconds(50)
    /// Skipped steps are scored from whatever was collected, which is usually nothing: unseen.

    var isRunning: Bool { completion != nil }

    /// nil means the user cancelled or the camera couldn't start.
    func start(engine: Engine, config: GestureRecognizer.Config,
               completion: @escaping (GestureCheck.Report?) -> Void) {
        guard !isRunning else {
            completion(nil)
            return
        }
        let runID = UUID()
        self.runID = runID
        self.completion = completion
        self.engine = engine
        let steps = GestureCheck.allSteps(config: config)
        model.reset(total: steps.count)
        open()
        run = Task { [weak self] in
            guard let self else { return }
            let token = await engine.startHandSampling(onCancelled: { [weak self] in
                guard let self, self.runID == runID else { return }
                self.cancel()
            }) { [weak self] hands in
                guard let self, self.runID == runID else { return }
                self.record(hands)
            }
            guard let token else {
                if self.runID == runID { finish(nil) }
                return
            }
            guard !Task.isCancelled, self.runID == runID else {
                engine.stopSampling(token)
                return
            }
            samplingToken = token
            var results: [GestureCheck.Result] = []
            do {
                for (index, step) in steps.enumerated() {
                    model.show(step, index: index)
                    engine.logNote("gesture check: \(step.id) make")
                    let made = try await phase(step, instruction: step.make, seconds: GestureCheck.makeSeconds)
                    engine.logNote("gesture check: \(step.id) rest")
                    let rest = try await phase(step, instruction: step.rest, seconds: GestureCheck.restSeconds)
                    let result = GestureCheck.score(step, made: made, rest: rest)
                    engine.logNote("gesture check: \(GestureCheck.summary(result))")
                    results.append(result)
                    model.results.append(result)
                }
            } catch {
                return // cancelled; cancel() already reported
            }
            finish(GestureCheck.Report(date: Date(), results: results))
        }
    }

    func cancel() {
        guard isRunning else { return }
        run?.cancel()
        finish(nil)
    }

    /// One phase: the instruction goes up, the hand gets `GestureCheck.settle` to get there, then
    /// frames are collected for `seconds` or until Skip.
    private func phase(_ step: GestureCheck.Step, instruction: String, seconds: TimeInterval) async throws -> GestureCheck.Phase {
        model.instruction = instruction
        model.phase = instruction == step.make ? "Make it" : "Now rest"
        model.progress = 0
        sampler = nil
        try await wait(GestureCheck.settle) { _ in }
        sampler = GestureCheck.Sampler(step: step)
        try await wait(seconds) { [weak self] fraction in self?.model.progress = fraction }
        let phase = sampler?.phase ?? GestureCheck.Sampler(step: step).phase
        sampler = nil
        return phase
    }

    /// Returns after `seconds`, or at once if Skip was pressed during this step.
    private func wait(_ seconds: TimeInterval, progress: (Double) -> Void) async throws {
        let start = Date()
        while true {
            let elapsed = Date().timeIntervalSince(start)
            progress(min(1, elapsed / seconds))
            if elapsed >= seconds || model.skipRequested { return }
            try await Task.sleep(for: Self.tick)
        }
    }

    private func record(_ hands: [HandPose]) {
        sampler?.add(hands, at: CACurrentMediaTime())
        model.live = sampler?.latest.map { CheckModel.Live(value: $0.value, recognized: $0.recognized) }
    }

    private func finish(_ report: GestureCheck.Report?) {
        guard let completion else { return }
        self.completion = nil
        run?.cancel()
        run = nil
        runID = nil
        sampler = nil
        engine?.logNote("gesture check: \(report == nil ? "cancelled" : "done, \(report!.results.count) results")")
        if let samplingToken { engine?.stopSampling(samplingToken) }
        samplingToken = nil
        engine = nil
        if report != nil {
            model.done = true
        } else {
            window?.close()
        }
        completion(report)
    }

    private func open() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: CheckView(
                model: model, onSkip: { [weak self] in self?.model.skipRequested = true },
                onCancel: { [weak self] in self?.cancel() },
                onClose: { [weak self] in self?.window?.close() })))
            window.title = "Gesture Check"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 460, height: 560))
            window.delegate = closeWatcher
            self.window = window
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private lazy var closeWatcher = CloseWatcher { [weak self] in self?.cancel() }
}

/// Closing the window mid-run cancels the run.
private final class CloseWatcher: NSObject, NSWindowDelegate {
    let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}

@MainActor
private final class CheckModel: ObservableObject {
    struct Live {
        var value: Double?
        var recognized: Bool
    }

    @Published var step: GestureCheck.Step?
    @Published var index = 0
    @Published var total = 0
    @Published var phase = ""
    @Published var instruction = ""
    @Published var progress = 0.0
    @Published var live: Live?
    @Published var results: [GestureCheck.Result] = []
    @Published var done = false
    var skipRequested = false

    func reset(total: Int) {
        step = nil
        index = 0
        self.total = total
        phase = ""
        instruction = ""
        progress = 0
        live = nil
        results = []
        done = false
        skipRequested = false
    }

    func show(_ step: GestureCheck.Step, index: Int) {
        self.step = step
        self.index = index
        live = nil
        skipRequested = false
    }
}

private struct CheckView: View {
    @ObservedObject var model: CheckModel
    let onSkip: () -> Void
    let onCancel: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.done {
                report
            } else if let step = model.step {
                running(step)
            } else {
                Text("Starting the camera…").font(.title3)
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 460, height: 560, alignment: .top)
    }

    private func running(_ step: GestureCheck.Step) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(step.hand?.title ?? "Both hands") · \(model.index + 1) of \(model.total)")
                .font(.caption).foregroundStyle(.secondary)
            Text(step.title).font(.title2.weight(.semibold))
            HStack(alignment: .top, spacing: 16) {
                sign(step).frame(width: 120, height: 120)
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.phase).font(.headline)
                    Text(model.instruction).fixedSize(horizontal: false, vertical: true)
                }
            }
            ProgressView(value: model.progress)
            liveLine(step)
            Text("Keep the camera on your hand. Each sign is held for a couple of seconds, then rested. Nothing is clicked or changed.")
                .font(.caption).foregroundStyle(.secondary)
            if !model.results.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.results, id: \.id) { result in line(result) }
                    }
                }
            }
            Spacer(minLength: 0)
            HStack {
                Button("Skip this gesture", action: onSkip)
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
            }
        }
    }

    private var report: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Gesture check").font(.title2.weight(.semibold))
            Text("Clear: reads nearly every time and never at rest. Weak: works most of the time, or rest comes close. Refused: misses more than it hits, or fires at rest. Saved beside the gesture logs; nothing was changed.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.results, id: \.id) { result in line(result) }
                }
            }
            HStack {
                Spacer()
                Button("Close", action: onClose).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func line(_ result: GestureCheck.Result) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(color(result.verdict)).frame(width: 10, height: 10).padding(.top, 4)
            Text(GestureCheck.summary(result)).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func color(_ verdict: GestureCheck.Verdict) -> Color {
        switch verdict {
        case .clear: return .green
        case .weak: return .orange
        case .refused: return .red
        case .unseen: return .gray
        }
    }

    private func liveLine(_ step: GestureCheck.Step) -> some View {
        let text: String
        if let live = model.live {
            switch step.measure {
            case .value(let threshold, _):
                text = live.value.map { String(format: "Reading %.2f (threshold %.2f): %@", $0, threshold, live.recognized ? "counts" : "doesn't count") }
                    ?? "Can't read that finger right now"
            case .peak(let threshold):
                text = live.value.map { String(format: "Travel %.3f (needs %.3f)", $0, threshold) }
                    ?? "Make the two-finger pose first"
            case .predicate:
                text = live.recognized ? "Reads as the sign" : "Not reading as the sign"
            }
        } else {
            text = step.hand == nil ? "Need both hands in view" : "Hand not in view"
        }
        return Text(text).font(.system(.body, design: .monospaced))
    }

    private func sign(_ step: GestureCheck.Step) -> some View {
        let hand = step.hand?.mainHand ?? .right
        if let trigger = step.trigger {
            return AnyView(HandSignView(trigger: trigger, hand: hand))
        }
        return AnyView(HandSignView(pose: HandPoseExamples.openHand(), hand: hand, label: step.title))
    }
}
