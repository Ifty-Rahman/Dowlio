import Foundation

/// One HTTP request whose response arrives as events: a connection, in the sense of `GLOSSARY.md`.
///
/// Each connection has its own `URLSession`, so each one gets its own TCP connection
/// (architecture.md, the download engine), unless it's given a `SharedSession`. Cookies and
/// caching are off.
final class Connection: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    // @unchecked: `session` and `task` are only read or written under `lock`. Everything else is
    // immutable.

    enum Event: Sendable {
        case response(HTTPURLResponse)
        case data(Data)
    }

    let events: AsyncThrowingStream<Event, Error>
    private let continuation: AsyncThrowingStream<Event, Error>.Continuation
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionTask?
    private let shared: SharedSession?

    /// Starts `request`. If no bytes arrive for `idleTimeout`, the events end with
    /// `URLError.timedOut`.
    init(request: URLRequest, idleTimeout: Duration = .seconds(60)) {
        (events, continuation) = AsyncThrowingStream.makeStream(of: Event.self)
        shared = nil
        super.init()

        let session = URLSession(
            configuration: Self.configuration(idleTimeout: idleTimeout), delegate: self, delegateQueue: nil
        )
        lock.withLock { self.session = session }

        continuation.onTermination = { [weak self] _ in self?.cancel() }
        session.dataTask(with: request).resume()
    }

    /// Starts `request` on `shared`, next to the download's other connections.
    init(request: URLRequest, shared: SharedSession) {
        (events, continuation) = AsyncThrowingStream.makeStream(of: Event.self)
        self.shared = shared
        super.init()

        let task = shared.session.dataTask(with: request)
        task.delegate = self
        lock.withLock { self.task = task }

        continuation.onTermination = { [weak self] _ in self?.cancel() }
        task.resume()
    }

    static func configuration(idleTimeout: Duration) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = idleTimeout.timeInterval
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
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
        let (session, task): (URLSession?, URLSessionTask?) = lock.withLock {
            defer {
                self.session = nil
                self.task = nil
            }
            return (self.session, self.task)
        }
        session?.invalidateAndCancel()
        task?.cancel()
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

    /// Follows redirects, but never carries the cookies or the browser's own headers to another
    /// scheme, host or port than the hop before.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var request = request
        if !Self.sameOrigin(response.url ?? task.currentRequest?.url, request.url) {
            for name in (request.allHTTPHeaderFields ?? [:]).keys where !Self.keptAcrossSites.contains(name.lowercased()) {
                request.setValue(nil, forHTTPHeaderField: name)
            }
        }
        completionHandler(request)
    }

    private static let keptAcrossSites: Set<String> = ["range", "if-range", "accept-encoding", "user-agent", "referer"]

    private static func sameOrigin(_ url: URL?, _ other: URL?) -> Bool {
        guard let url, let other else { return false }
        return url.hasSameOrigin(as: other)
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
        if shared == nil { session.finishTasksAndInvalidate() }
    }
}

/// One `URLSession` for all connections of a download.
final class SharedSession: Sendable {
    let session: URLSession

    init(idleTimeout: Duration) {
        let configuration = Connection.configuration(idleTimeout: idleTimeout)
        // The default of 6 would cap a download below its 16 connections.
        configuration.httpMaximumConnectionsPerHost = 16
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }
}
