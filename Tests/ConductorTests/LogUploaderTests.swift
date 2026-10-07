import CryptoKit
import XCTest
@testable import Conductor

final class LogUploaderTests: XCTestCase {
    private var dir: URL!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "LogUploaderTests.\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "LogUploaderTests.\(UUID())")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ name: String, _ text: String) throws -> URL {
        let url = dir.appending(path: name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// What one sweep sent: the request and the body file's bytes (the file is gone afterwards).
    private struct Delivery { var request: URLRequest; var body: Data }

    private func gunzip(_ data: Data) throws -> String {
        let input = FileManager.default.temporaryDirectory.appending(path: "LogUploaderTests.\(UUID()).gz")
        defer { try? FileManager.default.removeItem(at: input) }
        try data.write(to: input)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", input.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "gzip rejected the file")
        return String(decoding: out, as: UTF8.self)
    }

    /// Runs a sweep and waits for it. The queue is serial, so a sync no-op runs once the sweep's done.
    private func sweep(_ uploader: LogUploader, active: URL? = nil, deliveries: inout [Delivery]) {
        uploader.sweep(excluding: active)
        uploader.queue.sync {}
    }

    func testEachFinishedFileGoesOnceGzippedWithTheInstallHeaders() throws {
        let log = try write("gestures-2026-10-06-120000.jsonl", "{\"time\":1}\n{\"time\":2}\n")
        _ = try write("gesture-check-2026-10-06-121500.json", "{\"date\":\"2026-10-06\"}")
        let active = try write("gestures-2026-10-06-130000.jsonl", "{\"time\":3}\n")
        _ = try write("notes.txt", "not ours")
        var deliveries: [Delivery] = []
        let lock = NSLock()
        let uploader = LogUploader(config: .init(url: URL(string: "https://logs.example")!, token: "secret"),
                                   directory: dir, defaults: defaults, version: "0.1.0") { request, body in
            lock.lock(); defer { lock.unlock() }
            deliveries.append(Delivery(request: request, body: (try? Data(contentsOf: body)) ?? Data()))
            return .accepted
        }
        sweep(uploader, active: active, deliveries: &deliveries)

        XCTAssertEqual(deliveries.map { $0.request.url?.path }, ["/reports/gesture-check-2026-10-06-121500.json",
                                                                 "/recordings/gestures-2026-10-06-120000.jsonl.gz"])
        let recording = deliveries[1].request
        XCTAssertEqual(recording.httpMethod, "PUT")
        XCTAssertEqual(recording.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(recording.value(forHTTPHeaderField: "Content-Type"), "application/gzip")
        XCTAssertEqual(recording.value(forHTTPHeaderField: "X-Conductor-Version"), "0.1.0")
        XCTAssertEqual(recording.value(forHTTPHeaderField: "X-Conductor-Install"), uploader.installID)
        XCTAssertEqual(recording.value(forHTTPHeaderField: "X-Conductor-SHA256"),
                       SHA256.hash(data: deliveries[1].body).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(uploader.installID, defaults.string(forKey: LogUploader.installKey))
        XCTAssertEqual(try gunzip(deliveries[1].body), try String(contentsOf: log, encoding: .utf8))
        XCTAssertEqual(deliveries[0].request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(String(decoding: deliveries[0].body, as: UTF8.self), "{\"date\":\"2026-10-06\"}")

        // Sent files stay sent; the log that was active goes once it's finished.
        sweep(uploader, deliveries: &deliveries)
        XCTAssertEqual(deliveries.map { $0.request.url?.lastPathComponent }.suffix(1), ["gestures-2026-10-06-130000.jsonl.gz"])
        XCTAssertEqual(defaults.stringArray(forKey: LogUploader.sentKey)?.count, 3)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 4, "originals and the stray file stay")
    }

    func testAFailedUploadIsTriedAgainNextSweepAndADeletedFileIsForgotten() throws {
        _ = try write("gestures-2026-10-06-120000.jsonl", "{\"time\":1}\n")
        let report = try write("gesture-check-2026-10-06-121500.json", "{}")
        var deliveries: [Delivery] = []
        var answers: [LogUploader.Outcome] = [.accepted, .failed("HTTP 503")]
        let lock = NSLock()
        let uploader = LogUploader(config: .init(url: URL(string: "https://logs.example")!, token: "t"),
                                   directory: dir, defaults: defaults, version: nil) { request, body in
            lock.lock(); defer { lock.unlock() }
            deliveries.append(Delivery(request: request, body: Data()))
            return answers.isEmpty ? .accepted : answers.removeFirst()
        }
        sweep(uploader, deliveries: &deliveries)
        XCTAssertEqual(deliveries.count, 2)
        XCTAssertEqual(defaults.stringArray(forKey: LogUploader.sentKey), ["gesture-check-2026-10-06-121500.json"])

        sweep(uploader, deliveries: &deliveries)
        XCTAssertEqual(deliveries.map { $0.request.url?.lastPathComponent }.suffix(1), ["gestures-2026-10-06-120000.jsonl.gz"])
        XCTAssertEqual(defaults.stringArray(forKey: LogUploader.sentKey)?.count, 2)

        try FileManager.default.removeItem(at: report)
        sweep(uploader, deliveries: &deliveries)
        XCTAssertEqual(deliveries.count, 3)
        XCTAssertEqual(defaults.stringArray(forKey: LogUploader.sentKey), ["gestures-2026-10-06-120000.jsonl"])
    }

    func testTheServerComesFromTheBundleAndNeedsBothKeys() {
        XCTAssertNil(LogUploader.Config(info: [:]))
        XCTAssertNil(LogUploader.Config(info: ["ConductorUploadURL": "https://logs.example"]))
        XCTAssertNil(LogUploader.Config(info: ["ConductorUploadURL": "https://logs.example", "ConductorUploadToken": ""]))
        let config = LogUploader.Config(info: ["ConductorUploadURL": "https://logs.example", "ConductorUploadToken": "abc"])
        XCTAssertEqual(config, .init(url: URL(string: "https://logs.example")!, token: "abc"))
    }

    func testGzipStreamsAFileBiggerThanOneChunk() throws {
        let line = String(repeating: "{\"joints\":[0.1234,0.5678]}", count: 100) + "\n"
        let text = String(repeating: line, count: 2000) // ~5 MB, several 1 MiB reads
        let source = try write("big.jsonl", text)
        let packed = dir.appending(path: "big.jsonl.gz")
        try Gzip.compress(source, to: packed)
        let size = try XCTUnwrap(packed.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertLessThan(size, text.utf8.count / 20, "repetitive JSON should shrink a lot")
        XCTAssertEqual(try gunzip(Data(contentsOf: packed)), text)
    }
}
