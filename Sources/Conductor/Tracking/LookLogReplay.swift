import Foundation

/// Reads a gesture log back and refits the look calibration it recorded, so a run that went wrong
/// at someone's desk can be scored again here. Frames between a dot's "sampling" note and its
/// "done" note belong to that dot's display; the result note carries the score the app showed.
enum LookLogReplay {
    struct Run: Equatable {
        var samples: [LookCalibration.Sample] = []
        /// In order of first appearance, as the calibration showed them.
        var displays: [String] = []
        /// The outcome the app logged: the fitted pass and its separation, the failure, or cancelled.
        var loggedResult: String?
        /// The separation parsed out of `loggedResult`, if the run succeeded.
        var loggedSeparation: Double?

        /// The same fit the app made, from the logged frames.
        var result: Result<LookModel.Pass, LookCalibration.Failure> {
            LookCalibration.pass(from: samples, displays: displays)
        }
    }

    private struct Line: Decodable {
        struct Face: Decodable {
            var box: [Double]
            /// Degrees, as the log writes them.
            var pitch: Double?
            var yaw: Double?
        }
        var event: String?
        var face: Face?
    }

    static let samplingNote = #/look calibration: sampling .* \((.+)\) dot \d+/#
    static let doneNote = #/look calibration: dot \d+ done/#
    static let resultNote = #/look calibration result: (.*)/#
    static let separationInResult = #/separation ([0-9.]+)$/#

    /// The last calibration run in the log, finished or not. Nil when the log has none.
    static func lastRun(in log: URL) throws -> Run? {
        lastRun(in: try String(contentsOf: log, encoding: .utf8))
    }

    static func lastRun(in text: String) -> Run? {
        let decoder = JSONDecoder()
        var runs: [Run] = []
        var sampling: String?
        for raw in text.split(separator: "\n") {
            guard let line = try? decoder.decode(Line.self, from: Data(raw.utf8)) else { continue }
            if let event = line.event {
                if let match = event.firstMatch(of: samplingNote) {
                    let uuid = String(match.1)
                    if runs.isEmpty || runs[runs.count - 1].loggedResult != nil { runs.append(Run()) }
                    if !runs[runs.count - 1].displays.contains(uuid) { runs[runs.count - 1].displays.append(uuid) }
                    sampling = uuid
                } else if event.contains(doneNote) {
                    sampling = nil
                } else if let match = event.firstMatch(of: resultNote), !runs.isEmpty {
                    let result = String(match.1)
                    runs[runs.count - 1].loggedResult = result
                    runs[runs.count - 1].loggedSeparation = result.firstMatch(of: separationInResult).flatMap { Double($0.1) }
                    sampling = nil
                }
                continue
            }
            guard let display = sampling, let face = line.face, let pitch = face.pitch, let yaw = face.yaw,
                  face.box.count == 4 else { continue }
            runs[runs.count - 1].samples.append(
                LookCalibration.Sample(displayUUID: display, pitch: pitch, yaw: yaw, faceHeight: face.box[3]))
        }
        return runs.last
    }
}
