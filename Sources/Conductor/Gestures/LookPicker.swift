import CoreGraphics
import Foundation

/// Where each display sits in head-angle space, measured by look calibration. Angles are degrees
/// with Vision's signs: pitch positive looking down, yaw positive turning counterclockwise.
///
/// One pass per sitting distance. Up close the head follows the eyes; further back it moves far
/// less than the geometry says because the eyes do more of the work, so a single pass can't be
/// scaled to cover both. Passes are anchors and the picker interpolates between them.
struct LookModel: Codable, Equatable {
    struct Target: Codable, Equatable {
        var displayUUID: String
        /// Head angles seen while looking around this display, corner to corner.
        var pitch: ClosedRange<Double>
        var yaw: ClosedRange<Double>
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
    /// two passes each bound is interpolated by face height. Beyond the nearest or furthest pass
    /// the tangent rule scales that pass (see `scaled`). A display missing from one of the two
    /// bracketing passes is taken from the other as is.
    func targets(atFaceHeight faceHeight: Double) -> [Target] {
        guard let first = passes.first, let last = passes.last else { return [] }
        if faceHeight <= first.faceHeight { return Self.scaled(first, to: faceHeight) }
        if faceHeight >= last.faceHeight { return Self.scaled(last, to: faceHeight) }
        guard let upper = passes.firstIndex(where: { $0.faceHeight >= faceHeight }), upper > 0 else {
            return Self.scaled(last, to: faceHeight)
        }
        let far = passes[upper - 1], near = passes[upper]
        let t = (faceHeight - far.faceHeight) / (near.faceHeight - far.faceHeight)
        func mix(_ a: ClosedRange<Double>, _ b: ClosedRange<Double>) -> ClosedRange<Double> {
            let lo = a.lowerBound + t * (b.lowerBound - a.lowerBound)
            let hi = a.upperBound + t * (b.upperBound - a.upperBound)
            return min(lo, hi)...max(lo, hi)
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
        return pass.targets.map {
            Target(displayUUID: $0.displayUUID, pitch: scaled($0.pitch, by: ratio), yaw: scaled($0.yaw, by: ratio))
        }
    }

    /// A range measured at one distance, as it looks from another. The angle to a point on a screen
    /// has tan(angle) = offset / distance, and face height is proportional to 1 / distance, so the
    /// tangent scales with the face height ratio. Only a rough guide: real heads move less than
    /// this when far away, which is what extra passes are for.
    static func scaled(_ range: ClosedRange<Double>, by ratio: Double) -> ClosedRange<Double> {
        func scale(_ degrees: Double) -> Double { atan(tan(degrees * .pi / 180) * ratio) * 180 / .pi }
        let a = scale(range.lowerBound), b = scale(range.upperBound)
        return min(a, b)...max(a, b)
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
        /// Two displays' angle rectangles overlap so much the head can't tell them apart.
        case indistinct(String, String)
    }

    /// How long each target shows, how much of that is ignored while the eyes travel to it, and
    /// how many frames each display needs across all its targets.
    static let settle: TimeInterval = 0.5
    static let samplePeriod: TimeInterval = 1.0
    static let minimumSamplesPerDisplay = 15
    /// Fraction of the smaller rectangle that another may cover before the pair is indistinct.
    static let maximumOverlap = 0.5

    /// A sample from one frame, or nil when Vision didn't report the head angles.
    static func sample(_ face: FacePose, display: String) -> Sample? {
        guard let pitch = face.pitch, let yaw = face.yaw else { return nil }
        return Sample(displayUUID: display, pitch: pitch * 180 / .pi, yaw: yaw * 180 / .pi, faceHeight: face.box.height)
    }

    /// One target per display, from the 5th to 95th percentile of its samples on each axis so a
    /// stray frame can't stretch it. The pass's face height is the median over all samples.
    static func pass(from samples: [Sample], displays: [String]) -> Result<LookModel.Pass, Failure> {
        var targets: [LookModel.Target] = []
        for display in displays {
            let mine = samples.filter { $0.displayUUID == display }
            guard mine.count >= minimumSamplesPerDisplay else { return .failure(.tooFewSamples(displayUUID: display)) }
            targets.append(LookModel.Target(displayUUID: display,
                                            pitch: range(of: mine.map(\.pitch)), yaw: range(of: mine.map(\.yaw))))
        }
        for (i, a) in targets.enumerated() {
            for b in targets.dropFirst(i + 1) where overlap(a, b) > maximumOverlap {
                return .failure(.indistinct(a.displayUUID, b.displayUUID))
            }
        }
        let heights = samples.map(\.faceHeight).sorted()
        return .success(LookModel.Pass(faceHeight: heights.isEmpty ? 0 : heights[heights.count / 2], targets: targets))
    }

    private static func range(of values: [Double]) -> ClosedRange<Double> {
        let sorted = values.sorted()
        func percentile(_ q: Double) -> Double { sorted[Int((Double(sorted.count - 1) * q).rounded())] }
        return percentile(0.05)...percentile(0.95)
    }

    /// Shared area over the smaller target's area, in degrees squared. Ranges narrower than a
    /// degree count as a degree so a steady head doesn't make a zero-area target.
    private static func overlap(_ a: LookModel.Target, _ b: LookModel.Target) -> Double {
        func span(_ r: ClosedRange<Double>) -> Double { max(r.upperBound - r.lowerBound, 1) }
        func shared(_ x: ClosedRange<Double>, _ y: ClosedRange<Double>) -> Double {
            max(0, min(x.upperBound, y.upperBound) - max(x.lowerBound, y.lowerBound))
        }
        let intersection = shared(a.pitch, b.pitch) * shared(a.yaw, b.yaw)
        let smaller = min(span(a.pitch) * span(a.yaw), span(b.pitch) * span(b.yaw))
        return intersection / smaller
    }
}

/// Decides which display the user is looking at, frame by frame, with hysteresis so a glance or
/// jitter at the seam between screens doesn't move the cursor.
struct LookPicker {
    var model: LookModel
    /// How long the head must point at another display before the pick changes.
    static let dwell: TimeInterval = 0.25
    /// Another display must be this many degrees closer than the current one to count. Inside the
    /// current target the distance is zero, so nothing can beat it: ambiguous means stay put.
    static let margin: Double = 1.0

    private(set) var current: String?
    private var candidate: (uuid: String, since: TimeInterval)?

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
        let p = pitch * 180 / .pi, y = yaw * 180 / .pi
        let targets = model.targets(atFaceHeight: face.box.height)
        let distances = targets.map { (uuid: $0.displayUUID, distance: Self.distance(pitch: p, yaw: y, to: $0)) }
        guard let best = distances.min(by: { $0.distance < $1.distance }) else { return current }
        guard let current, let mine = distances.first(where: { $0.uuid == current }) else {
            current = best.uuid
            candidate = nil
            return current
        }
        guard best.uuid != current, mine.distance - best.distance >= Self.margin else {
            candidate = nil
            return current
        }
        if candidate?.uuid != best.uuid { candidate = (best.uuid, time) }
        if !locked, let candidate, time - candidate.since >= Self.dwell {
            self.current = candidate.uuid
            self.candidate = nil
        }
        return self.current
    }

    /// Degrees from a head direction to the nearest point of a target, zero inside it.
    static func distance(pitch: Double, yaw: Double, to target: LookModel.Target) -> Double {
        let dp = max(target.pitch.lowerBound - pitch, 0, pitch - target.pitch.upperBound)
        let dy = max(target.yaw.lowerBound - yaw, 0, yaw - target.yaw.upperBound)
        return (dp * dp + dy * dy).squareRoot()
    }
}
