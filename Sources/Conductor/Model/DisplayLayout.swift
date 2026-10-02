import AppKit

/// One connected display. `bounds` is in CGEvent global coordinates: origin at the top-left of the
/// main display, y down. Other displays can sit at negative coordinates (left of or above main).
struct DisplayInfo: Equatable {
    var uuid: String
    var name: String
    var bounds: CGRect
    var isBuiltin: Bool
    var isMain: Bool
}

enum DisplayLayout {
    /// The active displays with their names. NSScreen must be read on the main thread.
    @MainActor
    static func current() -> [DisplayInfo] {
        let names = Dictionary(NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, String)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (number.uint32Value, screen.localizedName)
        }, uniquingKeysWith: { first, _ in first })

        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        if count == 0 { ids = [CGMainDisplayID()]; count = 1 }

        return ids.prefix(Int(count)).map { id in
            DisplayInfo(
                uuid: uuidString(for: id),
                name: names[id] ?? "Display \(id)",
                bounds: CGDisplayBounds(id),
                isBuiltin: CGDisplayIsBuiltin(id) != 0,
                isMain: CGDisplayIsMain(id) != 0)
        }
    }

    /// Display IDs can change across reboots and replugs; the UUID is stable, so placements key on it.
    private static func uuidString(for id: CGDirectDisplayID) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
              let string = CFUUIDCreateString(nil, uuid) else { return "id-\(id)" }
        return string as String
    }

    /// Keeps a point on real screen area. With screens of different sizes, the bounding box of the
    /// layout has corners that belong to no display; a mapped point landing there moves to the
    /// nearest edge of the nearest display instead.
    static func snap(_ point: CGPoint, to displays: [CGRect]) -> CGPoint {
        var best = point
        var bestDistance = CGFloat.infinity
        for rect in displays where rect.width > 0 && rect.height > 0 {
            let inside = CGPoint(x: point.x.clamped(to: rect.minX...(rect.maxX - 1)),
                                 y: point.y.clamped(to: rect.minY...(rect.maxY - 1)))
            let distance = inside.distance(to: point)
            if distance < bestDistance {
                best = inside
                bestDistance = distance
            }
        }
        return best
    }
}

/// Where the webcam physically sits: which display it's mounted on, and how far along that
/// display's width, 0 = left edge, 1 = right edge.
struct CameraPlacement: Codable, Equatable {
    var displayUUID: String
    var x: Double

    /// The camera's position in global coordinates and the display it belongs to. Without a saved
    /// placement, or if that display is gone, assume a built-in camera sits top-center on the
    /// built-in display and any other camera sits top-center on the main display.
    static func resolve(_ placement: CameraPlacement?, displays: [DisplayInfo], builtInCamera: Bool)
        -> (x: CGFloat, display: DisplayInfo)? {
        if let placement, let display = displays.first(where: { $0.uuid == placement.displayUUID }) {
            return (display.bounds.minX + CGFloat(placement.x) * display.bounds.width, display)
        }
        let fallback = (builtInCamera ? displays.first(where: \.isBuiltin) : nil)
            ?? displays.first(where: \.isMain) ?? displays.first
        guard let fallback else { return nil }
        return (fallback.bounds.midX, fallback)
    }
}
