import AppKit
import Combine
import QuartzCore

/// A small ring that follows the cursor and shows what Conductor is about to do:
/// cyan fills as a pinch closes, orange as a dwell click counts down, green while the ready pose
/// is held, indigo as the pointing sign's hold counts down. It flashes when a click lands. While
/// scrolling it stays up in purple, with an arrow for the way the page is going. The window
/// ignores the mouse, so it never gets in the way.
@MainActor
final class CursorRing {
    private let window: NSPanel
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private let flash = CAShapeLayer()
    private let arrow = CAShapeLayer()
    private var arrowDirection: Int?
    private var cancellables: Set<AnyCancellable> = []

    private static let size: CGFloat = 56
    private static let radius: CGFloat = 20

    init(state: TrackingState, preferences: Preferences) {
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let view = NSView(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        view.wantsLayer = true
        let center = CGPoint(x: Self.size / 2, y: Self.size / 2)
        let circle = CGPath(ellipseIn: CGRect(x: center.x - Self.radius, y: center.y - Self.radius,
                                              width: Self.radius * 2, height: Self.radius * 2), transform: nil)
        // The progress arc starts at 12 o'clock and runs clockwise.
        let arcPath = CGMutablePath()
        arcPath.addArc(center: center, radius: Self.radius, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        for layer in [track, arc] {
            layer.fillColor = nil
            layer.lineWidth = 3.5
            layer.lineCap = .round
        }
        track.path = circle
        track.strokeColor = NSColor.black.withAlphaComponent(0.25).cgColor
        arc.path = arcPath
        arc.strokeEnd = 0
        flash.path = circle
        flash.fillColor = NSColor.white.withAlphaComponent(0.55).cgColor
        flash.opacity = 0
        view.layer?.addSublayer(track)
        view.layer?.addSublayer(flash)
        view.layer?.addSublayer(arc)
        arrow.fillColor = nil
        arrow.lineWidth = 3
        arrow.lineCap = .round
        arrow.lineJoin = .round
        arrow.strokeColor = Self.scrollColor.cgColor
        view.layer?.addSublayer(arrow)
        window.contentView = view

        state.$feedback
            .combineLatest(state.$mode, state.$isRunning, preferences.$showCursorRing)
            .sink { [weak self] feedback, mode, running, enabled in
                self?.update(feedback: feedback, mode: mode, visible: running && enabled)
            }
            .store(in: &cancellables)
        state.clicks
            .sink { [weak self] in self?.flashClick() }
            .store(in: &cancellables)
    }

    private func update(feedback: GestureRecognizer.Feedback, mode: GestureRecognizer.Mode, visible: Bool) {
        let scrolling = mode == .scrollMode || mode == .scroll
        let (progress, color): (CGFloat, NSColor) = {
            if scrolling { return (1, Self.scrollColor) }
            if mode == .waiting { return (feedback.ready, .systemGreen) }
            if feedback.point > 0.02 { return (feedback.point, .systemIndigo) }
            if feedback.dwell > 0.02 { return (feedback.dwell, .systemOrange) }
            return (feedback.pinch, NSColor(calibratedRed: 0.36, green: 0.78, blue: 0.98, alpha: 1))
        }()
        let show = visible && (progress > 0.03 || mode == .drag || scrolling)
        guard show else {
            if window.isVisible { window.orderOut(nil) }
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.strokeColor = color.cgColor
        arc.strokeEnd = mode == .drag ? 1 : progress
        setArrow(scrolling ? feedback.scrollDirection : nil)
        CATransaction.commit()
        moveToCursor()
        if !window.isVisible { window.orderFrontRegardless() }
    }

    private static let scrollColor = NSColor.systemPurple

    /// A chevron pointing the way the page scrolls, a short bar at rest, or nothing outside scroll mode.
    private func setArrow(_ direction: Int?) {
        guard direction != arrowDirection else { return }
        arrowDirection = direction
        let c = Self.size / 2
        let path = CGMutablePath()
        switch direction {
        case .some(0):
            path.move(to: CGPoint(x: c - 6, y: c))
            path.addLine(to: CGPoint(x: c + 6, y: c))
        case .some(let d):
            // AppKit y grows upward, so scrolling down the page (1) points the tip down.
            let tip = CGFloat(-d) * 5
            path.move(to: CGPoint(x: c - 7, y: c - tip))
            path.addLine(to: CGPoint(x: c, y: c + tip))
            path.addLine(to: CGPoint(x: c + 7, y: c - tip))
        case .none:
            break
        }
        arrow.path = path
    }

    private func moveToCursor() {
        let mouse = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(x: mouse.x - Self.size / 2, y: mouse.y - Self.size / 2))
    }

    private func flashClick() {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.25
        flash.add(fade, forKey: "flash")
    }
}
