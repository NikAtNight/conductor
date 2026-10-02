import AppKit
import SwiftUI

/// Native preferences window: toolbar tabs at the top (the System Settings look), one SwiftUI form
/// per tab. Each tab has a fixed size, and NSTabViewController resizes the window when you switch.
@MainActor
final class SettingsWindowController: NSWindowController {
    static let width: CGFloat = 540

    init(preferences: Preferences, calibrate: @escaping () -> Void) {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar

        let all: [(String, String, AnyView, CGFloat)] = [
            ("Tracking", "hand.raised", AnyView(TrackingSettingsView(preferences: preferences, calibrate: calibrate)), 680),
            ("Displays", "display.2", AnyView(DisplaySettingsView(preferences: preferences)), 470),
            ("Gestures", "hand.tap", AnyView(GestureSettingsView(preferences: preferences)), 560),
            ("Hands", "hand.wave", AnyView(HandsSettingsView(preferences: preferences)), 560),
            ("Camera", "web.camera", AnyView(CameraSettingsView(preferences: preferences)), 420),
        ]
        for (title, symbol, view, height) in all {
            let host = NSHostingController(rootView: view.frame(width: Self.width, height: height))
            host.sizingOptions = [.preferredContentSize]
            host.title = title
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func select(tab title: String) {
        guard let tabs = window?.contentViewController as? NSTabViewController,
              let index = tabs.tabViewItems.firstIndex(where: { $0.label == title }) else { return }
        tabs.selectedTabViewItemIndex = index
    }
}

/// A labeled slider with its value on the right. The label is attached to the slider itself so
/// VoiceOver reads "Width, 60 percent" instead of an unlabeled slider.
struct SettingSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    var scale: Double = 1

    var body: some View {
        let shown = String(format: format, value * scale)
        HStack {
            Text(title)
            Slider(value: $value, in: range) { Text(title) }
                .labelsHidden()
                .accessibilityValue(shown)
            Text(shown)
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

/// Grey explanatory text under a setting.
struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
