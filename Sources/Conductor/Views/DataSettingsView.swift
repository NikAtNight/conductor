import AppKit
import SwiftUI

/// What Conductor records while it runs and where it goes. Nothing here is a switch: the log is
/// how tracking gets tuned against real hands, and it never holds a picture. See GestureLog and
/// LogUploader for what's written and sent.
struct DataSettingsView: View {
    let installID: String
    /// Whether this build carries an upload server.
    let uploads: Bool
    let showLogs: () -> Void
    let uploadNow: () -> Void
    @State private var copied = false

    var body: some View {
        Form {
            Section("What Conductor records") {
                Text("While tracking is on, Conductor keeps a log of what it sees and what it does with it, and sends it to the developer to make tracking better. It is numbers only. No picture ever leaves the camera.")
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    bullet("The 21 points found on each hand, and how sure Vision is of each one")
                    bullet("The measurements the hand signs are read from: pinch distances, raised fingers, hand size")
                    bullet("Head angles and eye positions, which tell which display you're looking at")
                    bullet("What Conductor did: where the cursor went, clicks, scrolls, mode changes")
                    bullet("Your display layout, camera and Mac models, macOS version, and these settings")
                }
                Caption("Never recorded: camera images or video, anything you type, the apps you use, your name or account, or anything that identifies you or this Mac.")
            }
            Section("Where it goes") {
                LabeledContent("Install ID") {
                    HStack {
                        Text(installID)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Button(copied ? "Copied" : "Copy", action: copy)
                    }
                }
                Caption("A random ID made the first time Conductor ran, and the only thing a recording is filed under. Quote it when reporting a problem so the recordings from this Mac can be found.")
                HStack {
                    Button("Show Logs", action: showLogs)
                    Button("Upload Now", action: uploadNow).disabled(!uploads)
                    Spacer()
                }
                Caption(uploads
                    ? "Logs are sent when tracking stops and once an hour while it runs. They stay on this Mac too, for a week or 1 GB, whichever comes first. A log grows by a few megabytes a minute while a hand is in view."
                    : "This build has no upload server, so logs stay on this Mac: a week or 1 GB, whichever comes first.")
            }
        }
        .formStyle(.grouped)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(installID, forType: .string)
        copied = true
    }
}
