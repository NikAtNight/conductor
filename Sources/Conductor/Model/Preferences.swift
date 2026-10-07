import Foundation
import CoreGraphics
import Combine

/// Stores Settings in UserDefaults as one JSON blob and publishes it. The pipeline reads a copy.
@MainActor
final class Preferences: ObservableObject {
    typealias DisplayMode = Settings.DisplayMode
    typealias PointerMode = Settings.PointerMode
    typealias ScrollStyle = Settings.ScrollStyle

    @Published var settings: Settings { didSet { save() } }

    /// The UserDefaults key the settings blob lives under.
    static let key = "settings"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.data(forKey: Self.key)
        settings = (stored.map { Settings(stored: $0) ?? Settings() } ?? Self.legacySettings(from: defaults)).normalized()
        // Saved here because didSet doesn't run in init: a migration or repair on load must stick.
        save()
    }

    /// Back to the defaults. Per-app profiles are kept.
    func resetToDefaults() {
        var fresh = Settings()
        fresh.appProfiles = settings.appProfiles
        settings = fresh
    }

    /// The bindings to use while `bundleID` is the frontmost app. Pause / resume and scroll mode are
    /// global: they always come from the everywhere bindings, so switching apps can never strand or
    /// silently end either.
    nonisolated static func effectiveMap(base: GestureMap, profiles: [String: AppProfile], frontmost bundleID: String?) -> GestureMap {
        guard var map = bundleID.flatMap({ profiles[$0]?.map }) else { return base }
        let global: [GestureAction] = [.pauseTracking, .scrollMode]
        for trigger in Trigger.allCases {
            if global.contains(base[trigger]) {
                map[trigger] = base[trigger]
            } else if global.contains(map[trigger]) {
                map[trigger] = .none
            }
        }
        return map
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.key)
        }
    }

    /// Reads the one-key-per-setting storage that builds before the settings blob used. Only runs
    /// when there's no blob yet; the result is saved as the blob straight away. The old keys stay,
    /// so an older build still finds them.
    private static func legacySettings(from defaults: UserDefaults) -> Settings {
        var s = Settings()
        func double(_ key: String, _ value: inout Double) {
            if defaults.object(forKey: key) != nil { value = defaults.double(forKey: key) }
        }
        func bool(_ key: String, _ value: inout Bool) {
            if defaults.object(forKey: key) != nil { value = defaults.bool(forKey: key) }
        }
        func choice<T: RawRepresentable>(_ key: String, _ value: inout T) where T.RawValue == String {
            if let stored = defaults.string(forKey: key).flatMap(T.init(rawValue:)) { value = stored }
        }
        func json<T: Decodable>(_ key: String, _ type: T.Type) -> T? {
            defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
        }
        double("boxWidth", &s.boxWidth)
        double("boxHeight", &s.boxHeight)
        double("boxOffsetY", &s.boxOffsetY)
        bool("mirrored", &s.mirrored)
        double("smoothing", &s.smoothing)
        var engage = s.pinchEngage, release = s.pinchRelease
        double("pinchEngage", &engage)
        double("pinchRelease", &release)
        s.setPinchRelease(release)
        s.setPinchEngage(engage)
        double("scrollGain", &s.scrollGain)
        bool("zoomWithKeys", &s.zoomWithKeys)
        choice("displayMode", &s.displayMode)
        s.gestureMap = json("gestureMap", GestureMap.self) ?? .standard
        bool("matchScreenShape", &s.matchScreenShape)
        choice("mainHand", &s.mainHand)
        bool("requireReadyPose", &s.requireReadyPose)
        bool("dwellClick", &s.dwellClick)
        double("dwellTime", &s.dwellTime)
        bool("showCursorRing", &s.showCursorRing)
        bool("showHandMap", &s.showHandMap)
        bool("recordGestureLog", &s.recordGestureLog)
        bool("soundCues", &s.soundCues)
        choice("pointerMode", &s.pointerMode)
        double("trackpadSpeed", &s.trackpadSpeed)
        double("slowMoveSpeed", &s.slowMoveSpeed)
        bool("momentumScroll", &s.momentumScroll)
        choice("scrollStyle", &s.scrollStyle)
        s.cameraDeviceID = defaults.string(forKey: "cameraDeviceID")
        bool("powerSaving", &s.powerSaving)
        // Boxes calibrated before the cursor followed the index knuckle were measured from the
        // fingertips, about a hand length higher. They're dropped; the automatic box stands in.
        if defaults.string(forKey: "calibrationPoint") == "indexKnuckle",
           let v = defaults.array(forKey: "calibratedBox") as? [Double], v.count == 4 {
            s.calibratedBox = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
        }
        double("pinchDeadZone", &s.pinchDeadZone)
        double("dwellRadius", &s.dwellRadius)
        s.appProfiles = json("appProfiles", [String: AppProfile].self) ?? [:]
        s.cameraPlacement = json("cameraPlacement", CameraPlacement.self)
        // Models saved as angle ranges, before averages and spreads, don't decode and read as not
        // calibrated: ranges can't be turned back into the spreads the picker needs.
        s.lookModel = json("lookModel", LookModel.self)
        return s
    }
}
