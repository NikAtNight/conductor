import SwiftUI
import AppKit

/// One row per trigger: what it does, and a key recorder when it's a shortcut. A profile picker on
/// top switches between the everywhere bindings and per-app ones.
struct GestureSettingsView: View {
    @ObservedObject var preferences: Preferences
    /// Bundle ID of the profile being edited, or nil for "Everywhere".
    @State private var editing: String?

    var body: some View {
        Form {
            Section("Profile") {
                HStack {
                    Picker("Editing", selection: $editing) {
                        Text("Everywhere").tag(String?.none)
                        ForEach(sortedProfiles) { profile in
                            Text(profile.name).tag(Optional(profile.bundleID))
                        }
                    }
                    Menu("Add app") {
                        ForEach(addableApps, id: \.bundleIdentifier) { app in
                            Button(app.localizedName ?? app.bundleIdentifier ?? "App") { add(app) }
                        }
                    }
                    .fixedSize()
                    if let editing {
                        Button("Remove") {
                            preferences.settings.appProfiles[editing] = nil
                            self.editing = nil
                        }
                    }
                }
                Caption(editing == nil
                    ? "These bindings apply everywhere, except in apps with their own profile."
                    : "These bindings apply while this app is in front. Everything else uses Everywhere. Pause / resume and scroll mode are shared by every profile, so set them under Everywhere.")
            }
            Section("Bindings") {
                Picker("Main hand", selection: $preferences.settings.mainHand) {
                    ForEach(GestureRecognizer.MainHand.allCases) { Text($0.title).tag($0) }
                }
                Caption("The pictures show this hand, as you see it in the preview. It's also the hand that moves the cursor when both are in view; the other one joins in for two-hand gestures. Any hand can make the gestures.")
                ForEach(Trigger.allCases) { trigger in
                    GestureRow(trigger: trigger, hand: preferences.settings.mainHand, action: binding(for: trigger))
                }
            }
            Section("Push to talk") {
                HStack {
                    Text("Thumb + ring pinch talks to Walkie")
                    Spacer()
                    Button("Set up") {
                        var map = currentMap
                        map[.ringPinch] = .holdKey(Shortcut(keyCode: 54, modifiers: 0))
                        setMap(map)
                    }
                }
                Caption("Holds Right ⌘, Walkie's dictation key, for as long as you pinch. Any push-to-talk app works the same way: pick Hold a key for a gesture and record that app's key. Pressing a modifier on its own records just that key.")
            }
            Section("Scroll mode") {
                HStack {
                    Text("Cross index and middle fingers to switch scroll mode on and off")
                    Spacer()
                    Button("Set up") { preferences.settings.gestureMap[.crossedFingers] = .scrollMode }
                }
                Caption("For scrolling with a relaxed, open hand instead of a fist. Cross your fingers for a moment, uncross them, and rest your hand where it's comfortable: that spot becomes neutral. Knuckles above neutral scroll down the page, below it scroll up, and the farther from neutral, the faster. Tipping your fingers toward the screen lowers the knuckles, so rest with your hand tipped forward a little and you can scroll both ways by rocking at the wrist. Clicks, other gestures, and pause are off until you cross your fingers again, or hold a fist for a moment, which also leaves scroll mode. The cursor ring turns purple and shows an arrow while scroll mode is on.")
            }
            Section {
                Caption("Only one trigger is active at a time. Both hands beat a fist, a fist beats a pinch, and among pinches the fingertip closest to the thumb wins. Scroll on a one-handed trigger works as a lever: hold your hand above or below where it was when the trigger engaged (Settings > Tracking > Scroll by changes this). Zoom uses up and down hand travel. With index and middle fingers raised and the others curled, the cursor holds still: that pose's binding runs (scroll by default), and a quick sideways flick swipes. Point with your index finger, thumb out and the other fingers curled, to switch display: up, down, left or right picks the screen that way.")
                HStack {
                    Spacer()
                    Button("Reset bindings") { setMap(.standard) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var sortedProfiles: [AppProfile] {
        preferences.settings.appProfiles.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Regular apps that are running and don't have a profile yet.
    private var addableApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier && preferences.settings.appProfiles[$0.bundleIdentifier!] == nil }
            .sorted { ($0.localizedName ?? "") .localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
    }

    private func add(_ app: NSRunningApplication) {
        guard let id = app.bundleIdentifier else { return }
        // Start from the current everywhere bindings, so only the differences need changing.
        preferences.settings.appProfiles[id] = AppProfile(bundleID: id, name: app.localizedName ?? id, map: preferences.settings.gestureMap)
        editing = id
    }

    private var currentMap: GestureMap {
        editing.flatMap { preferences.settings.appProfiles[$0]?.map } ?? preferences.settings.gestureMap
    }

    private func setMap(_ map: GestureMap) {
        if let editing, preferences.settings.appProfiles[editing] != nil {
            preferences.settings.appProfiles[editing]?.map = map
        } else {
            preferences.settings.gestureMap = map
        }
    }

    private func binding(for trigger: Trigger) -> Binding<GestureAction> {
        Binding(
            get: { currentMap[trigger] },
            set: { newValue in
                var map = currentMap
                map[trigger] = newValue
                setMap(map)
            }
        )
    }
}

private struct GestureRow: View {
    let trigger: Trigger
    let hand: GestureRecognizer.MainHand
    @Binding var action: GestureAction

    /// The picker works on kinds. A recorded key shows as its generic choice; switching between
    /// "Keyboard shortcut" and "Hold a key" keeps the recorded key.
    private var kind: Binding<GestureAction> {
        Binding(
            get: { action.kind },
            set: { new in
                guard new != action.kind else { return }
                if let key = action.recordedKey {
                    switch new {
                    case .shortcut: action = .shortcut(key); return
                    case .holdKey: action = .holdKey(key); return
                    default: break
                    }
                }
                action = new
            }
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            HandSignView(trigger: trigger, hand: hand)
                .frame(width: 56, height: 56)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 6) {
                Picker(trigger.title, selection: kind) {
                    ForEach(GestureAction.menuChoices, id: \.self) { choice in
                        Text(choice.kindTitle).tag(choice)
                    }
                }
                if let key = action.recordedKey {
                    HStack {
                        Spacer()
                        ShortcutRecorder(shortcut: Binding(
                            get: { key },
                            set: { newKey in
                                if case .holdKey = action { action = .holdKey(newKey) } else { action = .shortcut(newKey) }
                            }
                        ))
                    }
                }
            }
        }
    }
}

/// Shows the current combo and records a new one from the next key press.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Text(shortcut == GestureAction.unsetKey ? "Not set" : shortcut.display)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 80, alignment: .trailing)
                .foregroundStyle(recording ? .orange : .primary)
            Button(recording ? "Press keys…" : "Record") { recording ? stop() : start() }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        // A modifier pressed and released on its own (say Right ⌘) records as that key alone, for
        // push-to-talk. Any regular key press records as key plus held modifiers.
        var lonelyModifier: UInt16?
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged {
                guard let modifier = InputController.modifier(for: event.keyCode) else { return nil }
                let isDown = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    .contains(Self.appKitFlag(for: modifier.flag))
                if isDown {
                    lonelyModifier = event.keyCode
                } else if lonelyModifier == event.keyCode {
                    shortcut = Shortcut(keyCode: event.keyCode, modifiers: 0)
                    stop()
                }
                return nil
            }
            lonelyModifier = nil
            let mask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
            let flags = event.modifierFlags.intersection(mask)
            var cg: CGEventFlags = []
            if flags.contains(.command) { cg.insert(.maskCommand) }
            if flags.contains(.option) { cg.insert(.maskAlternate) }
            if flags.contains(.control) { cg.insert(.maskControl) }
            if flags.contains(.shift) { cg.insert(.maskShift) }
            shortcut = Shortcut(keyCode: event.keyCode, modifiers: cg.rawValue)
            stop()
            return nil
        }
    }

    private static func appKitFlag(for flag: CGEventFlags) -> NSEvent.ModifierFlags {
        switch flag {
        case .maskCommand: return .command
        case .maskShift: return .shift
        case .maskAlternate: return .option
        case .maskControl: return .control
        default: return .function
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
