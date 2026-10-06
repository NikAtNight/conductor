import SwiftUI

/// A small drawing of a hand sign: the skeleton of an example pose the way the user sees their own
/// hand in the mirrored preview, plus an arrow for any motion the trigger needs. The examples have
/// the thumb on the viewer's left, which is a right hand with the palm toward you; the left hand is
/// that flipped.
struct HandSignView: View {
    enum Arrow {
        case upDown, leftRight, left, right, apart
    }

    let poses: [HandPose]
    let arrow: Arrow?
    let hand: GestureRecognizer.MainHand
    let label: String

    init(trigger: Trigger, hand: GestureRecognizer.MainHand) {
        self.hand = hand
        label = trigger.title
        switch trigger {
        case .indexPinch: poses = [HandPoseExamples.pinched(.indexTip)]; arrow = nil
        case .middlePinch: poses = [HandPoseExamples.pinched(.middleTip)]; arrow = nil
        case .ringPinch: poses = [HandPoseExamples.pinched(.ringTip)]; arrow = nil
        case .littlePinch: poses = [HandPoseExamples.pinched(.littleTip)]; arrow = nil
        case .fist: poses = [HandPoseExamples.fist()]; arrow = .upDown
        case .twoHandPinch:
            let one = HandPoseExamples.pinched(at: CGPoint(x: 0.3, y: 0.3))
            poses = [one, Self.flipped(one)]
            arrow = .apart
        case .swipeLeft: poses = [HandPoseExamples.twoFingers()]; arrow = .left
        case .swipeRight: poses = [HandPoseExamples.twoFingers()]; arrow = .right
        case .twoFingers: poses = [HandPoseExamples.twoFingers()]; arrow = .upDown
        case .crossedFingers: poses = [HandPoseExamples.crossed()]; arrow = nil
        case .indexPoint: poses = [HandPoseExamples.pointingSign(.up)]; arrow = nil
        }
    }

    init(pose: HandPose, arrow: Arrow? = nil, hand: GestureRecognizer.MainHand, label: String) {
        poses = [pose]
        self.arrow = arrow
        self.hand = hand
        self.label = label
    }

    /// The same hand on the other side of the frame, as the other hand.
    static func flipped(_ hand: HandPose) -> HandPose {
        var flipped = hand
        flipped.joints = hand.joints.mapValues { CGPoint(x: 1 - $0.x, y: $0.y) }
        return flipped
    }

    var body: some View {
        Canvas { context, size in
            let shown = hand == .left ? poses.map(Self.flipped) : poses
            let points = shown.flatMap { $0.joints.values }
            guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
                  let minY = points.map(\.y).min(), let maxY = points.map(\.y).max(),
                  maxX > minX, maxY > minY else { return }
            // Fit the hands into the middle, leaving a margin for the arrow.
            let bounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            let room = CGRect(x: size.width * 0.14, y: size.height * 0.14, width: size.width * 0.72, height: size.height * 0.72)
            let scale = min(room.width / bounds.width, room.height / bounds.height)
            func place(_ p: CGPoint) -> CGPoint {
                CGPoint(x: room.midX + (p.x - bounds.midX) * scale, y: room.midY - (p.y - bounds.midY) * scale)
            }
            for pose in shown {
                var bones = Path()
                for (a, b) in HandJoint.bones {
                    guard let pa = pose[a], let pb = pose[b] else { continue }
                    bones.move(to: place(pa))
                    bones.addLine(to: place(pb))
                }
                context.stroke(bones, with: .color(.primary.opacity(0.75)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                for p in pose.joints.values {
                    let q = place(p)
                    context.fill(Path(ellipseIn: CGRect(x: q.x - 1.6, y: q.y - 1.6, width: 3.2, height: 3.2)), with: .color(.primary))
                }
            }
            if let arrow { Self.draw(arrow, in: &context, size: size) }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel(Text(label))
    }

    private static func draw(_ arrow: Arrow, in context: inout GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        var path = Path()
        func shaft(_ from: CGPoint, _ to: CGPoint, headAt: [CGPoint]) {
            path.move(to: from)
            path.addLine(to: to)
            for tip in headAt {
                // A head is two short strokes pointing back along the shaft.
                let dx = to.x - from.x, dy = to.y - from.y
                let length = max((dx * dx + dy * dy).squareRoot(), 0.001)
                let ux = dx / length, uy = dy / length
                let toward: CGFloat = tip == to ? 1 : -1
                let back = CGPoint(x: tip.x - toward * ux * 5, y: tip.y - toward * uy * 5)
                path.move(to: tip)
                path.addLine(to: CGPoint(x: back.x - uy * 3.5, y: back.y + ux * 3.5))
                path.move(to: tip)
                path.addLine(to: CGPoint(x: back.x + uy * 3.5, y: back.y - ux * 3.5))
            }
        }
        switch arrow {
        case .upDown:
            let a = CGPoint(x: w * 0.93, y: h * 0.28), b = CGPoint(x: w * 0.93, y: h * 0.72)
            shaft(a, b, headAt: [a, b])
        case .leftRight:
            let a = CGPoint(x: w * 0.22, y: h * 0.07), b = CGPoint(x: w * 0.78, y: h * 0.07)
            shaft(a, b, headAt: [a, b])
        case .left:
            shaft(CGPoint(x: w * 0.78, y: h * 0.07), CGPoint(x: w * 0.22, y: h * 0.07), headAt: [CGPoint(x: w * 0.22, y: h * 0.07)])
        case .right:
            shaft(CGPoint(x: w * 0.22, y: h * 0.07), CGPoint(x: w * 0.78, y: h * 0.07), headAt: [CGPoint(x: w * 0.78, y: h * 0.07)])
        case .apart:
            shaft(CGPoint(x: w * 0.42, y: h * 0.93), CGPoint(x: w * 0.1, y: h * 0.93), headAt: [CGPoint(x: w * 0.1, y: h * 0.93)])
            shaft(CGPoint(x: w * 0.58, y: h * 0.93), CGPoint(x: w * 0.9, y: h * 0.93), headAt: [CGPoint(x: w * 0.9, y: h * 0.93)])
        }
        context.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
    }
}
