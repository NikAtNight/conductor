import Vision
import CoreMedia

/// Wraps VNDetectHumanHandPoseRequest. Call `detect` from the camera queue; it is synchronous and
/// takes a few milliseconds per frame on Apple silicon.
final class HandTracker {
    private let request: VNDetectHumanHandPoseRequest
    private let minimumJointConfidence: Float

    init(maximumHands: Int = 2, minimumJointConfidence: Float = 0.3) {
        request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = maximumHands
        self.minimumJointConfidence = minimumJointConfidence
    }

    func detect(in sampleBuffer: CMSampleBuffer) -> [HandPose] {
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        return (request.results ?? []).compactMap(convert)
    }

    private func convert(_ observation: VNHumanHandPoseObservation) -> HandPose? {
        guard let all = try? observation.recognizedPoints(.all) else { return nil }
        var joints: [HandJoint: CGPoint] = [:]
        var confidence: [HandJoint: Float] = [:]
        for joint in HandJoint.allCases {
            guard let point = all[joint.visionName], point.confidence >= minimumJointConfidence else { continue }
            joints[joint] = point.location
            confidence[joint] = point.confidence
        }
        guard joints[.wrist] != nil else { return nil }
        let chirality: Chirality
        switch observation.chirality {
        case .left: chirality = .left
        case .right: chirality = .right
        default: chirality = .unknown
        }
        return HandPose(joints: joints, confidence: confidence, chirality: chirality)
    }
}

extension HandJoint {
    var visionName: VNHumanHandPoseObservation.JointName {
        switch self {
        case .wrist: return .wrist
        case .thumbCMC: return .thumbCMC
        case .thumbMP: return .thumbMP
        case .thumbIP: return .thumbIP
        case .thumbTip: return .thumbTip
        case .indexMCP: return .indexMCP
        case .indexPIP: return .indexPIP
        case .indexDIP: return .indexDIP
        case .indexTip: return .indexTip
        case .middleMCP: return .middleMCP
        case .middlePIP: return .middlePIP
        case .middleDIP: return .middleDIP
        case .middleTip: return .middleTip
        case .ringMCP: return .ringMCP
        case .ringPIP: return .ringPIP
        case .ringDIP: return .ringDIP
        case .ringTip: return .ringTip
        case .littleMCP: return .littleMCP
        case .littlePIP: return .littlePIP
        case .littleDIP: return .littleDIP
        case .littleTip: return .littleTip
        }
    }

    /// Bones drawn in the preview overlay, as (parent, child) pairs.
    static let bones: [(HandJoint, HandJoint)] = [
        (.wrist, .thumbCMC), (.thumbCMC, .thumbMP), (.thumbMP, .thumbIP), (.thumbIP, .thumbTip),
        (.wrist, .indexMCP), (.indexMCP, .indexPIP), (.indexPIP, .indexDIP), (.indexDIP, .indexTip),
        (.wrist, .middleMCP), (.middleMCP, .middlePIP), (.middlePIP, .middleDIP), (.middleDIP, .middleTip),
        (.wrist, .ringMCP), (.ringMCP, .ringPIP), (.ringPIP, .ringDIP), (.ringDIP, .ringTip),
        (.wrist, .littleMCP), (.littleMCP, .littlePIP), (.littlePIP, .littleDIP), (.littleDIP, .littleTip),
        (.indexMCP, .middleMCP), (.middleMCP, .ringMCP), (.ringMCP, .littleMCP),
    ]
}
