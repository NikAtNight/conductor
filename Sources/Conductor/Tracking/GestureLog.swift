import CoreGraphics
import Foundation

/// Opt-in record of every camera frame: what the tracker saw, the measurements the recognizer
/// decides with, and what it did. For tuning thresholds against real hands. One JSON object per
/// line, landmarks and numbers only, never camera images. Used from the camera queue only.
final class GestureLog {
    struct Hand: Encodable {
        var chirality: String
        /// Vision space (origin bottom-left, un-mirrored). Joints Vision didn't find are left out.
        var joints: [String: [Double]]
        var confidence: [String: Double]
    }

    /// What the recognizer measures on the hand driving the cursor.
    struct Measures: Encodable {
        var scale: Double?
        var palmWidth: Double?
        /// Thumb tip to each fingertip in hand scales, the number pinch engage and release use.
        var pinch: [String: Double]
        var indexLift: Double?
        /// How long the index finger looks to the camera, in palm widths.
        var indexLength: Double?
        var othersCurled: Bool
        var fist: Bool
        var openHand: Bool
    }

    struct Frame: Encodable {
        /// Unix time in seconds.
        var time: Double
        var fps: Double
        var mode: String
        var label: String
        var actions: [String]
        var hands: [Hand]
        var primary: Measures?
        /// Where the cursor was sent this frame, in global screen points.
        var cursor: [Double]?
        /// Milliseconds since the camera delivered the previous frame; stalls show up here.
        var sinceLastMs: Double?
        /// Milliseconds spent in Vision, and in the whole frame before this line was written.
        var detectMs: Double
        var processMs: Double
    }

    /// Something that happened between frames.
    struct Note: Encodable {
        var time: Double
        var event: String
    }

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Conductor")
    }

    let url: URL
    private let handle: FileHandle
    private let encoder = JSONEncoder()

    /// Starts a new file named for `date`.
    init(directory: URL = GestureLog.directory, date: Date = Date()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let stamp = formatter.string(from: date)
        var candidate = directory.appending(path: "gestures-\(stamp).jsonl")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appending(path: "gestures-\(stamp)-\(n).jsonl")
            n += 1
        }
        url = candidate
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    deinit {
        try? handle.close()
    }

    func write(time: Date, fps: Double, hands: [HandPose], primary: HandPose?,
               output: GestureRecognizer.Output, cursor: CGPoint?,
               sinceLastMs: Double?, detectMs: Double, processMs: Double) {
        append(Frame(
            time: time.timeIntervalSince1970, fps: fps, mode: output.mode.rawValue, label: output.label,
            actions: output.actions.map { String(describing: $0) },
            hands: hands.map(Self.hand), primary: primary.map(Self.measures),
            cursor: cursor.map { [Self.round($0.x, places: 1), Self.round($0.y, places: 1)] },
            sinceLastMs: sinceLastMs.map { Self.round($0, places: 1) },
            detectMs: Self.round(detectMs, places: 1), processMs: Self.round(processMs, places: 1)))
    }

    func note(_ event: String) {
        append(Note(time: Date().timeIntervalSince1970, event: event))
    }

    private func append<T: Encodable>(_ line: T) {
        guard var data = try? encoder.encode(line) else { return }
        data.append(0x0A)
        try? handle.write(contentsOf: data)
    }

    private static func hand(_ pose: HandPose) -> Hand {
        Hand(chirality: String(describing: pose.chirality),
             joints: Dictionary(uniqueKeysWithValues: pose.joints.map { (String(describing: $0.key), [round($0.value.x), round($0.value.y)]) }),
             confidence: Dictionary(uniqueKeysWithValues: pose.confidence.map { (String(describing: $0.key), round(CGFloat($0.value), places: 2)) }))
    }

    private static func measures(_ pose: HandPose) -> Measures {
        var pinch: [String: Double] = [:]
        for tip in [HandJoint.indexTip, .middleTip, .ringTip, .littleTip] {
            if let d = pose.normalizedDistance(.thumbTip, tip) { pinch[String(describing: tip)] = round(d) }
        }
        return Measures(scale: pose.scale.map { round($0) }, palmWidth: pose.palmWidth.map { round($0) }, pinch: pinch,
                        indexLift: pose.indexLift.map { round($0) }, indexLength: pose.visibleLength(of: .indexTip).map { round($0) },
                        othersCurled: pose.othersCurled, fist: pose.isFist, openHand: pose.isOpenHand)
    }

    private static func round(_ value: CGFloat, places: Int = 4) -> Double {
        let scale = pow(10, Double(places))
        return (Double(value) * scale).rounded() / scale
    }
}
