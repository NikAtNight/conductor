import SwiftUI

struct ConductorApp: App {
    @NSApplicationDelegateAdaptor(ConductorDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class ConductorDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menuBar = MenuBarController()
    }
}

@main
enum ConductorMain {
    static func main() {
        ConductorApp.main()
    }
}
