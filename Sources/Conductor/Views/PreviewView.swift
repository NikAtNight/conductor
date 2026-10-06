import SwiftUI
import AVFoundation

/// Camera preview with the detected skeleton drawn on top, and beside it a panel of every bound
/// gesture showing which one the hand is making. Mirrored so it behaves like a mirror, which is
/// what people expect when they move their hand and watch the screen.
struct PreviewView: View {
    @ObservedObject var state: TrackingState
    @ObservedObject var preferences: Preferences
    let session: AVCaptureSession

    var body: some View {
        HStack(spacing: 0) {
            camera
            GesturePanel(state: state, preferences: preferences)
                .frame(width: 260)
        }
        .frame(minWidth: 740, minHeight: 360)
    }

    private var camera: some View {
        ZStack(alignment: .bottomLeading) {
            CameraLayerView(session: session, hands: state.hands, face: state.face,
                            controlBox: ScreenMapper.visionRect(forViewBox: state.controlBox, mirrored: preferences.mirrored),
                            onBoxEdited: { preferences.calibratedBox = $0 })
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) {
                    Text(state.gestureLabel).fontWeight(.semibold)
                    Text(String(format: "%.0f fps", state.fps)).foregroundStyle(.secondary)
                    if let face = state.face, let pitch = face.pitch, let yaw = face.yaw {
                        Text(String(format: "head pitch %.0f° yaw %.0f°", pitch * 180 / .pi, yaw * 180 / .pi))
                            .foregroundStyle(.cyan)
                    }
                    if let name = state.targetDisplayName {
                        Text("Controlling \(name)").foregroundStyle(.cyan)
                    }
                    if let error = state.error {
                        Text(error).foregroundStyle(.red)
                    } else if let warning = state.warning {
                        Text(warning).foregroundStyle(.orange)
                    }
                }
                .font(.system(.body, design: .monospaced))
                Text(preferences.calibratedBox == nil
                     ? "The dashed box maps to your screen. Drag it to move, drag a corner to resize."
                     : "Your box. Drag to move, drag a corner to resize; Settings > Tracking > Use automatic resets it.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(8)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
            .padding(10)
        }
        .frame(minWidth: 480, minHeight: 360)
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
    }
}

/// Every bound trigger with its picture and action. The one the hand is making lights up, and each
/// pinch shows how close its fingertip is to the thumb, so you can see a pinch about to fire and
/// which finger Conductor thinks is closest.
private struct GesturePanel: View {
    @ObservedObject var state: TrackingState
    @ObservedObject var preferences: Preferences

    var body: some View {
        let map = preferences.gestureMap
        let hand = GestureRecognizer.primaryHand(state.hands, prefer: preferences.mainHand)
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("What your hand is doing").font(.headline)
                Text(state.gestureLabel).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Divider()
                ForEach(Trigger.allCases.filter { map[$0] != .none }) { trigger in
                    row(trigger, action: map[trigger], hand: hand)
                }
                if preferences.appProfiles.isEmpty == false {
                    Text("Shows the Everywhere bindings. An app with its own profile may differ.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(12)
        }
        .background(.background)
    }

    private func row(_ trigger: Trigger, action: GestureAction, hand: HandPose?) -> some View {
        let active = state.activeTrigger == trigger
        return HStack(spacing: 8) {
            HandSignView(trigger: trigger, hand: preferences.mainHand)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(trigger.title).font(.caption).fontWeight(active ? .semibold : .regular)
                Text(action.title).font(.caption2).foregroundStyle(.secondary)
                if let closeness = closeness(of: trigger, in: hand) {
                    ProgressView(value: closeness)
                        .tint(active ? .accentColor : .secondary)
                        .frame(maxWidth: 140)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(active ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }

    /// For a pinch: 0 with the fingertip at release distance or further, 1 at engage or closer.
    private func closeness(of trigger: Trigger, in hand: HandPose?) -> Double? {
        guard let tip = trigger.fingertip, let hand, let distance = hand.normalizedDistance(.thumbTip, tip) else { return nil }
        let engage = preferences.pinchEngage, release = preferences.pinchRelease
        guard release > engage else { return nil }
        return ((release - Double(distance)) / (release - engage)).clamped(to: 0...1)
    }
}

private struct CameraLayerView: NSViewRepresentable {
    let session: AVCaptureSession
    let hands: [HandPose]
    let face: FacePose?
    let controlBox: CGRect
    /// Gets the box the user dragged out, in Vision space.
    let onBoxEdited: (CGRect) -> Void

    func makeNSView(context: Context) -> SkeletonOverlayView {
        let view = SkeletonOverlayView(session: session)
        view.onBoxEdited = onBoxEdited
        return view
    }

    func updateNSView(_ view: SkeletonOverlayView, context: Context) {
        view.onBoxEdited = onBoxEdited
        view.controlBox = controlBox
        view.face = face
        view.hands = hands
    }
}

/// The camera picture with the hand skeleton, the face, and the control box drawn over it. The box
/// can be dragged: inside to move it, by a corner to resize it. When the drag ends the box is handed
/// back in Vision space and saved as the calibrated box.
final class SkeletonOverlayView: NSView {
    private let previewLayer: AVCaptureVideoPreviewLayer
    private let skeleton = CAShapeLayer()
    private let dots = CAShapeLayer()
    private let box = CAShapeLayer()
    /// Squares on the box's corners, so it reads as something you can grab.
    private let handles = CAShapeLayer()
    private let boxLabel = CATextLayer()
    /// Face box, eye outlines and pupils, in cyan so they read apart from the hand.
    private let faceLines = CAShapeLayer()

    var hands: [HandPose] = [] {
        didSet { redraw() }
    }

    /// Set before `hands` each frame; `hands` triggers the redraw.
    var face: FacePose?

    var controlBox: CGRect = CGRect(x: 0.2, y: 0.25, width: 0.6, height: 0.5) {
        didSet {
            if controlBox != oldValue {
                redraw()
                window?.invalidateCursorRects(for: self)
            }
        }
    }

    var onBoxEdited: ((CGRect) -> Void)?

    private enum Handle: Equatable {
        case move
        /// Which corner: the right-hand edge and the top edge, in layer coordinates.
        case corner(right: Bool, top: Bool)
    }

    /// Where a drag started, the box it started from (layer coordinates), and what it grabs.
    private var drag: (start: CGPoint, original: CGRect, handle: Handle)?
    /// The box as it's being dragged, layer coordinates. Drawn instead of `controlBox` meanwhile.
    private var liveBox: CGRect?
    private static let grabRadius: CGFloat = 14

    override func resetCursorRects() {
        let rect = layerRect(for: controlBox)
        addCursorRect(rect, cursor: .openHand)
        for (dx, dy) in [(rect.minX, rect.minY), (rect.maxX, rect.minY), (rect.minX, rect.maxY), (rect.maxX, rect.maxY)] {
            addCursorRect(CGRect(x: dx - Self.grabRadius, y: dy - Self.grabRadius, width: 2 * Self.grabRadius, height: 2 * Self.grabRadius),
                          cursor: .crosshair)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let rect = layerRect(for: controlBox)
        for (right, top) in [(false, false), (true, false), (false, true), (true, true)] {
            let corner = CGPoint(x: right ? rect.maxX : rect.minX, y: top ? rect.maxY : rect.minY)
            if corner.distance(to: p) <= Self.grabRadius {
                drag = (p, rect, .corner(right: right, top: top))
                return
            }
        }
        guard rect.contains(p) else { return }
        drag = (p, rect, .move)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let p = convert(event.locationInWindow, from: nil)
        var rect = drag.original
        switch drag.handle {
        case .move:
            rect.origin.x += p.x - drag.start.x
            rect.origin.y += p.y - drag.start.y
        case .corner(let right, let top):
            let fixedX = right ? rect.minX : rect.maxX, fixedY = top ? rect.minY : rect.maxY
            rect = CGRect(x: min(fixedX, p.x), y: min(fixedY, p.y), width: abs(p.x - fixedX), height: abs(p.y - fixedY))
        }
        liveBox = rect
        redraw()
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            drag = nil
            liveBox = nil
            redraw()
        }
        guard drag != nil, let rect = liveBox else { return }
        // Back to Vision space (the capture device's normalized coordinates), clamped to the
        // frame and to the smallest box calibration itself would accept.
        let a = previewLayer.captureDevicePointConverted(fromLayerPoint: rect.origin)
        let b = previewLayer.captureDevicePointConverted(fromLayerPoint: CGPoint(x: rect.maxX, y: rect.maxY))
        var vision = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !vision.isNull else { return }
        vision.size.width = max(vision.width, Calibration.minimumWidth)
        vision.size.height = max(vision.height, Calibration.minimumHeight)
        vision.origin.x = min(vision.minX, 1 - vision.width)
        vision.origin.y = min(vision.minY, 1 - vision.height)
        onBoxEdited?(vision)
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
        faceLines.strokeColor = NSColor.systemCyan.cgColor
        faceLines.lineWidth = 1.5
        faceLines.fillColor = nil
        handles.fillColor = NSColor.systemGreen.cgColor
        handles.strokeColor = NSColor.black.withAlphaComponent(0.6).cgColor
        handles.lineWidth = 1
        boxLabel.string = "Control box: drag to move, corners to resize"
        boxLabel.fontSize = 10
        boxLabel.foregroundColor = NSColor.systemGreen.cgColor
        boxLabel.alignmentMode = .left
        boxLabel.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        previewLayer.addSublayer(box)
        previewLayer.addSublayer(handles)
        previewLayer.addSublayer(boxLabel)
        previewLayer.addSublayer(faceLines)
        previewLayer.addSublayer(skeleton)
        previewLayer.addSublayer(dots)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        skeleton.frame = bounds
        dots.frame = bounds
        box.frame = bounds
        handles.frame = bounds
        faceLines.frame = bounds
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
        let faceShapes = CGMutablePath()
        if let face {
            faceShapes.addRect(layerRect(for: face.box))
            for eye in [face.leftEye, face.rightEye].compactMap({ $0 }) {
                let outline = eye.outline.map { previewLayer.layerPointConverted(fromCaptureDevicePoint: $0) }
                if let first = outline.first {
                    faceShapes.move(to: first)
                    for p in outline.dropFirst() { faceShapes.addLine(to: p) }
                    faceShapes.closeSubpath()
                }
                if let pupil = eye.pupil {
                    let p = previewLayer.layerPointConverted(fromCaptureDevicePoint: pupil)
                    points.addEllipse(in: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
                }
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let boxRect = liveBox ?? layerRect(for: controlBox)
        box.path = CGPath(rect: boxRect, transform: nil)
        box.lineDashPattern = liveBox == nil ? [6, 4] : nil
        let squares = CGMutablePath()
        for (x, y) in [(boxRect.minX, boxRect.minY), (boxRect.maxX, boxRect.minY), (boxRect.minX, boxRect.maxY), (boxRect.maxX, boxRect.maxY)] {
            squares.addRect(CGRect(x: x - 4, y: y - 4, width: 8, height: 8))
        }
        handles.path = squares
        // The label sits just inside the top-left corner (layer y grows upward).
        boxLabel.frame = CGRect(x: boxRect.minX + 8, y: boxRect.maxY - 18, width: max(boxRect.width - 16, 0), height: 14)
        boxLabel.isHidden = boxRect.width < 180
        faceLines.path = faceShapes
        skeleton.path = bones
        dots.path = points
        CATransaction.commit()
    }

    /// A Vision-space rectangle in layer coordinates. Mirroring can swap the corners.
    private func layerRect(for rect: CGRect) -> CGRect {
        let corner1 = previewLayer.layerPointConverted(fromCaptureDevicePoint: rect.origin)
        let corner2 = previewLayer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(x: min(corner1.x, corner2.x), y: min(corner1.y, corner2.y),
                      width: abs(corner2.x - corner1.x), height: abs(corner2.y - corner1.y))
    }
}
