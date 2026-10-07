import AppKit
import SwiftUI
import Combine

/// Owns the status item. Everything the user can do starts here.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let state = TrackingState()
    private let preferences = Preferences()
    private let engine: Engine
    private var previewWindow: NSWindow?
    private var settingsWindow: SettingsWindowController?
    private var setupWindow: NSWindow?
    private var hotKey: HotKey?
    private var cursorRing: CursorRing?
    private var handMap: HandMap?
    private var cues: Cues?
    private let lookCalibration = LookCalibrationController()
    private let gestureCheck = GestureCheckController()
    private var cancellables: Set<AnyCancellable> = []

    private let toggleItem = NSMenuItem(title: "Start Tracking", action: #selector(toggleTracking), keyEquivalent: "t")
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let handMapItem = NSMenuItem(title: "Show Hand Map", action: #selector(toggleHandMap), keyEquivalent: "")
    private let gestureLogItem = NSMenuItem(title: "Record Gesture Log", action: #selector(toggleGestureLog), keyEquivalent: "")

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        engine = Engine(state: state, preferences: preferences)
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "hand.raised", accessibilityDescription: "Conductor")
        statusItem.menu = buildMenu()
        statusItem.menu?.delegate = self

        cursorRing = CursorRing(state: state, preferences: preferences)
        handMap = HandMap(state: state, preferences: preferences)
        cues = Cues(state: state, preferences: preferences)
        hotKey = HotKey { [weak self] in
            Task { @MainActor in self?.toggleTracking() }
        }
        // Push every preference edit to the camera queue, debounced so slider drags don't flood it.
        preferences.objectWillChange
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.engine.refreshFromMainActor() }
            .store(in: &cancellables)
        // Screen size can change (display plugged in, resolution switch) while we run.
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.engine.refreshFromMainActor() }
            .store(in: &cancellables)
        state.$isRunning
            .sink { [weak self] running in self?.updateIcon(running: running) }
            .store(in: &cancellables)

        // Per-app profiles follow the frontmost app.
        engine.frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap { ($0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier }
            .sink { [weak self] bundleID in
                guard let self, bundleID != Bundle.main.bundleIdentifier else { return }
                self.engine.frontmostBundleID = bundleID
                self.engine.refreshFromMainActor()
            }
            .store(in: &cancellables)

        if !UserDefaults.standard.bool(forKey: "setupComplete") {
            DispatchQueue.main.async { [weak self] in self?.showSetup() }
        }
    }

    @objc func showSetup() {
        if setupWindow == nil {
            let view = SetupAssistantView(
                preferences: preferences, state: state,
                calibrate: { [weak self] in self?.calibrate() },
                calibrateLook: { [weak self] in self?.calibrateLook() },
                done: { [weak self] in
                    UserDefaults.standard.set(true, forKey: "setupComplete")
                    self?.setupWindow?.close()
                })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Conductor Setup"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            setupWindow = window
        }
        present(setupWindow)
    }

    /// Opens the preview so you can see yourself, then records your reach.
    @objc func calibrate() {
        showPreview()
        let preferences = self.preferences
        let engine = self.engine
        Task {
            await engine.calibrate { box in
                if let box { preferences.calibratedBox = box }
            }
        }
    }

    /// Walks a dot around every display and saves the head angles seen for each as one pass at the
    /// current sitting distance, then switches to the "Display you're looking at" mode so the
    /// result is used right away. After the first pass, a hint says to repeat it from other seats.
    @objc func calibrateLook() {
        let displays = DisplayLayout.current()
        let preferences = self.preferences
        lookCalibration.start(displays: displays, engine: engine) { [weak self] result in
            switch result {
            case .success(let pass)?:
                let model = (preferences.lookModel ?? LookModel(passes: [])).adding(pass)
                preferences.lookModel = model
                preferences.displayMode = .lookedAt
                let alert = NSAlert()
                let switchHint = Self.switchHint(preferences.gestureMap)
                switch LookCalibration.quality(of: pass) {
                case .clear:
                    alert.messageText = "Saved for this distance"
                    alert.informativeText = "Your head tells the screens apart clearly from here."
                case .weak:
                    alert.messageText = "Saved, but it's a close call from here"
                    alert.informativeText = "Your head moves only a little between screens from this distance, so near the edge between them Conductor may pick the wrong one. \(switchHint)"
                }
                // The setup assistant's own text already says to repeat it from other seats.
                if model.passes.count == 1, self?.setupWindow?.isVisible != true {
                    alert.informativeText += "\n\nIf you also work sitting further back, run Calibrate Look again from there. Conductor keeps one pass per distance."
                }
                alert.runModal()
            case .failure(let failure)?:
                let alert = NSAlert()
                alert.messageText = "Look calibration didn't work"
                alert.informativeText = Self.message(for: failure, displays: displays)
                if case .indistinct = failure { alert.informativeText += " \(Self.switchHint(preferences.gestureMap))" }
                alert.runModal()
            case nil:
                break
            }
        }
    }

    /// Opens the preview so you can see yourself, then walks every gesture for each hand and
    /// reports how cleanly the current thresholds read them. The report is saved beside the
    /// gesture logs; nothing is changed by it.
    @objc func checkGestures() {
        showPreview()
        var config = GestureRecognizer.Config()
        config.pinchEngage = preferences.pinchEngage
        config.pinchRelease = preferences.pinchRelease
        gestureCheck.start(engine: engine, config: config) { report in
            guard let report else { return }
            do {
                _ = try GestureCheck.save(report)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't save the gesture check"
                alert.informativeText = "\(error)"
                alert.runModal()
            }
        }
    }

    /// How to switch screens by hand with the user's current bindings.
    private static func switchHint(_ map: GestureMap) -> String {
        guard let trigger = Trigger.allCases.first(where: { map[$0] == .switchDisplay }) else {
            return "To switch by hand, bind Switch display to a gesture in Settings > Gestures."
        }
        return "\(trigger.title) switches screens by hand."
    }

    private static func message(for failure: LookCalibration.Failure, displays: [DisplayInfo]) -> String {
        func name(_ uuid: String) -> String { displays.first { $0.uuid == uuid }?.name ?? "a display" }
        switch failure {
        case .tooFewSamples(let uuid):
            return "Couldn't see your face while the dot was on \(name(uuid)). Make sure the camera can see you and try again."
        case .indistinct(let a, let b):
            return "Your head barely moved between \(name(a)) and \(name(b)), so Conductor can't tell them apart. Sit a little closer or move your head more, then try again."
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(withTitle: "Hotkey: ⌃⌥⌘H", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        let preview = NSMenuItem(title: "Show Preview", action: #selector(showPreview), keyEquivalent: "p")
        preview.target = self
        menu.addItem(preview)
        handMapItem.target = self
        menu.addItem(handMapItem)
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let calibrate = NSMenuItem(title: "Calibrate Reach…", action: #selector(calibrate), keyEquivalent: "")
        calibrate.target = self
        menu.addItem(calibrate)
        let calibrateLook = NSMenuItem(title: "Calibrate Look…", action: #selector(calibrateLook), keyEquivalent: "")
        calibrateLook.target = self
        menu.addItem(calibrateLook)
        let checkGestures = NSMenuItem(title: "Check Gestures…", action: #selector(checkGestures), keyEquivalent: "")
        checkGestures.target = self
        menu.addItem(checkGestures)
        let setup = NSMenuItem(title: "Setup Assistant…", action: #selector(showSetup), keyEquivalent: "")
        setup.target = self
        menu.addItem(setup)
        menu.addItem(.separator())
        gestureLogItem.target = self
        menu.addItem(gestureLogItem)
        let logs = NSMenuItem(title: "Show Gesture Logs", action: #selector(showGestureLogs), keyEquivalent: "")
        logs.target = self
        menu.addItem(logs)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Conductor", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        toggleItem.title = state.isRunning ? "Pause Tracking" : "Start Tracking"
        handMapItem.state = preferences.showHandMap ? .on : .off
        gestureLogItem.state = preferences.recordGestureLog ? .on : .off
        if !state.isRunning {
            statusLine.title = "Tracking is off"
        } else if let problem = state.error ?? state.warning {
            statusLine.title = problem
        } else {
            statusLine.title = state.gestureLabel
        }
    }

    private func updateIcon(running: Bool) {
        statusItem.button?.image = NSImage(
            systemSymbolName: running ? "hand.raised.fill" : "hand.raised",
            accessibilityDescription: "Conductor")
    }

    @objc private func toggleTracking() {
        if state.isRunning {
            engine.stop()
        } else {
            Task { await engine.start() }
        }
    }

    @objc private func toggleHandMap() {
        preferences.showHandMap.toggle()
    }

    @objc private func toggleGestureLog() {
        preferences.recordGestureLog.toggle()
    }

    @objc private func showGestureLogs() {
        try? FileManager.default.createDirectory(at: GestureLog.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(GestureLog.directory)
    }

    @objc private func showPreview() {
        if previewWindow == nil {
            let view = PreviewView(state: state, preferences: preferences, session: engine.camera.session)
            previewWindow = makeWindow(title: "Conductor Preview", content: view, size: NSSize(width: 900, height: 480))
        }
        present(previewWindow)
        if !state.isRunning { Task { await engine.start() } }
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(
                preferences: preferences,
                calibrate: { [weak self] in self?.calibrate() },
                calibrateLook: { [weak self] in self?.calibrateLook() })
        }
        present(settingsWindow?.window)
    }

    private func makeWindow<V: View>(title: String, content: V, size: NSSize) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(size)
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil) // applicationWillTerminate releases held input
    }

    func shutdown() {
        engine.shutdown()
    }
}
