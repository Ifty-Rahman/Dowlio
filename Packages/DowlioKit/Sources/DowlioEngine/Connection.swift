import Foundation

/// One HTTP request whose response arrives as events: a connection, in the sense of `GLOSSARY.md`.
///
/// Each connection has its own `URLSession`, so each one gets its own TCP connection
/// (architecture.md, the download engine). Cookies and caching are off.
final class Connection: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    // @unchecked: `session` is only read or written under `lock`. Everything else is immutable.

    enum Event: Sendable {
        case response(HTTPURLResponse)
        case data(Data)
    }

    let events: AsyncThrowingStream<Event, Error>
    private let continuation: AsyncThrowingStream<Event, Error>.Continuation
    private let lock = NSLock()
    private var session: URLSession?

    /// Starts `request`. If no bytes arrive for `idleTimeout`, the events end with
    /// `URLError.timedOut`.
    init(request: URLRequest, idleTimeout: Duration = .seconds(60)) {
        (events, continuation) = AsyncThrowingStream.makeStream(of: Event.self)
        super.init()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = idleTimeout.timeInterval
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        lock.withLock { self.session = session }

        continuation.onTermination = { [weak self] _ in self?.cancel() }
        session.dataTask(with: request).resume()
    }

    /// Waits for the response. After it, `events` yields only data.
    func firstResponse() async throws -> HTTPURLResponse {
        for try await event in events {
            if case .response(let response) = event { return response }
        }
        throw URLError(.badServerResponse)
    }

    /// Stops the request. Safe to call more than once, from any thread.
    func cancel() {
        let session: URLSession? = lock.withLock {
            defer { self.session = nil }
            return self.session
        }
        session?.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            continuation.finish(throwing: URLError(.badServerResponse))
            return completionHandler(.cancel)
        }
        continuation.yield(.response(response))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation.yield(.data(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
        session.finishTasksAndInvalidate()
    }
}
