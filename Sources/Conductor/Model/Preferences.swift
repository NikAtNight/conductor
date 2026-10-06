import Foundation
import CoreGraphics
import Combine

/// User-tunable knobs, persisted in UserDefaults. The pipeline reads a snapshot each frame.
@MainActor
final class Preferences: ObservableObject {
    @Published var boxWidth: Double { didSet { save() } }
    @Published var boxHeight: Double { didSet { save() } }
    @Published var boxOffsetY: Double { didSet { save() } }
    @Published var mirrored: Bool { didSet { save() } }
    @Published var smoothing: Double { didSet { save() } }
    @Published var pinchEngage: Double { didSet { save() } }
    @Published var pinchRelease: Double { didSet { save() } }
    @Published var scrollGain: Double { didSet { save() } }
    @Published var zoomWithKeys: Bool { didSet { save() } }
    @Published var displayMode: DisplayMode { didSet { save() } }
    @Published var gestureMap: GestureMap { didSet { gestureMap.save(to: defaults) } }
    @Published var matchScreenShape: Bool { didSet { save() } }
    @Published var mainHand: GestureRecognizer.MainHand { didSet { save() } }
    @Published var requireReadyPose: Bool { didSet { save() } }
    @Published var dwellClick: Bool { didSet { save() } }
    @Published var dwellTime: Double { didSet { save() } }
    @Published var showCursorRing: Bool { didSet { save() } }
    @Published var showHandMap: Bool { didSet { save() } }
    /// Write every frame to a gesture log (see GestureLog).
    @Published var recordGestureLog: Bool { didSet { save() } }
    @Published var soundCues: Bool { didSet { save() } }
    @Published var pointerMode: PointerMode { didSet { save() } }
    @Published var trackpadSpeed: Double { didSet { save() } }
    /// How far slow moves carry the cursor in the absolute mode, as a fraction. 1 turns it off.
    @Published var slowMoveSpeed: Double { didSet { save() } }
    @Published var momentumScroll: Bool { didSet { save() } }
    /// Nil means automatic: see CameraCapture.preferredDevice.
    @Published var cameraDeviceID: String? { didSet { save() } }
    @Published var powerSaving: Bool { didSet { save() } }
    /// A box measured by calibration, in Vision space. Overrides the automatic layout when set.
    @Published var calibratedBox: CGRect? { didSet { save() } }
    @Published var pinchDeadZone: Double { didSet { save() } }
    @Published var dwellRadius: Double { didSet { save() } }
    /// Per-app gesture maps, keyed by bundle identifier.
    @Published var appProfiles: [String: AppProfile] { didSet { save() } }

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

    enum PointerMode: String, CaseIterable, Identifiable {
        /// The cursor sits wherever the hand is inside the control box.
        case absolute
        /// The cursor moves by how far the hand moves, like a trackpad.
        case relative
        var id: String { rawValue }
        var title: String { self == .absolute ? "To where your hand is" : "Like a trackpad" }
    }
    /// Nil means automatic: see CameraPlacement.resolve.
    @Published var cameraPlacement: CameraPlacement? { didSet { save() } }
    /// Head angles per display from look calibration. Nil until calibrated; `lookedAt` needs it.
    @Published var lookModel: LookModel? { didSet { save() } }

    enum DisplayMode: String, CaseIterable, Identifiable {
        /// The control box covers the union of every connected display.
        case all
        /// Each time the hand reappears, lock onto the display the cursor is on.
        case followCursor
        case main
        /// The whole box maps onto whichever display the head is turned toward (see LookPicker).
        case lookedAt

        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All displays"
            case .followCursor: return "Display under the cursor"
            case .main: return "Main display only"
            case .lookedAt: return "Display you're looking at"
            }
        }
    }

    struct Snapshot {
        var boxWidth: Double
        var boxHeight: Double
        var boxOffsetY: Double
        var mirrored: Bool
        var smoothing: Double
        var pinchEngage: Double
        var pinchRelease: Double
        var scrollGain: Double
        var zoomWithKeys: Bool
        var displayMode: DisplayMode
        var gestureMap: GestureMap
        var matchScreenShape: Bool
        var cameraPlacement: CameraPlacement?
        var pointerMode: PointerMode
        var trackpadSpeed: Double
        var slowMoveSpeed: Double
        var momentumScroll: Bool
        var cameraDeviceID: String?
        var powerSaving: Bool
        var calibratedBox: CGRect?
        var pinchDeadZone: Double
        var dwellRadius: Double
        var appProfiles: [String: AppProfile]
        var mainHand: GestureRecognizer.MainHand
        var requireReadyPose: Bool
        var dwellClick: Bool
        var dwellTime: Double
        var recordGestureLog: Bool
        var lookModel: LookModel?
    }

    var snapshot: Snapshot {
        Snapshot(boxWidth: boxWidth, boxHeight: boxHeight, boxOffsetY: boxOffsetY, mirrored: mirrored,
                 smoothing: smoothing, pinchEngage: pinchEngage, pinchRelease: pinchRelease,
                 scrollGain: scrollGain, zoomWithKeys: zoomWithKeys, displayMode: displayMode,
                 gestureMap: gestureMap, matchScreenShape: matchScreenShape, cameraPlacement: cameraPlacement,
                 pointerMode: pointerMode, trackpadSpeed: trackpadSpeed, slowMoveSpeed: slowMoveSpeed,
                 momentumScroll: momentumScroll,
                 cameraDeviceID: cameraDeviceID, powerSaving: powerSaving, calibratedBox: calibratedBox,
                 pinchDeadZone: pinchDeadZone, dwellRadius: dwellRadius, appProfiles: appProfiles,
                 mainHand: mainHand, requireReadyPose: requireReadyPose, dwellClick: dwellClick, dwellTime: dwellTime,
                 recordGestureLog: recordGestureLog, lookModel: lookModel)
    }

    private let defaults: UserDefaults
    /// Optional properties start as nil before init runs, so assigning them in init goes through
    /// the published setter and fires didSet. A save at that point would write half-loaded values
    /// over the stored ones (it dropped the look model once), so saving waits until init is done.
    private var loaded = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func d(_ key: String, _ fallback: Double) -> Double {
            defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key)
        }
        func b(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
        boxWidth = d("boxWidth", 0.6)
        boxHeight = d("boxHeight", 0.5)
        boxOffsetY = d("boxOffsetY", 0.05)
        mirrored = b("mirrored", true)
        smoothing = d("smoothing", 0.6)
        pinchEngage = d("pinchEngage", 0.35)
        pinchRelease = d("pinchRelease", 0.55)
        scrollGain = d("scrollGain", 1.0)
        zoomWithKeys = b("zoomWithKeys", false)
        displayMode = DisplayMode(rawValue: defaults.string(forKey: "displayMode") ?? "") ?? .all
        var map = GestureMap.load(from: defaults)
        // The ring pinch did nothing by default before Switch display existed, so saved maps have it
        // unbound. Bind it once; someone who unbinds it again keeps it unbound. Saved here because
        // nothing saves during init.
        if !defaults.bool(forKey: "switchDisplayDefault") {
            if map[.ringPinch] == .none {
                map[.ringPinch] = .switchDisplay
                map.save(to: defaults)
            }
            defaults.set(true, forKey: "switchDisplayDefault")
        }
        gestureMap = map
        matchScreenShape = b("matchScreenShape", true)
        mainHand = GestureRecognizer.MainHand(rawValue: defaults.string(forKey: "mainHand") ?? "") ?? .right
        requireReadyPose = b("requireReadyPose", true)
        dwellClick = b("dwellClick", false)
        dwellTime = d("dwellTime", 0.8)
        showCursorRing = b("showCursorRing", true)
        showHandMap = b("showHandMap", false)
        recordGestureLog = b("recordGestureLog", false)
        soundCues = b("soundCues", false)
        pointerMode = PointerMode(rawValue: defaults.string(forKey: "pointerMode") ?? "") ?? .absolute
        trackpadSpeed = d("trackpadSpeed", 1.0)
        slowMoveSpeed = d("slowMoveSpeed", 0.35)
        momentumScroll = b("momentumScroll", true)
        cameraDeviceID = defaults.string(forKey: "cameraDeviceID")
        powerSaving = b("powerSaving", true)
        // Boxes calibrated before the cursor followed the index knuckle were measured from the
        // fingertips, about a hand length higher. Drop them once; the automatic box stands in.
        if defaults.string(forKey: "calibrationPoint") != "indexKnuckle" {
            defaults.removeObject(forKey: "calibratedBox")
            defaults.set("indexKnuckle", forKey: "calibrationPoint")
        }
        if let v = defaults.array(forKey: "calibratedBox") as? [Double], v.count == 4 {
            calibratedBox = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
        } else {
            calibratedBox = nil
        }
        pinchDeadZone = d("pinchDeadZone", 0.012)
        dwellRadius = d("dwellRadius", 0.015)
        appProfiles = defaults.data(forKey: "appProfiles")
            .flatMap { try? JSONDecoder().decode([String: AppProfile].self, from: $0) } ?? [:]
        // Profiles saved before newer triggers existed get those triggers' defaults.
        for (id, var profile) in appProfiles {
            for trigger in Trigger.allCases where profile.map.bindings[trigger] == nil {
                profile.map.bindings[trigger] = GestureMap.standard[trigger]
            }
            appProfiles[id] = profile
        }
        cameraPlacement = defaults.data(forKey: "cameraPlacement")
            .flatMap { try? JSONDecoder().decode(CameraPlacement.self, from: $0) }
        // Models saved as angle ranges, before averages and spreads, don't decode and read as not
        // calibrated: ranges can't be turned back into the spreads the picker needs.
        lookModel = defaults.data(forKey: "lookModel")
            .flatMap { try? JSONDecoder().decode(LookModel.self, from: $0) }
        loaded = true
    }

    func resetToDefaults() {
        boxWidth = 0.6; boxHeight = 0.5; boxOffsetY = 0.05; mirrored = true
        smoothing = 0.6; pinchEngage = 0.35; pinchRelease = 0.55; scrollGain = 1.0; zoomWithKeys = false
        displayMode = .all
        gestureMap = .standard
        matchScreenShape = true
        cameraPlacement = nil
        lookModel = nil
        mainHand = .right
        requireReadyPose = true
        dwellClick = false
        dwellTime = 0.8
        showCursorRing = true
        showHandMap = false
        recordGestureLog = false
        soundCues = false
        pointerMode = .absolute
        trackpadSpeed = 1.0
        slowMoveSpeed = 0.35
        momentumScroll = true
        cameraDeviceID = nil
        powerSaving = true
        calibratedBox = nil
        pinchDeadZone = 0.012
        dwellRadius = 0.015
    }

    private func save() {
        guard loaded else { return }
        defaults.set(boxWidth, forKey: "boxWidth")
        defaults.set(boxHeight, forKey: "boxHeight")
        defaults.set(boxOffsetY, forKey: "boxOffsetY")
        defaults.set(mirrored, forKey: "mirrored")
        defaults.set(smoothing, forKey: "smoothing")
        defaults.set(pinchEngage, forKey: "pinchEngage")
        defaults.set(pinchRelease, forKey: "pinchRelease")
        defaults.set(scrollGain, forKey: "scrollGain")
        defaults.set(zoomWithKeys, forKey: "zoomWithKeys")
        defaults.set(displayMode.rawValue, forKey: "displayMode")
        defaults.set(matchScreenShape, forKey: "matchScreenShape")
        defaults.set(mainHand.rawValue, forKey: "mainHand")
        defaults.set(requireReadyPose, forKey: "requireReadyPose")
        defaults.set(dwellClick, forKey: "dwellClick")
        defaults.set(dwellTime, forKey: "dwellTime")
        defaults.set(showCursorRing, forKey: "showCursorRing")
        defaults.set(showHandMap, forKey: "showHandMap")
        defaults.set(recordGestureLog, forKey: "recordGestureLog")
        defaults.set(soundCues, forKey: "soundCues")
        defaults.set(pointerMode.rawValue, forKey: "pointerMode")
        defaults.set(trackpadSpeed, forKey: "trackpadSpeed")
        defaults.set(slowMoveSpeed, forKey: "slowMoveSpeed")
        defaults.set(momentumScroll, forKey: "momentumScroll")
        defaults.set(cameraDeviceID, forKey: "cameraDeviceID")
        defaults.set(powerSaving, forKey: "powerSaving")
        if let box = calibratedBox {
            defaults.set([box.minX, box.minY, box.width, box.height].map(Double.init), forKey: "calibratedBox")
        } else {
            defaults.removeObject(forKey: "calibratedBox")
        }
        defaults.set(pinchDeadZone, forKey: "pinchDeadZone")
        defaults.set(dwellRadius, forKey: "dwellRadius")
        if let data = try? JSONEncoder().encode(appProfiles) {
            defaults.set(data, forKey: "appProfiles")
        }
        if let cameraPlacement, let data = try? JSONEncoder().encode(cameraPlacement) {
            defaults.set(data, forKey: "cameraPlacement")
        } else {
            defaults.removeObject(forKey: "cameraPlacement")
        }
        if let lookModel, let data = try? JSONEncoder().encode(lookModel) {
            defaults.set(data, forKey: "lookModel")
        } else {
            defaults.removeObject(forKey: "lookModel")
        }
    }
}
