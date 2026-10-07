import AppKit
import Sparkle

/// In-app updates through Sparkle. A release checks the appcast published with each GitHub
/// release once a day, downloads the new build, and installs it on quit.
///
/// Only the Developer ID signed release can take an update: Sparkle refuses a download whose
/// signature doesn't match the running app, and a dev build is signed with "Talix Dev Signing"
/// or ad hoc. So the updater stays off unless this copy is the signed release, and the menu item
/// says so instead of failing halfway.
@MainActor
final class UpdateController: NSObject {
    private var updater: SPUStandardUpdaterController?

    /// Whether this copy can install an update: it has a feed, and it's the signed release.
    static let isSupported: Bool = {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil && signedForDistribution
    }()

    private static var signedForDistribution: Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let certificates = dictionary["certificates"] as? [SecCertificate],
              let leaf = certificates.first else { return false }
        var commonName: CFString?
        SecCertificateCopyCommonName(leaf, &commonName)
        return (commonName as String?)?.hasPrefix("Developer ID Application") ?? false
    }

    func start() {
        guard Self.isSupported else { return }
        updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    /// The menu item. Always shows something, even in a build that can't update.
    @objc func checkForUpdates(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        guard let updater else {
            let alert = NSAlert()
            alert.messageText = "Updates aren't available in this build"
            alert.informativeText = "Only the signed release updates itself. This copy was built locally, so install new versions with build-app.sh or from the GitHub releases page."
            alert.runModal()
            return
        }
        updater.checkForUpdates(sender)
    }
}
