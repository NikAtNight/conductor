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
    private var cues: Cues?
    private var cancellables: Set<AnyCancellable> = []

    private let toggleItem = NSMenuItem(title: "Start Tracking", action: #selector(toggleTracking), keyEquivalent: "t")
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        engine = Engine(state: state, preferences: preferences)
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "hand.raised", accessibilityDescription: "Conductor")
        statusItem.menu = buildMenu()
        statusItem.menu?.delegate = self

        cursorRing = CursorRing(state: state, preferences: preferences)
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
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let calibrate = NSMenuItem(title: "Calibrate Reach…", action: #selector(calibrate), keyEquivalent: "")
        calibrate.target = self
        menu.addItem(calibrate)
        let setup = NSMenuItem(title: "Setup Assistant…", action: #selector(showSetup), keyEquivalent: "")
        setup.target = self
        menu.addItem(setup)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Conductor", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        toggleItem.title = state.isRunning ? "Pause Tracking" : "Start Tracking"
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

    @objc private func showPreview() {
        if previewWindow == nil {
            let view = PreviewView(state: state, preferences: preferences, session: engine.camera.session)
            previewWindow = makeWindow(title: "Conductor Preview", content: view, size: NSSize(width: 640, height: 480))
        }
        present(previewWindow)
        if !state.isRunning { Task { await engine.start() } }
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(preferences: preferences, calibrate: { [weak self] in self?.calibrate() })
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
