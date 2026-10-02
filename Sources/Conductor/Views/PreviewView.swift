import SwiftUI
import AVFoundation

/// Camera preview with the detected skeleton drawn on top. Mirrored so it behaves like a mirror,
/// which is what people expect when they move their hand and watch the screen.
struct PreviewView: View {
    @ObservedObject var state: TrackingState
    @ObservedObject var preferences: Preferences
    let session: AVCaptureSession

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CameraLayerView(session: session, hands: state.hands,
                            controlBox: controlBox)
            HStack(spacing: 12) {
                Text(state.gestureLabel).fontWeight(.semibold)
                Text(String(format: "%.0f fps", state.fps)).foregroundStyle(.secondary)
                if let error = state.error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .font(.system(.body, design: .monospaced))
            .padding(8)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
            .padding(10)
        }
        .frame(minWidth: 480, minHeight: 360)
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
    }

    /// The control box in Vision's normalized, bottom-left-origin space, before mirroring. The
    /// preview layer handles mirroring itself, so this must not.
    private var controlBox: CGRect {
        let w = preferences.boxWidth, h = preferences.boxHeight
        let left = (1 - w) / 2
        let bottom = (1 - h) / 2 + preferences.boxOffsetY
        return CGRect(x: left, y: bottom, width: w, height: h)
    }
}

private struct CameraLayerView: NSViewRepresentable {
    let session: AVCaptureSession
    let hands: [HandPose]
    let controlBox: CGRect

    func makeNSView(context: Context) -> SkeletonOverlayView {
        let view = SkeletonOverlayView(session: session)
        return view
    }

    func updateNSView(_ view: SkeletonOverlayView, context: Context) {
        view.controlBox = controlBox
        view.hands = hands
    }
}

final class SkeletonOverlayView: NSView {
    private let previewLayer: AVCaptureVideoPreviewLayer
    private let skeleton = CAShapeLayer()
    private let dots = CAShapeLayer()
    private let box = CAShapeLayer()

    var hands: [HandPose] = [] {
        didSet { redraw() }
    }

    var controlBox: CGRect = CGRect(x: 0.2, y: 0.25, width: 0.6, height: 0.5) {
        didSet { if controlBox != oldValue { redraw() } }
    }

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspect
        if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        layer = previewLayer
        skeleton.strokeColor = NSColor.systemGreen.cgColor
        skeleton.lineWidth = 2
        skeleton.fillColor = nil
        dots.fillColor = NSColor.white.cgColor
        box.strokeColor = NSColor.systemGreen.withAlphaComponent(0.7).cgColor
        box.lineWidth = 1.5
        box.lineDashPattern = [6, 4]
        box.fillColor = nil
        previewLayer.addSublayer(box)
        previewLayer.addSublayer(skeleton)
        previewLayer.addSublayer(dots)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        skeleton.frame = bounds
        dots.frame = bounds
        box.frame = bounds
        redraw()
    }

    private func redraw() {
        let bones = CGMutablePath()
        let points = CGMutablePath()
        for hand in hands {
            // Vision points are normalized with a bottom-left origin, which is exactly what
            // `layerPointConverted(fromCaptureDevicePoint:)` expects. It handles mirroring too.
            var converted: [HandJoint: CGPoint] = [:]
            for (joint, p) in hand.joints {
                converted[joint] = previewLayer.layerPointConverted(fromCaptureDevicePoint: p)
            }
            for (a, b) in HandJoint.bones {
                guard let pa = converted[a], let pb = converted[b] else { continue }
                bones.move(to: pa)
                bones.addLine(to: pb)
            }
            for p in converted.values {
                points.addEllipse(in: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
            }
        }
        let corner1 = previewLayer.layerPointConverted(fromCaptureDevicePoint: controlBox.origin)
        let corner2 = previewLayer.layerPointConverted(
            fromCaptureDevicePoint: CGPoint(x: controlBox.maxX, y: controlBox.maxY))
        let boxRect = CGRect(x: min(corner1.x, corner2.x), y: min(corner1.y, corner2.y),
                             width: abs(corner2.x - corner1.x), height: abs(corner2.y - corner1.y))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        box.path = CGPath(rect: boxRect, transform: nil)
        skeleton.path = bones
        dots.path = points
        CATransaction.commit()
    }
}
