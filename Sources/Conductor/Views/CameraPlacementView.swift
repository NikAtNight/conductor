import SwiftUI
import AppKit

/// A small map of the display arrangement, like System Settings > Displays. Clicking a display sets
/// the camera there, at the clicked spot along its top edge.
struct CameraPlacementView: View {
    @ObservedObject var preferences: Preferences
    @State private var displays: [DisplayInfo] = DisplayLayout.current()
    private var resolved: (x: CGFloat, display: DisplayInfo)? {
        CameraPlacement.resolve(preferences.cameraPlacement, displays: displays,
                                builtInCamera: CameraCapture.isBuiltIn(id: preferences.cameraDeviceID))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisplayMap(displays: displays, camera: resolved) { display, x in
                preferences.cameraPlacement = CameraPlacement(displayUUID: display.uuid, x: x)
            }
            .frame(height: 150)
            HStack(alignment: .firstTextBaseline) {
                Text(summary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Automatic") { preferences.cameraPlacement = nil }
                    .disabled(preferences.cameraPlacement == nil)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays = DisplayLayout.current()
        }
    }

    private var summary: String {
        guard let resolved else { return "No displays found." }
        let prefix = preferences.cameraPlacement == nil ? "Automatic: camera" : "Camera"
        return "\(prefix) on \(resolved.display.name). Click a screen to move it."
    }
}

private struct DisplayMap: View {
    let displays: [DisplayInfo]
    let camera: (x: CGFloat, display: DisplayInfo)?
    let onPick: (DisplayInfo, Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let fit = Fit(displays: displays.map(\.bounds), size: geo.size)
            ZStack(alignment: .topLeading) {
                ForEach(displays, id: \.uuid) { display in
                    let rect = fit.rect(display.bounds)
                    let hasCamera = camera?.display.uuid == display.uuid
                    RoundedRectangle(cornerRadius: 4)
                        .fill(hasCamera ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.15))
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .stroke(hasCamera ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: 1))
                        .overlay(Text(display.name).font(.caption2).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).padding(4))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
                if let camera {
                    let rect = fit.rect(camera.display.bounds)
                    let x = fit.origin.x + (camera.x - fit.union.minX) * fit.scale
                    Image(systemName: "web.camera.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(Circle().fill(Color.accentColor))
                        .position(x: x, y: rect.minY)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                for display in displays {
                    let rect = fit.rect(display.bounds)
                    if rect.contains(location) {
                        onPick(display, Double((location.x - rect.minX) / rect.width))
                        return
                    }
                }
            }
        }
    }

    /// Scales the whole layout to fit the view, centered, with room for the camera badge.
    private struct Fit {
        let union: CGRect
        let scale: CGFloat
        let origin: CGPoint

        init(displays: [CGRect], size: CGSize) {
            let union = displays.dropFirst().reduce(displays.first ?? .zero) { $0.union($1) }
            let pad: CGFloat = 12
            let scale = union.width > 0 && union.height > 0
                ? min((size.width - 2 * pad) / union.width, (size.height - 2 * pad) / union.height) : 1
            self.union = union
            self.scale = scale
            origin = CGPoint(x: (size.width - union.width * scale) / 2, y: (size.height - union.height * scale) / 2)
        }

        func rect(_ bounds: CGRect) -> CGRect {
            CGRect(x: origin.x + (bounds.minX - union.minX) * scale,
                   y: origin.y + (bounds.minY - union.minY) * scale,
                   width: bounds.width * scale, height: bounds.height * scale)
        }
    }
}
