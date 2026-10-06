import CoreGraphics
import Foundation

/// Where each display sits in head-angle space, measured by look calibration. Angles are degrees
/// with Vision's signs: pitch positive looking down, yaw positive turning counterclockwise.
///
/// Each display is summarised by the average head angle while looking around it and how far the
/// head strayed from that average. Ranges were tried first and failed: the corner walk makes the
/// two screens' ranges overlap near the edge they share, and inside the overlap nothing could
/// win, so the pick stuck on one screen.
///
/// One pass per sitting distance. Up close the head follows the eyes; further back it moves far
/// less than the geometry says because the eyes do more of the work, so a single pass can't be
/// scaled to cover both. Passes are anchors and the picker interpolates between them.
struct LookModel: Codable, Equatable {
    /// Average and standard deviation of one head angle, degrees.
    struct Spread: Codable, Equatable {
        var mean: Double
        var sd: Double
    }

    struct Target: Codable, Equatable {
        var displayUUID: String
        var pitch: Spread
        var yaw: Spread
    }

    /// One calibration run at one distance from the camera.
    struct Pass: Codable, Equatable {
        /// Face height (fraction of the frame) during the run: the distance gauge.
        var faceHeight: Double
        var targets: [Target]
    }

    /// Sorted by face height, furthest first.
    var passes: [Pass]

    /// A new pass within this much of an existing pass's face height replaces it instead of piling
    /// up: that's the same chair position measured again.
    static let samePlaceTolerance = 0.15

    init(passes: [Pass]) {
        self.passes = passes.sorted { $0.faceHeight < $1.faceHeight }
    }

    /// A one-pass model.
    init(targets: [Target], faceHeight: Double) {
        self.init(passes: [Pass(faceHeight: faceHeight, targets: targets)])
    }

    func adding(_ pass: Pass) -> LookModel {
        var kept = passes.filter { abs($0.faceHeight - pass.faceHeight) > Self.samePlaceTolerance * pass.faceHeight }
        kept.append(pass)
        return LookModel(passes: kept)
    }

    /// The targets as they look from the distance where the face is `faceHeight` tall. Between
    /// two passes each average and spread is interpolated by face height. Beyond the nearest or
    /// furthest pass the tangent rule scales that pass (see `scaled`). A display missing from one
    /// of the two bracketing passes is taken from the other as is.
    func targets(atFaceHeight faceHeight: Double) -> [Target] {
        guard let first = passes.first, let last = passes.last else { return [] }
        if faceHeight <= first.faceHeight { return Self.scaled(first, to: faceHeight) }
        if faceHeight >= last.faceHeight { return Self.scaled(last, to: faceHeight) }
        guard let upper = passes.firstIndex(where: { $0.faceHeight >= faceHeight }), upper > 0 else {
            return Self.scaled(last, to: faceHeight)
        }
        let far = passes[upper - 1], near = passes[upper]
        let t = (faceHeight - far.faceHeight) / (near.faceHeight - far.faceHeight)
        func mix(_ a: Spread, _ b: Spread) -> Spread {
            Spread(mean: a.mean + t * (b.mean - a.mean), sd: a.sd + t * (b.sd - a.sd))
        }
        var result: [Target] = []
        for a in far.targets {
            if let b = near.targets.first(where: { $0.displayUUID == a.displayUUID }) {
                result.append(Target(displayUUID: a.displayUUID, pitch: mix(a.pitch, b.pitch), yaw: mix(a.yaw, b.yaw)))
            } else {
                result.append(a)
            }
        }
        result += near.targets.filter { b in !far.targets.contains { $0.displayUUID == b.displayUUID } }
        return result
    }

    private static func scaled(_ pass: Pass, to faceHeight: Double) -> [Target] {
        let ratio = pass.faceHeight > 0 ? faceHeight / pass.faceHeight : 1
        guard ratio != 1 else { return pass.targets } // atan(tan(x)) isn't exactly x in floating point
        func scale(_ s: Spread) -> Spread {
            // Small angles: the spread scales about like the tangent does.
            Spread(mean: scaled(s.mean, by: ratio), sd: s.sd * ratio)
        }
        return pass.targets.map { Target(displayUUID: $0.displayUUID, pitch: scale($0.pitch), yaw: scale($0.yaw)) }
    }

    /// An angle measured at one distance, as it looks from another. The angle to a point on a
    /// screen has tan(angle) = offset / distance, and face height is proportional to 1 / distance,
    /// so the tangent scales with the face height ratio. Only a rough guide: real heads move less
    /// than this when far away, which is what extra passes are for.
    static func scaled(_ degrees: Double, by ratio: Double) -> Double {
        atan(tan(degrees * .pi / 180) * ratio) * 180 / .pi
    }

    /// The typical spread on each axis across these targets, the unit the picker measures in.
    /// Pooled over displays so the boundary between two screens falls midway between their
    /// averages. Floored so a very still head doesn't make every degree look huge.
    static func pooledSpread(_ targets: [Target]) -> (pitch: Double, yaw: Double) {
        func pool(_ sds: [Double]) -> Double {
            guard !sds.isEmpty else { return minimumSpread }
            return max((sds.map { $0 * $0 }.reduce(0, +) / Double(sds.count)).squareRoot(), minimumSpread)
        }
        return (pool(targets.map(\.pitch.sd)), pool(targets.map(\.yaw.sd)))
    }

    static let minimumSpread = 1.0

    /// How far apart two displays' averages are, in pooled spreads. The bigger, the more reliably
    /// the head tells them apart; see LookCalibration's thresholds.
    static func separation(_ a: Target, _ b: Target, spread: (pitch: Double, yaw: Double)) -> Double {
        let dp = (a.pitch.mean - b.pitch.mean) / spread.pitch
        let dy = (a.yaw.mean - b.yaw.mean) / spread.yaw
        return (dp * dp + dy * dy).squareRoot()
    }

    /// The closest pair of displays in this pass, by `separation`. Infinity with one display.
    static func weakestSeparation(_ pass: Pass) -> Double {
        let spread = pooledSpread(pass.targets)
        var weakest = Double.infinity
        for (i, a) in pass.targets.enumerated() {
            for b in pass.targets.dropFirst(i + 1) { weakest = min(weakest, separation(a, b, spread: spread)) }
        }
        return weakest
    }
}

/// Fits one calibration pass from head angles sampled while the user followed a target around
/// each display.
enum LookCalibration {
    struct Sample: Equatable {
        var displayUUID: String
        var pitch: Double
        var yaw: Double
        var faceHeight: Double
    }

    enum Failure: Error, Equatable {
        /// The face wasn't seen enough while this display's targets were up.
        case tooFewSamples(displayUUID: String)
        /// Two displays' averages are too close, relative to how much the head wanders on each,
        /// for the head to tell them apart.
        case indistinct(String, String)
    }

    /// How a successful pass separates the screens.
    enum Quality: Equatable {
        /// The head tells the screens apart almost everywhere.
        case clear
        /// Usable, but near the edge between screens the pick can go either way.
        case weak
    }

    /// How long each target shows, how much of that is ignored while the eyes travel to it, and
    /// how many frames each display needs across all its targets.
    static let settle: TimeInterval = 0.5
    static let samplePeriod: TimeInterval = 1.0
    static let minimumSamplesPerDisplay = 15
    /// Separation (pooled spreads between averages) below which a pass is refused, and below
    /// which it's saved with a warning. A close pass at Nikhil's desk measured about 2.7 and
    /// worked; a leaning-back pass measured about 2.1 and confused the screens near their edge.
    static let minimumSeparation = 1.5
    static let clearSeparation = 2.5

    /// A sample from one frame, or nil when Vision didn't report the head angles.
    static func sample(_ face: FacePose, display: String) -> Sample? {
        guard let pitch = face.pitch, let yaw = face.yaw else { return nil }
        return Sample(displayUUID: display, pitch: pitch * 180 / .pi, yaw: yaw * 180 / .pi, faceHeight: face.box.height)
    }

    /// One target per display: the average and spread of its samples on each axis, after
    /// dropping the 5% furthest out on either side so a stray frame can't drag them. The pass's
    /// face height is the median over all samples.
    static func pass(from samples: [Sample], displays: [String]) -> Result<LookModel.Pass, Failure> {
        var targets: [LookModel.Target] = []
        for display in displays {
            let mine = samples.filter { $0.displayUUID == display }
            guard mine.count >= minimumSamplesPerDisplay else { return .failure(.tooFewSamples(displayUUID: display)) }
            targets.append(LookModel.Target(displayUUID: display,
                                            pitch: spread(of: mine.map(\.pitch)), yaw: spread(of: mine.map(\.yaw))))
        }
        let pooled = LookModel.pooledSpread(targets)
        for (i, a) in targets.enumerated() {
            for b in targets.dropFirst(i + 1) where LookModel.separation(a, b, spread: pooled) < minimumSeparation {
                return .failure(.indistinct(a.displayUUID, b.displayUUID))
            }
        }
        let heights = samples.map(\.faceHeight).sorted()
        return .success(LookModel.Pass(faceHeight: heights.isEmpty ? 0 : heights[heights.count / 2], targets: targets))
    }

    static func quality(of pass: LookModel.Pass) -> Quality {
        LookModel.weakestSeparation(pass) >= clearSeparation ? .clear : .weak
    }

    private static func spread(of values: [Double]) -> LookModel.Spread {
        let sorted = values.sorted()
        let cut = Int(Double(sorted.count) * 0.05)
        let kept = sorted.count > 2 * cut ? Array(sorted[cut..<(sorted.count - cut)]) : sorted
        let mean = kept.reduce(0, +) / Double(kept.count)
        let variance = kept.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(kept.count)
        return LookModel.Spread(mean: mean, sd: variance.squareRoot())
    }
}

/// Decides which display the user is looking at, frame by frame, with hysteresis so a glance or
/// jitter at the edge between screens doesn't move the cursor.
struct LookPicker {
    var model: LookModel
    /// How long the head must point at another display before the pick changes.
    static let dwell: TimeInterval = 0.25
    /// Another display must be this many pooled spreads closer than the current one to count.
    /// Between two screens that leaves a dead band a quarter spread either side of the midpoint,
    /// where the pick stays put.
    static let margin: Double = 0.5

    private(set) var current: String?
    private var candidate: (uuid: String, since: TimeInterval)?
    /// After a manual switch: the display the head pointed at when it happened (nil until the next
    /// face). The head has to point somewhere else before it can pick again, so a manual switch
    /// isn't undone the moment it's made.
    private var hold: (active: Bool, headPick: String?) = (false, nil)

    init(model: LookModel) {
        self.model = model
    }

    /// The display to control after this frame, nil until the first face is seen. `locked` means a
    /// drag, scroll, zoom or held key is in progress; the switch waits until it ends. No face, or a
    /// face without angles, leaves the pick alone.
    mutating func update(_ face: FacePose?, at time: TimeInterval, locked: Bool) -> String? {
        guard let face, let pitch = face.pitch, let yaw = face.yaw else {
            candidate = nil
            return current
        }
        let targets = model.targets(atFaceHeight: face.box.height)
        let spread = LookModel.pooledSpread(targets)
        let p = pitch * 180 / .pi, y = yaw * 180 / .pi
        let distances = targets.map { (uuid: $0.displayUUID, distance: Self.distance(pitch: p, yaw: y, to: $0, spread: spread)) }
        guard let best = distances.min(by: { $0.distance < $1.distance }) else { return current }
        if hold.active, hold.headPick == nil { hold.headPick = best.uuid }
        guard let current else {
            self.current = best.uuid
            candidate = nil
            return best.uuid
        }
        // What the head has to leave: during a hold, where it pointed at the switch; otherwise the
        // current display. Leaving takes the same margin and dwell as a switch, so edge jitter on a
        // weak calibration can't release a hold and then undo the switch.
        let anchor = hold.active ? hold.headPick ?? current : current
        let anchorDistance = distances.first { $0.uuid == anchor }?.distance ?? .infinity
        guard best.uuid != anchor, anchorDistance - best.distance >= Self.margin else {
            candidate = nil
            return current
        }
        if candidate?.uuid != best.uuid { candidate = (best.uuid, time) }
        guard let candidate, time - candidate.since >= Self.dwell else { return current }
        hold = (false, nil)
        if candidate.uuid == current {
            self.candidate = nil
        } else if !locked {
            self.current = candidate.uuid
            self.candidate = nil
        }
        return self.current
    }

    /// A manual switch (the Switch display action). Sticks until the head has turned toward a
    /// different display than the one it points at now, for as long as a normal switch takes.
    mutating func override(to uuid: String) {
        current = uuid
        candidate = nil
        hold = (true, nil)
    }

    /// Distance from a head direction to a display's average, in pooled spreads.
    static func distance(pitch: Double, yaw: Double, to target: LookModel.Target,
                         spread: (pitch: Double, yaw: Double)) -> Double {
        let dp = (pitch - target.pitch.mean) / spread.pitch
        let dy = (yaw - target.yaw.mean) / spread.yaw
        return (dp * dp + dy * dy).squareRoot()
    }
}
