import AppKit
import SwiftUI

/// Owns the status item. Everything the user can do starts here.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let state = TrackingState()
    private let engine: Engine
    private var previewWindow: NSWindow?

    private let toggleItem = NSMenuItem(title: "Start Tracking", action: #selector(toggleTracking), keyEquivalent: "t")

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        engine = Engine(state: state)
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "hand.raised", accessibilityDescription: "Conductor")
        statusItem.menu = buildMenu()
        statusItem.menu?.delegate = self
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        toggleItem.target = self
        menu.addItem(toggleItem)
        let preview = NSMenuItem(title: "Show Preview", action: #selector(showPreview), keyEquivalent: "p")
        preview.target = self
        menu.addItem(preview)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Conductor", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        toggleItem.title = state.isRunning ? "Pause Tracking" : "Start Tracking"
        statusItem.button?.image = NSImage(
            systemSymbolName: state.isRunning ? "hand.raised.fill" : "hand.raised",
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
            let view = PreviewView(state: state, session: engine.camera.session)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Conductor Preview"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 640, height: 480))
            window.center()
            previewWindow = window
        }
        previewWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !state.isRunning { Task { await engine.start() } }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
