import CryptoKit
import Foundation

/// Sends finished gesture logs and gesture check reports to the upload server (see ingest/),
/// which files them in the recordings bucket for analysis. Opt in per Mac with Upload Gesture
/// Logs. The server address and token come from the app bundle (build-app.sh writes them from
/// CONDUCTOR_UPLOAD_URL and CONDUCTOR_UPLOAD_TOKEN); a build without them has no uploader.
///
/// A sweep looks at the log folder and sends every file it hasn't sent before, except the log
/// being written. A file counts as sent only once the server accepts it, so a failed or
/// interrupted upload is tried again on the next sweep. Logs are gzipped on the way (about ten
/// times smaller); reports go as they are. All of it runs on its own queue, never the camera's,
/// which is why it's `@unchecked Sendable`: the only mutable state is the sent list in UserDefaults.
final class LogUploader: @unchecked Sendable {
    struct Config: Equatable {
        var url: URL
        var token: String

        init(url: URL, token: String) {
            self.url = url
            self.token = token
        }

        /// Reads ConductorUploadURL and ConductorUploadToken from an Info.plist dictionary. Nil
        /// unless both are there.
        init?(info: [String: Any]) {
            guard let url = (info["ConductorUploadURL"] as? String).flatMap(URL.init(string:)),
                  let token = info["ConductorUploadToken"] as? String, !token.isEmpty else { return nil }
            self.init(url: url, token: token)
        }
    }

    /// The two kinds of file the server takes, named as its URL paths.
    enum Kind: String {
        case recordings, reports

        init?(fileName: String) {
            if fileName.hasPrefix("gestures-"), fileName.hasSuffix(".jsonl") {
                self = .recordings
            } else if fileName.hasPrefix("gesture-check-"), fileName.hasSuffix(".json") {
                self = .reports
            } else {
                return nil
            }
        }
    }

    enum Outcome: Equatable {
        case accepted
        case failed(String)
    }

    /// Delivers one request whose body is the file, and waits for the answer. Replaced in tests.
    typealias Send = (URLRequest, URL) -> Outcome

    /// The server (and the Workers platform) won't take a body past this; a recording that
    /// gzips bigger is skipped for good rather than tried again every sweep.
    static let maxBytes = 100 << 20
    static let sentKey = "uploadedLogs"
    static let installKey = "installID"

    let config: Config
    let installID: String
    private let directory: URL
    private let defaults: UserDefaults
    private let version: String?
    private let send: Send
    /// Serial; tests block on it to wait for a sweep.
    let queue = DispatchQueue(label: "conductor.log-upload", qos: .utility)

    init(config: Config, directory: URL = GestureLog.directory, defaults: UserDefaults = .standard,
         version: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
         send: Send? = nil) {
        self.config = config
        self.directory = directory
        self.defaults = defaults
        self.version = version
        self.send = send ?? Self.httpSend()
        installID = Self.installID(in: defaults)
    }

    /// A random ID for this Mac's copy of the app, made once and kept. It groups a Mac's
    /// recordings on the server without naming anyone.
    static func installID(in defaults: UserDefaults) -> String {
        if let id = defaults.string(forKey: installKey) { return id }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: installKey)
        return id
    }

    /// Sends every log and report in the folder that the server hasn't accepted yet, oldest
    /// first, skipping `active` (the log still being written). Returns at once; the work queues.
    func sweep(excluding active: URL? = nil) {
        queue.async { [self] in
            let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            // Files the user deleted drop out of the list so it doesn't grow forever.
            let present = Set(files.map(\.lastPathComponent))
            let stored = defaults.stringArray(forKey: Self.sentKey) ?? []
            var sent = Set(stored).intersection(present)
            // Saved after every accepted file, not once at the end: a quit mid-sweep shouldn't
            // send a recording twice.
            func save() { defaults.set(Array(sent).sorted(), forKey: Self.sentKey) }
            if sent.count != stored.count { save() }
            for file in files {
                let name = file.lastPathComponent
                guard file.standardizedFileURL != active?.standardizedFileURL, !sent.contains(name),
                      let kind = Kind(fileName: name) else { continue }
                switch upload(file, as: kind) {
                case .accepted:
                    sent.insert(name)
                    save()
                case .failed(let reason):
                    NSLog("Conductor: upload of \(name) failed: \(reason)")
                }
            }
        }
    }

    private func upload(_ file: URL, as kind: Kind) -> Outcome {
        var body = file
        var name = file.lastPathComponent
        var contentType = "application/json"
        if kind == .recordings {
            body = FileManager.default.temporaryDirectory.appending(path: "\(name).\(UUID().uuidString).gz")
            name += ".gz"
            contentType = "application/gzip"
            do {
                try Gzip.compress(file, to: body)
            } catch {
                return .failed("\(error)")
            }
        }
        defer { if body != file { try? FileManager.default.removeItem(at: body) } }
        let size = (try? body.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > Self.maxBytes {
            NSLog("Conductor: \(name) is \(size >> 20) MB gzipped, over the \(Self.maxBytes >> 20) MB upload limit; not sending it")
            return .accepted
        }
        guard let digest = try? Self.sha256(of: body) else { return .failed("couldn't read \(name) to checksum it") }
        var request = URLRequest(url: config.url.appending(path: "\(kind.rawValue)/\(name)"))
        request.httpMethod = "PUT"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        // The server has R2 check the body against this, and refuses a different file under a name
        // it already has.
        request.setValue(digest, forHTTPHeaderField: "X-Conductor-SHA256")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(installID, forHTTPHeaderField: "X-Conductor-Install")
        if let version { request.setValue(version, forHTTPHeaderField: "X-Conductor-Version") }
        request.setValue(ProcessInfo.processInfo.operatingSystemVersionString, forHTTPHeaderField: "X-Conductor-OS")
        return send(request, body)
    }

    /// Hex SHA-256 of a file, read in pieces.
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Uploads over HTTP and blocks the upload queue until the server answers; one file at a time
    /// is the point.
    private static func httpSend() -> Send {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 30 * 60
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        return { request, file in
            let done = DispatchSemaphore(value: 0)
            var outcome = Outcome.failed("no response")
            session.uploadTask(with: request, fromFile: file) { data, response, error in
                if let error {
                    outcome = .failed(error.localizedDescription)
                } else if let http = response as? HTTPURLResponse {
                    let text = data.flatMap { String(data: $0.prefix(200), encoding: .utf8) } ?? ""
                    outcome = (200..<300).contains(http.statusCode) ? .accepted : .failed("HTTP \(http.statusCode) \(text)")
                }
                done.signal()
            }.resume()
            done.wait()
            return outcome
        }
    }

    /// The request carries the token, and a redirect would carry it to wherever the server said.
    /// The server never redirects; one that does is not ours.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
