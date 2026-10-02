import AppKit

/// Owns the status item. Everything the user can do starts here.
@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "hand.raised", accessibilityDescription: "Conductor")
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Conductor", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Conductor", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
