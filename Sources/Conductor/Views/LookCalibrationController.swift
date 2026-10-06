import AppKit
import SwiftUI

/// Look calibration: covers every display, walks a dot around each one's corners and centre, and
/// collects the head angles seen along the way into one pass for the current sitting distance.
/// One run at a time; a second `start` while one is up is reported as cancelled.
@MainActor
final class LookCalibrationController {
    /// Where the dot goes on each display, as fractions of the screen, before the inset.
    static let targets: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1), CGPoint(x: 0.5, y: 0.5),
    ]
    static let inset: CGFloat = 36

    private let overlay = OverlayModel()
    private var windows: [NSWindow] = []
    private var engine: Engine?
    private var run: Task<Void, Never>?
    private var completion: ((Result<LookModel.Pass, LookCalibration.Failure>?) -> Void)?
    private var samples: [LookCalibration.Sample] = []
    /// The display whose sample period is open. Nil while the eyes travel to a new dot.
    private var sampling: String?

    var isRunning: Bool { completion != nil }

    /// nil means the user cancelled or the camera couldn't start.
    func start(displays: [DisplayInfo], engine: Engine,
               completion: @escaping (Result<LookModel.Pass, LookCalibration.Failure>?) -> Void) {
        // Mirrored or sleeping displays can be in the CG list without an NSScreen to draw on.
        let screens = Self.screensByUUID()
        let shown = displays.compactMap { display in screens[display.uuid].map { (display, $0) } }
        guard !isRunning, !shown.isEmpty else {
            completion(nil)
            return
        }
        self.completion = completion
        self.engine = engine
        samples = []
        sampling = nil
        run = Task { [weak self] in
            guard let self else { return }
            let started = await engine.startLookSampling { [weak self] face in self?.record(face) }
            guard started else {
                finish(nil)
                return
            }
            guard !Task.isCancelled else {
                engine.stopLookSampling() // cancelled while the camera was starting
                return
            }
            open(shown)
            do {
                try await walk(shown.map(\.0))
            } catch {
                return // cancelled; cancel() already reported
            }
            finish(LookCalibration.pass(from: samples, displays: shown.map(\.0.uuid)))
        }
    }

    func cancel() {
        guard isRunning else { return }
        run?.cancel()
        finish(nil)
    }

    private func walk(_ displays: [DisplayInfo]) async throws {
        let total = displays.count * Self.targets.count
        for (d, display) in displays.enumerated() {
            overlay.screenLine = "Screen \(d + 1) of \(displays.count): \(display.name)"
            for t in Self.targets.indices {
                overlay.displayIndex = d
                overlay.targetIndex = t
                overlay.progress = Double(d * Self.targets.count + t) / Double(total)
                sampling = nil
                try await Task.sleep(for: .seconds(LookCalibration.settle))
                sampling = display.uuid
                let spot = Self.targets[t]
                engine?.logNote("look calibration: sampling \(display.name) (\(display.uuid)) dot \(t + 1) at \(spot.x),\(spot.y)")
                try await Task.sleep(for: .seconds(LookCalibration.samplePeriod))
                engine?.logNote("look calibration: dot \(t + 1) done")
            }
        }
        sampling = nil
        overlay.progress = 1
    }

    private func record(_ face: FacePose?) {
        guard let sampling, let face, let sample = LookCalibration.sample(face, display: sampling) else { return }
        samples.append(sample)
    }

    private func finish(_ result: Result<LookModel.Pass, LookCalibration.Failure>?) {
        guard let completion else { return }
        self.completion = nil
        run = nil
        sampling = nil
        engine?.logNote("look calibration result: \(Self.describe(result))")
        engine?.stopLookSampling()
        engine = nil
        for window in windows { window.close() }
        windows = []
        overlay.displayIndex = nil
        completion(result)
    }

    /// The outcome as one log line: the fitted pass as JSON with its weakest separation, the
    /// failure, or "cancelled".
    private static func describe(_ result: Result<LookModel.Pass, LookCalibration.Failure>?) -> String {
        switch result {
        case .success(let pass)?:
            let json = (try? JSONEncoder().encode(pass)).map { String(decoding: $0, as: UTF8.self) } ?? "?"
            return "\(json) separation \(String(format: "%.2f", LookModel.weakestSeparation(pass)))"
        case .failure(let failure)?:
            return "failed: \(failure)"
        case nil:
            return "cancelled"
        }
    }

    private func open(_ shown: [(DisplayInfo, NSScreen)]) {
        windows = shown.enumerated().map { index, pair in
            let window = OverlayWindow(contentRect: pair.1.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isReleasedWhenClosed = false
            window.onCancel = { [weak self] in self?.cancel() }
            window.contentView = NSHostingView(rootView: LookOverlayView(
                model: overlay, displayIndex: index, onCancel: { [weak self] in self?.cancel() }))
            window.orderFrontRegardless()
            return window
        }
        windows.first?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func screensByUUID() -> [String: NSScreen] {
        Dictionary(NSScreen.screens.compactMap { screen -> (String, NSScreen)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (DisplayLayout.uuidString(for: number.uint32Value), screen)
        }, uniquingKeysWith: { first, _ in first })
    }
}

/// Borderless windows refuse key status by default, and the overlay needs it so Escape works.
private final class OverlayWindow: NSWindow {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// What every overlay window shows. One model, shared, so the dot is on exactly one screen.
@MainActor
private final class OverlayModel: ObservableObject {
    @Published var displayIndex: Int?
    @Published var targetIndex = 0
    @Published var screenLine = ""
    @Published var progress = 0.0
}

private struct LookOverlayView: View {
    @ObservedObject var model: OverlayModel
    let displayIndex: Int
    let onCancel: () -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Dim, not dark: the screens are often what lights the face, and the camera
                // needs to keep seeing it while the dot moves.
                Color.black.opacity(0.6)
                VStack(spacing: 12) {
                    Text("Look at the dot").font(.largeTitle.weight(.semibold))
                    Text(model.screenLine).font(.title3)
                    ProgressView(value: model.progress).frame(width: 260).tint(.white)
                    Button("Cancel", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                        .padding(.top, 8)
                }
                .foregroundStyle(.white)
                // Above centre so the last dot, in the middle, doesn't sit on the text.
                .position(x: geo.size.width / 2, y: geo.size.height * 0.3)
                if model.displayIndex == displayIndex {
                    Circle()
                        .stroke(Color.white, lineWidth: 3)
                        .frame(width: 44, height: 44)
                        .overlay(Circle().fill(Color.white).frame(width: 10, height: 10))
                        .position(Self.point(model.targetIndex, in: geo.size))
                        .accessibilityHidden(true)
                }
            }
        }
        .ignoresSafeArea()
    }

    private static func point(_ index: Int, in size: CGSize) -> CGPoint {
        let inset = LookCalibrationController.inset
        let fraction = LookCalibrationController.targets[index]
        return CGPoint(x: inset + fraction.x * (size.width - 2 * inset),
                       y: inset + fraction.y * (size.height - 2 * inset))
    }
}
