import AppKit

/// Plain AppKit startup. An earlier SwiftUI `App` needed a placeholder `Settings { EmptyView() }`
/// scene, and macOS would open that as a blank "Conductor Settings" window on ⌘, or from its own
/// Settings command. Running NSApplication directly means the only windows are the ones we make.
@main
enum ConductorMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = ConductorDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        _ = delegate // keep the delegate alive for the life of the run loop
    }
}

@MainActor
final class ConductorDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menuBar = MenuBarController()
        self.menuBar = menuBar
        NSApp.mainMenu = Self.mainMenu(settingsTarget: menuBar)
    }

    /// Every quit path (⌘Q, the menu, logout) lands here; nothing may stay pressed after we exit.
    func applicationWillTerminate(_ notification: Notification) {
        menuBar?.shutdown()
    }

    /// An accessory app never shows a menu bar, but key equivalents in the main menu still work
    /// while one of its windows is key: ⌘W to close, ⌘Q to quit, and the standard edit commands.
    private static func mainMenu(settingsTarget: MenuBarController) -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(MenuBarController.showSettings), keyEquivalent: ",")
        settings.target = settingsTarget
        appMenu.addItem(settings)
        appMenu.addItem(withTitle: "Quit Conductor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)
        return main
    }
}
