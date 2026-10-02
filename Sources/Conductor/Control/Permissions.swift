import ApplicationServices

enum Permissions {
    /// Posting CGEvents requires the Accessibility grant. Passing `prompt: true` makes macOS show
    /// its own dialog and add the app to the list, unchecked, in System Settings.
    static func accessibilityGranted(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
