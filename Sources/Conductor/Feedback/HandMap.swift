import AppKit
import Combine
import SwiftUI

/// A small always-on-top picture of the camera's view: the control box and a dot for the hand
/// driving the cursor, red when it's outside the box. For finding the box without opening the
/// preview. Shown while tracking runs and the menu bar toggle is on. It ignores the mouse.
@MainActor
final class HandMap {
    private let panel: NSPanel
    private var cancellables: Set<AnyCancellable> = []

    private static let size = NSSize(width: 200, height: 150) // the 4:3 camera frame
    private static let margin: CGFloat = 16

    init(state: TrackingState, preferences: Preferences) {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: HandMapView(state: state, preferences: preferences))

        state.$isRunning
            .combineLatest(preferences.$showHandMap)
            .sink { [weak self] running, enabled in self?.setVisible(running && enabled) }
            .store(in: &cancellables)
    }

    private func setVisible(_ visible: Bool) {
        guard visible else {
            panel.orderOut(nil)
            return
        }
        // Bottom-right of the menu bar screen, clear of the Dock.
        if let screen = NSScreen.screens.first?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - Self.size.width - Self.margin, y: screen.minY + Self.margin))
        }
        panel.orderFrontRegardless()
    }
}

private struct HandMapView: View {
    @ObservedObject var state: TrackingState
    @ObservedObject var preferences: Preferences

    var body: some View {
        let hand = GestureRecognizer.primaryHand(state.hands, prefer: preferences.mainHand)
        let mirrored = preferences.mirrored
        let box = state.controlBox
        Canvas { context, size in
            // Everything is drawn in view space: mirrored like the preview, origin top-left.
            func place(_ p: CGPoint) -> CGPoint {
                CGPoint(x: (mirrored ? 1 - p.x : p.x) * size.width, y: (1 - p.y) * size.height)
            }
            let boxRect = CGRect(x: box.minX * size.width, y: box.minY * size.height,
                                 width: box.width * size.width, height: box.height * size.height)
            context.stroke(Path(boxRect), with: .color(.green.opacity(0.8)), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            guard let hand, let pointer = hand.pointer else { return }
            var bones = Path()
            for (a, b) in HandJoint.bones {
                guard let pa = hand[a], let pb = hand[b] else { continue }
                bones.move(to: place(pa))
                bones.addLine(to: place(pb))
            }
            context.stroke(bones, with: .color(.white.opacity(0.45)), lineWidth: 1)
            let dot = place(pointer)
            let inside = boxRect.contains(dot)
            context.fill(Path(ellipseIn: CGRect(x: dot.x - 6, y: dot.y - 6, width: 12, height: 12)),
                         with: .color(inside ? .green : .red))
        }
        .overlay {
            if hand == nil {
                Text("No hand in view").font(.caption).foregroundStyle(.white.opacity(0.7))
            }
        }
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityHidden(true)
    }
}
