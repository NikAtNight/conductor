import CoreGraphics
import Foundation

/// Walks every trigger one hand at a time, measures the number each one is decided on while the
/// user makes the sign and again while they rest, and scores how cleanly the current threshold
/// separates the two. A report, not a calibration: nothing here changes a setting. The numbers
/// are the ones the gesture log records, so a check can be read back against it.
enum GestureCheck {
    enum Hand: String, Codable, CaseIterable {
        case right, left

        var chirality: Chirality { self == .right ? .right : .left }
        var title: String { self == .right ? "Right hand" : "Left hand" }
    }

    /// How a step's reading is judged.
    enum Measure: Equatable {
        /// A number against a threshold. `lowerIsMade` means the sign is made when the value is
        /// under it (a pinch distance); otherwise over it (the thumb held out).
        case value(threshold: Double, lowerIsMade: Bool)
        /// The largest value reached in the phase against a threshold: a flick.
        case peak(threshold: Double)
        /// A shape that is simply there or not.
        case predicate
    }

    struct Step: Identifiable {
        var id: String
        /// Nil for the both-hands step.
        var hand: Hand?
        var trigger: Trigger?
        var title: String
        var make: String
        var rest: String
        var measure: Measure
        /// The number the recognizer decides with, or nil when it can't be read this frame.
        var value: ([HandPose]) -> Double?
        /// Whether the sign's own shape test passes, with the current thresholds.
        var recognized: ([HandPose]) -> Bool
    }

    /// Frames are ignored this long after an instruction changes, while the hand gets there.
    static let settle: TimeInterval = 0.8
    static let makeSeconds: TimeInterval = 2.5
    static let restSeconds: TimeInterval = 2.0
    /// Fewer frames with the hand in view than this and a phase can't be scored.
    static let minimumFrames = 15
    /// The swipe's trailing window, the same one the recognizer measures a flick over.
    static let flickWindow: TimeInterval = GestureRecognizer.Config().swipeWindow

    // MARK: Steps

    static func allSteps(config: GestureRecognizer.Config) -> [Step] {
        Hand.allCases.flatMap { steps(for: $0, config: config) } + [bothHands(config: config)]
    }

    /// Every one-handed trigger plus the ready pose, in the order they are shown.
    static func steps(for hand: Hand, config: GestureRecognizer.Config) -> [Step] {
        let only: ([HandPose]) -> HandPose? = { the(hand, in: $0) }
        var steps: [Step] = []
        steps.append(Step(
            id: "\(hand.rawValue)-readyPose", hand: hand, trigger: nil, title: "Open hand (ready pose)",
            make: "Hold your hand flat and open, fingers apart, thumb out.",
            rest: "Let the hand go loose: fingers relaxed, thumb resting against the hand.",
            measure: .value(threshold: HandPose.openHandThumbOut, lowerIsMade: false),
            value: { only($0)?.normalizedDistance(.thumbTip, .indexMCP).map(Double.init) },
            recognized: { only($0)?.isOpenHand ?? false }))
        for trigger in Trigger.pinches {
            let tip = trigger.fingertip!
            let finger = ["index", "middle", "ring", "little"][Trigger.pinches.firstIndex(of: trigger)!]
            steps.append(Step(
                id: "\(hand.rawValue)-\(trigger.rawValue)", hand: hand, trigger: trigger, title: trigger.title,
                make: "Touch your thumb to your \(finger) fingertip and hold it there.",
                rest: "Open the hand, fingers relaxed.",
                measure: .value(threshold: config.pinchEngage, lowerIsMade: true),
                value: { only($0)?.normalizedDistance(.thumbTip, tip).map(Double.init) },
                recognized: { hands in
                    guard let hand = only(hands), let distance = hand.normalizedDistance(.thumbTip, tip) else { return false }
                    // The recognizer's own start conditions: close enough, and the finger seen from the side.
                    return distance < config.pinchEngage && (tip == .indexTip || !hand.othersCurled)
                        && (hand.visibleLength(of: tip) ?? 0) >= config.minimumFingerLength
                }))
        }
        steps.append(Step(
            id: "\(hand.rawValue)-fist", hand: hand, trigger: .fist, title: Trigger.fist.title,
            make: "Close your hand into a fist.",
            rest: "Relax the hand, fingers loosely open.",
            measure: .predicate,
            value: { _ in nil },
            recognized: { only($0)?.isFist ?? false }))
        steps.append(Step(
            id: "\(hand.rawValue)-twoFingers", hand: hand, trigger: .twoFingers, title: Trigger.twoFingers.title,
            make: "Index and middle up, ring and little curled.",
            rest: "Relax the hand, fingers loosely open.",
            measure: .predicate,
            value: { _ in nil },
            recognized: { only($0)?.isTwoFingerPose ?? false }))
        steps.append(Step(
            id: "\(hand.rawValue)-crossedFingers", hand: hand, trigger: .crossedFingers, title: Trigger.crossedFingers.title,
            make: "Cross your index and middle fingers, either finger on top, palm toward the camera.",
            rest: "Index and middle up, side by side, not crossed.",
            measure: .value(threshold: Double(config.crossEngage), lowerIsMade: false),
            value: { only($0)?.fingerCross.map(Double.init) },
            recognized: { (only($0)?.fingerCross ?? -.infinity) > config.crossEngage }))
        steps.append(Step(
            id: "\(hand.rawValue)-swipe", hand: hand, trigger: .swipeLeft, title: "Two-finger swipe",
            make: "In the two-finger pose, flick your hand sideways. A few times is fine.",
            rest: "In the two-finger pose, move slowly up and down, as if scrolling.",
            measure: .peak(threshold: Double(config.swipeDistance)),
            value: { _ in nil }, // the sampler measures travel over time; see Sampler
            recognized: { only($0)?.isTwoFingerPose ?? false }))
        steps.append(Step(
            id: "\(hand.rawValue)-indexPoint", hand: hand, trigger: .indexPoint, title: Trigger.indexPoint.title,
            make: "Point your index finger up, thumb out, the other fingers curled.",
            rest: "Point with your index finger, thumb resting on the curled fingers.",
            measure: .value(threshold: HandPose.pointingThumbOut, lowerIsMade: false),
            value: { only($0)?.normalizedDistance(.thumbTip, .indexMCP).map(Double.init) },
            recognized: { hands in
                guard let hand = only(hands), hand.isPointingSign else { return false }
                return (hand.visibleLength(of: .indexTip) ?? 0) >= config.minimumFingerLength
            }))
        return steps
    }

    static func bothHands(config: GestureRecognizer.Config) -> Step {
        let widest: ([HandPose]) -> Double? = { hands in
            guard hands.count >= 2 else { return nil }
            let distances = hands.prefix(2).compactMap { $0.normalizedDistance(.thumbTip, .indexTip) }
            guard distances.count == 2 else { return nil }
            return Double(distances.max()!)
        }
        return Step(
            id: "both-twoHandPinch", hand: nil, trigger: .twoHandPinch, title: Trigger.twoHandPinch.title,
            make: "Pinch thumb and index on both hands, with the other fingers open.",
            rest: "Both hands up, open and relaxed.",
            measure: .value(threshold: Double(config.twoHandPinchEngage), lowerIsMade: true),
            value: widest,
            recognized: { (widest($0) ?? .infinity) < Double(config.twoHandPinchEngage) })
    }

    /// The hand a one-handed step watches: the one Vision says is that hand, or the only hand in
    /// view when Vision can't tell, the way the recognizer picks its main hand.
    static func the(_ hand: Hand, in hands: [HandPose]) -> HandPose? {
        hands.first { $0.chirality == hand.chirality } ?? (hands.count == 1 ? hands[0] : nil)
    }

    // MARK: Sampling

    /// Collects one phase's frames for a step.
    struct Sampler {
        let step: Step
        private(set) var frames = 0
        private(set) var seen = 0
        private(set) var recognized = 0
        private(set) var values: [Double] = []
        /// The latest frame, for live feedback.
        private(set) var latest: (value: Double?, recognized: Bool)?
        private var trail: [(time: TimeInterval, point: CGPoint)] = []

        init(step: Step) {
            self.step = step
        }

        mutating func add(_ hands: [HandPose], at time: TimeInterval) {
            frames += 1
            let present = step.hand.map { GestureCheck.the($0, in: hands) != nil } ?? (hands.count >= 2)
            guard present else {
                latest = nil
                return
            }
            seen += 1
            let hit = step.recognized(hands)
            if hit { recognized += 1 }
            let value: Double?
            if case .peak = step.measure {
                value = flick(hands, at: time)
            } else {
                value = step.value(hands)
            }
            if let value { values.append(value) }
            latest = (value, hit)
        }

        /// Sideways knuckle travel over the trailing window while in the two-finger pose, the number
        /// the recognizer compares with its swipe distance.
        private mutating func flick(_ hands: [HandPose], at time: TimeInterval) -> Double? {
            guard let hand = step.hand, let pose = GestureCheck.the(hand, in: hands),
                  pose.isTwoFingerPose, let point = pose.knuckleCenter else {
                trail.removeAll()
                return nil
            }
            trail.append((time, point))
            trail.removeAll { time - $0.time > GestureCheck.flickWindow }
            guard let first = trail.first else { return nil }
            return Double(abs(GestureRecognizer.swipeTravel(from: first.point, to: point)))
        }

        var phase: Phase {
            let sorted = values.sorted()
            func percentile(_ p: Double) -> Double? {
                guard !sorted.isEmpty else { return nil }
                return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
            }
            let hits: Int
            switch step.measure {
            case .value(let threshold, let lowerIsMade):
                hits = values.filter { lowerIsMade ? $0 < threshold : $0 > threshold }.count
            case .peak(let threshold):
                hits = (sorted.last ?? 0) >= threshold ? seen : 0
            case .predicate:
                hits = recognized
            }
            return Phase(frames: frames, seen: seen, readable: values.count, recognized: recognized, hits: hits,
                         low: percentile(0.1), median: percentile(0.5), high: percentile(0.9), peak: sorted.last)
        }
    }

    // MARK: Results

    /// What one phase measured. Percentiles are over the frames with a reading.
    struct Phase: Codable, Equatable {
        var frames: Int
        /// Frames with the hand (or both hands) in view.
        var seen: Int
        /// Frames the number could be read on.
        var readable: Int
        /// Frames the sign's shape test passed.
        var recognized: Int
        /// Frames past the threshold (the shape test for predicates; every seen frame for a peak
        /// that reached it).
        var hits: Int
        var low: Double?
        var median: Double?
        var high: Double?
        var peak: Double?

        /// Hits as a share of the frames the hand was in view.
        var hitRate: Double { seen > 0 ? Double(hits) / Double(seen) : 0 }
    }

    enum Verdict: String, Codable {
        /// Made it fires nearly every frame, at rest almost never.
        case clear
        /// Works most of the time, or rest comes close to firing.
        case weak
        /// Made it misses more often than not, or rest fires it.
        case refused
        /// The hand wasn't in view long enough to say.
        case unseen
    }

    struct Result: Codable, Equatable {
        var id: String
        var hand: String
        var title: String
        /// "value", "peak" or "predicate": how `made` and `rest` were judged.
        var kind: String
        var threshold: Double?
        var made: Phase
        var rest: Phase
        var verdict: Verdict
        /// Midway between the made and rest readings, when they don't overlap. Not applied.
        var suggestedThreshold: Double?
    }

    static func score(_ step: Step, made: Phase, rest: Phase) -> Result {
        var threshold: Double?
        var suggested: Double?
        var kind = "predicate"
        var verdict: Verdict
        if made.seen < minimumFrames || rest.seen < minimumFrames {
            verdict = .unseen
        } else {
            verdict = Self.verdict(madeRate: made.hitRate, restRate: rest.hitRate)
        }
        switch step.measure {
        case .value(let t, let lowerIsMade):
            kind = "value"
            threshold = t
            // The worst made frames against the closest rest frames.
            if let madeEdge = lowerIsMade ? made.high : made.low, let restEdge = lowerIsMade ? rest.low : rest.high,
               lowerIsMade ? madeEdge < restEdge : madeEdge > restEdge {
                suggested = (madeEdge + restEdge) / 2
            }
        case .peak(let t):
            kind = "peak"
            threshold = t
            if let madePeak = made.peak, madePeak > rest.peak ?? 0 {
                suggested = (madePeak + (rest.peak ?? 0)) / 2
            }
        case .predicate:
            break
        }
        return Result(id: step.id, hand: step.hand?.title ?? "Both hands", title: step.title, kind: kind,
                      threshold: threshold, made: made, rest: rest, verdict: verdict, suggestedThreshold: suggested)
    }

    static func verdict(madeRate: Double, restRate: Double) -> Verdict {
        if madeRate >= 0.8, restRate <= 0.05 { return .clear }
        if madeRate >= 0.5, restRate <= 0.2 { return .weak }
        return .refused
    }

    /// One line per result, for the window and the log.
    static func summary(_ result: Result) -> String {
        var line = "\(result.hand), \(result.title): \(result.verdict.rawValue)"
        if case .unseen = result.verdict {
            return line + " (hand in view for \(result.made.seen) made and \(result.rest.seen) rest frames)"
        }
        line += String(format: ", read %.0f%% made, %.0f%% at rest", result.made.hitRate * 100, result.rest.hitRate * 100)
        if let threshold = result.threshold, result.kind == "peak" {
            line += String(format: "; flick %.3f vs %.3f at rest, threshold %.3f", result.made.peak ?? 0, result.rest.peak ?? 0, threshold)
        } else if let threshold = result.threshold, let made = result.made.median, let rest = result.rest.median {
            line += String(format: "; made %.2f, rest %.2f, threshold %.2f", made, rest, threshold)
        }
        if let suggested = result.suggestedThreshold {
            line += String(format: "; midpoint %.2f", suggested)
        }
        return line
    }

    struct Report: Codable, Equatable {
        var date: Date
        var results: [Result]
    }

    /// Writes the report beside the gesture logs as gesture-check-<date>.json and returns the file.
    static func save(_ report: Report, to directory: URL = GestureLog.directory) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = directory.appending(path: "gesture-check-\(formatter.string(from: report.date)).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: url)
        return url
    }
}
