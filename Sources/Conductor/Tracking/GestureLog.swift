import AVFoundation
import CoreGraphics
import Foundation

/// Record of every camera frame while tracking runs: what the tracker saw, the measurements the
/// recognizer decides with, and what it did. For tuning thresholds against real hands. One JSON
/// object per line, landmarks and numbers only, never camera images. A bounded worker encodes
/// and writes away from the camera queue. Engine opens one per session; `prune` keeps the folder
/// from growing without end.
final class GestureLog: @unchecked Sendable {
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
        /// Index tip past the middle tip, in palm widths. Positive is crossed.
        var fingerCross: Double?
        var fist: Bool
        var openHand: Bool
    }

    /// The user's face, for working out which display they're looking at.
    struct Face: Encodable {
        /// Vision space: x, y, width, height. Height is the distance gauge.
        var box: [Double]
        /// Degrees. Pitch is positive nodding down.
        var roll: Double?
        var yaw: Double?
        var pitch: Double?
        var landmarkConfidence: Double?
        var leftEye: Eye?
        var rightEye: Eye?
    }

    struct Eye: Encodable {
        var pupil: [Double]?
        /// Pupil position inside the eye opening, -1...1 each axis, +y toward the upper lid.
        var gaze: [Double]?
        var openness: Double?
        var glare: Double?
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
        var face: Face?
        /// Where the cursor was sent this frame, in global screen points.
        var cursor: [Double]?
        /// Milliseconds since the camera delivered the previous frame; stalls show up here.
        var sinceLastMs: Double?
        /// Milliseconds spent in Vision on hands, on the face, and in the whole frame before this
        /// line was written.
        var detectMs: Double
        var faceMs: Double?
        var processMs: Double
        /// The tracking quality warning showing, if any (too dark, unsure).
        var warning: String?
        /// Set on frames taken at the power-saving rate, with no hand seen for a minute.
        var idle: Bool?
    }

    /// What a recording was made on and with: the first line of every log, and again whenever any
    /// of it changes. Needed to read the frames back, since an action in the log means nothing
    /// without the thresholds that fired it. Product names, sizes and settings; nothing that names
    /// the person or the hardware: per-app profiles are reduced to a count so the apps they use
    /// stay private, and camera and display UUIDs give way to names.
    struct Setup: Encodable, Equatable {
        struct Display: Encodable, Equatable {
            var name: String
            /// Points, in the global layout (origin at the main display's top-left, y down).
            var x: Double
            var y: Double
            var width: Double
            var height: Double
            /// Pixels per point; 2 on a Retina display.
            var scale: Double
            var builtin: Bool
            var main: Bool
        }

        struct Camera: Encodable, Equatable {
            var name: String
            var model: String
            var builtin: Bool
            /// The camera's active format.
            var width: Int
            var height: Int
            var maxFps: Double?
        }

        struct Placement: Encodable, Equatable {
            var display: String
            /// Along the display's width, 0 = left edge, 1 = right edge.
            var x: Double
        }

        /// The random ID this install made for itself; see LogUploader.installID.
        var install: String
        var version: String?
        var build: String?
        var macOS: String
        /// The Mac's model identifier, like Mac14,6.
        var model: String
        var arch: String
        var displays: [Display]
        var camera: Camera?
        var placement: Placement?
        var accessibility: Bool
        var settings: Settings
        var appProfiles: Int

        /// Gathers the live values. Main thread, for NSScreen.
        init(install: String, displays: [DisplayInfo], camera: AVCaptureDevice?, placement: (x: CGFloat, display: DisplayInfo)?,
             accessibility: Bool, settings: Settings, bundle: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
            self.install = install
            version = bundle["CFBundleShortVersionString"] as? String
            build = bundle["CFBundleVersion"] as? String
            macOS = ProcessInfo.processInfo.operatingSystemVersionString
            model = Self.sysctl("hw.model")
            #if arch(arm64)
            arch = "arm64"
            #else
            arch = "x86_64"
            #endif
            self.displays = displays.map { d in
                Display(name: d.name, x: d.bounds.minX, y: d.bounds.minY, width: d.bounds.width, height: d.bounds.height,
                        scale: d.bounds.width > 0 ? (d.pixelSize.width / d.bounds.width).rounded() : 1,
                        builtin: d.isBuiltin, main: d.isMain)
            }
            self.camera = camera.map { device in
                let size = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                let maxFps = device.activeFormat.videoSupportedFrameRateRanges.map(\.maxFrameRate).max()
                return Camera(name: device.localizedName, model: device.modelID,
                              builtin: device.deviceType == .builtInWideAngleCamera,
                              width: Int(size.width), height: Int(size.height), maxFps: maxFps)
            }
            self.placement = placement.map { p in
                Placement(display: p.display.name,
                          x: p.display.bounds.width > 0 ? Double((p.x - p.display.bounds.minX) / p.display.bounds.width) : 0)
            }
            self.accessibility = accessibility
            var settings = settings
            appProfiles = settings.appProfiles.count
            settings.appProfiles = [:]
            // Camera and display UUIDs are hardware identifiers: they'd tie an install to the same
            // Mac across a preferences wipe, which the random install ID is there to avoid. The
            // names above say as much as the analysis needs.
            settings.cameraDeviceID = nil
            settings.cameraPlacement = nil
            let names = Dictionary(displays.map { ($0.uuid, $0.name) }, uniquingKeysWith: { first, _ in first })
            if var model = settings.lookModel {
                for p in model.passes.indices {
                    for t in model.passes[p].targets.indices {
                        model.passes[p].targets[t].displayUUID = names[model.passes[p].targets[t].displayUUID] ?? "a display since unplugged"
                    }
                }
                settings.lookModel = model
            }
            self.settings = settings
        }

        private static func sysctl(_ name: String) -> String {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
            return String(cString: buffer)
        }
    }

    /// Something that happened between frames.
    struct Note: Encodable {
        var time: Double
        var event: String
    }

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Conductor")
    }

    /// The completed name. It becomes readable here only after finalization.
    let url: URL
    let inProgressURL: URL
    let started: Date
    private let writer: GestureLogWriter
    typealias Diagnostics = GestureLogWriter.Diagnostics
    var diagnostics: Diagnostics { writer.diagnostics }

    /// Starts a non-uploadable file. The bounded worker owns its file handle.
    init(directory: URL = GestureLog.directory, date: Date = Date(), bufferCapacity: Int = 256,
         beforeWrite: (() throws -> Void)? = nil) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let created = try GestureLogWriter.withLifecycleLock(directory: directory) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd-HHmmss"
            let stamp = formatter.string(from: date)
            var candidate = directory.appending(path: "gestures-\(stamp).jsonl")
            var n = 2
            while FileManager.default.fileExists(atPath: candidate.path)
                    || FileManager.default.fileExists(atPath: candidate.path + ".inprogress") {
                candidate = directory.appending(path: "gestures-\(stamp)-\(n).jsonl")
                n += 1
            }
            let active = URL(fileURLWithPath: candidate.path + ".inprogress")
            let writer = try GestureLogWriter(activeURL: active, finalURL: candidate, capacity: bufferCapacity,
                                              beforeWrite: beforeWrite)
            return (candidate, active, writer)
        }
        url = created.0
        inProgressURL = created.1
        writer = created.2
        started = date
    }

    deinit { writer.finish(completion: {}) }

    /// Rejects new records immediately, then drains, closes, and atomically publishes the file.
    func finish(completion: @escaping @Sendable () -> Void = {}) { writer.finish(completion: completion) }

    /// Shutdown path only. Normal rotation uses finish so the camera queue keeps moving.
    func finishAndWait() { writer.finishAndWait() }

    /// Call once before opening new logs. Locked writers in other app processes are skipped.
    @discardableResult
    static func recoverInterruptedLogs(directory: URL = GestureLog.directory) -> [URL] {
        GestureLogWriter.recover(directory: directory)
    }

    /// Keeps the folder bounded now that every session is logged: logs and reports older than
    /// `keepDays`, and the oldest once the total passes `keepBytes`, are deleted. The log being
    /// written is never touched, nor is anything else in the folder. Returns what it deleted.
    @discardableResult
    static func prune(directory: URL = GestureLog.directory, keepBytes: Int = 1 << 30, keepDays: Int = 7,
                      excluding active: URL? = nil, now: Date = Date()) -> [String] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else { return [] }
        let ours = files.compactMap { url -> (url: URL, size: Int, modified: Date)? in
            guard url.standardizedFileURL != active?.standardizedFileURL, LogUploader.Kind(fileName: url.lastPathComponent) != nil,
                  let values = try? url.resourceValues(forKeys: keys), let size = values.fileSize,
                  let modified = values.contentModificationDate else { return nil }
            return (url, size, modified)
        }.sorted { $0.modified > $1.modified }
        let cutoff = now.addingTimeInterval(-Double(keepDays) * 86400)
        var total = 0
        var deleted: [String] = []
        for file in ours {
            total += file.size
            guard file.modified < cutoff || total > keepBytes else { continue }
            if (try? FileManager.default.removeItem(at: file.url)) != nil { deleted.append(file.url.lastPathComponent) }
        }
        return deleted
    }

    func write(time: Date, fps: Double, hands: [HandPose], primary: HandPose?, face: FacePose? = nil,
               output: GestureRecognizer.Output, cursor: CGPoint?,
               sinceLastMs: Double?, detectMs: Double, faceMs: Double? = nil, processMs: Double,
               warning: String? = nil, idle: Bool = false) {
        writer.append(.frame(Frame(
            time: time.timeIntervalSince1970, fps: fps, mode: output.mode.rawValue, label: output.label,
            actions: output.actions.map { String(describing: $0) },
            hands: hands.map(Self.hand), primary: primary.map(Self.measures), face: face.map(Self.face),
            cursor: cursor.map { [Self.round($0.x, places: 1), Self.round($0.y, places: 1)] },
            sinceLastMs: sinceLastMs.map { Self.round($0, places: 1) },
            detectMs: Self.round(detectMs, places: 1), faceMs: faceMs.map { Self.round($0, places: 1) },
            processMs: Self.round(processMs, places: 1), warning: warning, idle: idle ? true : nil)))
    }

    func setup(_ setup: Setup) {
        writer.append(.setup(setup, Date().timeIntervalSince1970))
    }

    func note(_ event: String) {
        writer.append(.note(Note(time: Date().timeIntervalSince1970, event: event)))
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
                        othersCurled: pose.othersCurled, fingerCross: pose.fingerCross.map { round($0) },
                        fist: pose.isFist, openHand: pose.isOpenHand)
    }

    private static func face(_ pose: FacePose) -> Face {
        func degrees(_ radians: Double?) -> Double? { radians.map { round($0 * 180 / .pi, places: 1) } }
        return Face(box: [round(pose.box.minX), round(pose.box.minY), round(pose.box.width), round(pose.box.height)],
                    roll: degrees(pose.roll), yaw: degrees(pose.yaw), pitch: degrees(pose.pitch),
                    landmarkConfidence: pose.landmarkConfidence.map { round(CGFloat($0), places: 2) },
                    leftEye: pose.leftEye.map(eye), rightEye: pose.rightEye.map(eye))
    }

    private static func eye(_ eye: FacePose.Eye) -> Eye {
        Eye(pupil: eye.pupil.map { [round($0.x), round($0.y)] },
            gaze: eye.gaze.map { [round($0.dx, places: 2), round($0.dy, places: 2)] },
            openness: eye.openness.map { round($0, places: 2) },
            glare: eye.glare.map { round($0, places: 2) })
    }

    private static func round(_ value: CGFloat, places: Int = 4) -> Double {
        let scale = pow(10, Double(places))
        return (Double(value) * scale).rounded() / scale
    }
}
