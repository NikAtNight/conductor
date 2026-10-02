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
                            preferences.appProfiles[editing] = nil
                            self.editing = nil
                        }
                    }
                }
                Caption(editing == nil
                    ? "These bindings apply everywhere, except in apps with their own profile."
                    : "These bindings apply while this app is in front. Everything else uses Everywhere.")
            }
            Section("Bindings") {
                ForEach(Trigger.allCases) { trigger in
                    GestureRow(trigger: trigger, action: binding(for: trigger))
                }
            }
            Section {
                Caption("Only one trigger is active at a time. Both hands beat a fist, a fist beats a pinch, and among pinches the fingertip closest to the thumb wins. Scroll and zoom on a one-handed trigger use up and down hand travel. For swipes, raise index and middle fingers with the others curled, then flick sideways; the cursor holds still in that pose.")
                HStack {
                    Spacer()
                    Button("Reset bindings") { setMap(.standard) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var sortedProfiles: [AppProfile] {
        preferences.appProfiles.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Regular apps that are running and don't have a profile yet.
    private var addableApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier && preferences.appProfiles[$0.bundleIdentifier!] == nil }
            .sorted { ($0.localizedName ?? "") .localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
    }

    private func add(_ app: NSRunningApplication) {
        guard let id = app.bundleIdentifier else { return }
        // Start from the current everywhere bindings, so only the differences need changing.
        preferences.appProfiles[id] = AppProfile(bundleID: id, name: app.localizedName ?? id, map: preferences.gestureMap)
        editing = id
    }

    private var currentMap: GestureMap {
        editing.flatMap { preferences.appProfiles[$0]?.map } ?? preferences.gestureMap
    }

    private func setMap(_ map: GestureMap) {
        if let editing, preferences.appProfiles[editing] != nil {
            preferences.appProfiles[editing]?.map = map
        } else {
            preferences.gestureMap = map
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
    @Binding var action: GestureAction

    private static let placeholder = GestureAction.shortcut(Shortcut(keyCode: 0, modifiers: 0))

    /// The picker works on kinds. A recorded shortcut still shows as the generic "Shortcut" choice,
    /// and choosing "Shortcut" over an existing one keeps the recorded key.
    private var kind: Binding<GestureAction> {
        Binding(
            get: { action.isShortcut ? Self.placeholder : action },
            set: { new in
                if new.isShortcut, action.isShortcut { return }
                action = new
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(trigger.title, selection: kind) {
                ForEach(GestureAction.menuChoices, id: \.self) { choice in
                    Text(choice.isShortcut ? "Keyboard shortcut" : choice.title).tag(choice)
                }
            }
            if case .shortcut(let shortcut) = action {
                HStack {
                    Spacer()
                    ShortcutRecorder(shortcut: Binding(
                        get: { shortcut },
                        set: { action = .shortcut($0) }
                    ))
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
            Text(shortcut.keyCode == 0 && shortcut.modifiers == 0 ? "Not set" : shortcut.display)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 80, alignment: .trailing)
                .foregroundStyle(recording ? .orange : .primary)
            Button(recording ? "Press keys…" : "Record") { recording ? stop() : start() }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Modifier-only presses arrive as flagsChanged, not keyDown, so anything here is a real key.
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

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
