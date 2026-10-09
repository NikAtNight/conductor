import Foundation

/// One cancellable upload. Delegate callbacks retain at most 200 response bytes.
final class LogUploadHTTP: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let responseLimit = 200
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private let configuration: URLSessionConfiguration
    private var task: URLSessionUploadTask?
    private var cancelled = false
    private var response: HTTPURLResponse?
    private var responseBytes = Data()
    private var result = LogUploader.Outcome.failed("no response")

    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
        super.init()
    }

    var bufferedResponseBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return responseBytes.count
    }

    func send(_ request: URLRequest, file: URL) -> LogUploader.Outcome {
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        lock.lock()
        if cancelled {
            lock.unlock()
            session.invalidateAndCancel()
            return .failed("cancelled")
        }
        let upload = session.uploadTask(with: request, fromFile: file)
        task = upload
        upload.resume()
        lock.unlock()
        done.wait()
        session.finishTasksAndInvalidate()
        lock.lock(); defer { lock.unlock() }
        task = nil
        return result
    }

    func cancel() {
        lock.lock()
        cancelled = true
        task?.cancel()
        lock.unlock()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        self.response = response as? HTTPURLResponse
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        responseBytes.append(contentsOf: data.prefix(Self.responseLimit - responseBytes.count))
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        if cancelled {
            result = .failed("cancelled")
        } else if let error {
            result = .failed(error.localizedDescription)
        } else if let response {
            let text = String(decoding: responseBytes, as: UTF8.self)
            result = (200..<300).contains(response.statusCode) ? .accepted : .failed("HTTP \(response.statusCode) \(text)")
        }
        lock.unlock()
        done.signal()
    }

    /// The Authorization header must never follow a redirect.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
