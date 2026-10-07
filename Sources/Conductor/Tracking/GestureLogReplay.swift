import CoreGraphics
import Foundation

/// Reads the hands back out of a gesture log, so a recording from someone's desk can be run
/// through the recognizer again here with different settings. Only frames are returned; notes
/// between them are skipped.
enum GestureLogReplay {
    struct Frame: Equatable {
        var time: TimeInterval
        var hands: [HandPose]
        /// What the app showed for this frame when it was recorded.
        var label: String
    }

    private struct Line: Decodable {
        struct Hand: Decodable {
            var chirality: String
            var joints: [String: [Double]]
            var confidence: [String: Double]
        }
        var time: Double
        var label: String?
        var hands: [Hand]?
    }

    private static let joints: [String: HandJoint] = Dictionary(
        uniqueKeysWithValues: HandJoint.allCases.map { (String(describing: $0), $0) })

    static func frames(in log: URL) throws -> [Frame] {
        frames(in: try String(contentsOf: log, encoding: .utf8))
    }

    static func frames(in text: String) -> [Frame] {
        let decoder = JSONDecoder()
        var frames: [Frame] = []
        for raw in text.split(separator: "\n") {
            guard let line = try? decoder.decode(Line.self, from: Data(raw.utf8)), let hands = line.hands else { continue }
            frames.append(Frame(time: line.time, hands: hands.map(pose), label: line.label ?? ""))
        }
        return frames
    }

    private static func pose(_ hand: Line.Hand) -> HandPose {
        var joints: [HandJoint: CGPoint] = [:]
        var confidence: [HandJoint: Float] = [:]
        for (name, point) in hand.joints where point.count == 2 {
            guard let joint = Self.joints[name] else { continue }
            joints[joint] = CGPoint(x: point[0], y: point[1])
        }
        for (name, value) in hand.confidence {
            guard let joint = Self.joints[name] else { continue }
            confidence[joint] = Float(value)
        }
        let chirality: Chirality
        switch hand.chirality {
        case "left": chirality = .left
        case "right": chirality = .right
        default: chirality = .unknown
        }
        return HandPose(joints: joints, confidence: confidence, chirality: chirality)
    }
}
