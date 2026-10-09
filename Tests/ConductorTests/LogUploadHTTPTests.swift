import XCTest
@testable import Conductor

final class LogUploadHTTPTests: XCTestCase {
    private final class LocalProtocol: URLProtocol {
        static var handle: ((LocalProtocol) -> Void)?
        static var stopped: (() -> Void)?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() { Self.handle?(self) }
        override func stopLoading() { Self.stopped?() }
    }

    private var body: URL!

    override func setUpWithError() throws {
        body = FileManager.default.temporaryDirectory.appending(path: "LogUploadHTTPTests.\(UUID()).json")
        try Data("{}".utf8).write(to: body)
    }

    override func tearDownWithError() throws {
        LocalProtocol.handle = nil
        LocalProtocol.stopped = nil
        try? FileManager.default.removeItem(at: body)
    }

    private func transport() -> LogUploadHTTP {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalProtocol.self]
        return LogUploadHTTP(configuration: configuration)
    }

    func testOversizedResponseChunksKeepOnlyFirst200BytesAndStatus() {
        for status in [201, 409] {
            LocalProtocol.handle = { protocolInstance in
                let response = HTTPURLResponse(url: protocolInstance.request.url!, statusCode: status,
                                               httpVersion: "HTTP/1.1", headerFields: nil)!
                protocolInstance.client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
                protocolInstance.client?.urlProtocol(protocolInstance, didLoad: Data(repeating: 0x41, count: 125))
                protocolInstance.client?.urlProtocol(protocolInstance, didLoad: Data(repeating: 0x42, count: 1 << 20))
                protocolInstance.client?.urlProtocol(protocolInstance, didLoad: Data(repeating: 0x43, count: 1 << 20))
                protocolInstance.client?.urlProtocolDidFinishLoading(protocolInstance)
            }
            let sender = transport()
            let result = sender.send(URLRequest(url: URL(string: "https://local.invalid/upload")!), file: body)
            XCTAssertEqual(sender.bufferedResponseBytes, 200)
            let expected: LogUploader.Outcome = status == 201 ? .accepted :
                .failed("HTTP 409 " + String(repeating: "A", count: 125) + String(repeating: "B", count: 75))
            XCTAssertEqual(result, expected)
        }
    }

    func testCancelStopsAnActiveRequestAndReturnsFailure() {
        let started = DispatchSemaphore(value: 0)
        let stopped = expectation(description: "protocol stopped")
        LocalProtocol.handle = { _ in started.signal() }
        LocalProtocol.stopped = { stopped.fulfill() }
        let sender = transport()
        let finished = expectation(description: "send returned")
        let file = body!
        DispatchQueue.global().async {
            XCTAssertEqual(sender.send(URLRequest(url: URL(string: "https://local.invalid/upload")!), file: file), .failed("cancelled"))
            finished.fulfill()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        sender.cancel()
        wait(for: [stopped, finished], timeout: 2)
    }

    func testCancellationBeforeSendNeverStartsARequest() {
        LocalProtocol.handle = { _ in XCTFail("cancelled upload started") }
        let sender = transport()
        sender.cancel()
        XCTAssertEqual(sender.send(URLRequest(url: URL(string: "https://local.invalid/upload")!), file: body), .failed("cancelled"))
    }

    func testRedirectIsRejectedWithoutForwardingAuthorization() {
        let sender = transport()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://local.invalid/upload")!)
        let response = HTTPURLResponse(url: task.originalRequest!.url!, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: nil)!
        var redirect = URLRequest(url: URL(string: "https://other.invalid/upload")!)
        redirect.setValue("Bearer test", forHTTPHeaderField: "Authorization")
        var called = false
        sender.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: redirect) { request in
            called = true
            XCTAssertNil(request)
        }
        XCTAssertTrue(called)
    }

    func testUploaderOptOutCancelsActiveSessionAndLeavesBothBacklogFilesUnsent() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "LogUploadHTTPTests.\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["gesture-check-a.json", "gesture-check-b.json"] {
            try Data("{}".utf8).write(to: directory.appending(path: name))
        }
        let suite = "LogUploadHTTPTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let started = DispatchSemaphore(value: 0)
        let stopped = expectation(description: "active URLSession task cancelled")
        var requests = 0
        LocalProtocol.handle = { _ in requests += 1; started.signal() }
        LocalProtocol.stopped = { stopped.fulfill() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalProtocol.self]
        let uploader = LogUploader(config: .init(url: URL(string: "https://local.invalid")!, token: "test"),
                                   directory: directory, defaults: defaults, httpConfiguration: configuration)
        uploader.sweep()
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        uploader.sweep()
        uploader.setEnabled(false)
        let finished = expectation(description: "cancelled sweep returned")
        uploader.queue.async { finished.fulfill() }
        wait(for: [stopped, finished], timeout: 2)
        XCTAssertEqual(requests, 1)
        XCTAssertNil(defaults.stringArray(forKey: LogUploader.sentKey))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
                       ["gesture-check-a.json", "gesture-check-b.json"])
    }

}
